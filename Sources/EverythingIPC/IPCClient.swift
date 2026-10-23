import Foundation
import Darwin

/// Blocking client for the Everything IPC socket.
public final class IPCClient: @unchecked Sendable {
    public let path: String
    public var timeoutMs: Int32 = 30_000
    private var fd: Int32 = -1
    private let lock = NSLock()

    public init(path: String = SocketPath.path()) { self.path = path }
    public convenience init(instance: String) { self.init(path: SocketPath.path(instance: instance)) }

    deinit { disconnect() }

    public var isConnected: Bool { fd >= 0 }

    /// True when a server answers a ping.
    public static func isRunning(path: String = SocketPath.path()) -> Bool {
        let c = IPCClient(path: path)
        c.timeoutMs = 2_000
        return (try? c.send(IPCRequest(kind: .ping)))?.ok == true
    }

    public func connect() throws {
        lock.lock(); defer { lock.unlock() }
        try connectLocked()
    }

    private func connectLocked() throws {
        if fd >= 0 { return }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw IPCError.socket(errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(s); throw IPCError.pathTooLong }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { p in
                for (i, b) in bytes.enumerated() { p[i] = CChar(bitPattern: b) }
                p[bytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sa_family_t>.size + 1 + bytes.count + 1)
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, len) } }
        guard r == 0 else { let e = errno; close(s); throw IPCError.connect(e) }
        var nosig: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        fd = s
    }

    public func disconnect() {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { close(fd); fd = -1 }
    }

    /// Sends one request and waits for the response. Reconnects once on a broken connection.
    public func send(_ request: IPCRequest) throws -> IPCResponse {
        lock.lock(); defer { lock.unlock() }
        let payload = try IPCCodec.encode(request)
        for attempt in 0..<2 {
            do { try connectLocked() } catch { throw error }
            if FrameIO.writeFrame(fd, payload), let data = FrameIO.readFrame(fd, timeoutMs: timeoutMs) {
                do { return try IPCCodec.decode(IPCResponse.self, data) } catch { throw IPCError.decode("\(error)") }
            }
            close(fd); fd = -1
            if attempt == 1 { throw IPCError.closed }
        }
        throw IPCError.closed
    }

    // MARK: convenience

    public func query(_ params: IPCQueryParams) throws -> IPCQueryResult {
        let r = try send(.query(params))
        guard r.ok, let q = r.query else { throw IPCError.decode(r.error ?? "no result") }
        return q
    }

    public func version() throws -> String {
        let r = try send(IPCRequest(kind: .version))
        guard r.ok, let v = r.version ?? r.string else { throw IPCError.decode(r.error ?? "no version") }
        return v
    }
}
