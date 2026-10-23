import Foundation
import Darwin

/// Unix domain socket server dispatching framed JSON requests to an `IPCService`.
public final class IPCServer: @unchecked Sendable {
    public let path: String
    public let service: IPCService
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "everything.ipc.accept")
    private let workQueue = DispatchQueue(label: "everything.ipc.work", attributes: .concurrent)
    public private(set) var isRunning = false
    public var log: ((String) -> Void)?

    public init(path: String, service: IPCService) {
        self.path = path
        self.service = service
    }

    deinit { stop() }

    public func start() throws {
        guard !isRunning else { return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.socket(errno) }
        unlink(path)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); throw IPCError.pathTooLong }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { p in
                for (i, b) in bytes.enumerated() { p[i] = CChar(bitPattern: b) }
                p[bytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sa_family_t>.size + 1 + bytes.count + 1)
        let bindResult = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard bindResult == 0 else { let e = errno; close(fd); throw IPCError.bind(e) }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else { let e = errno; close(fd); throw IPCError.listen(e) }
        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        src.setEventHandler { [weak self] in self?.acceptPending() }
        src.resume()
        source = src
        isRunning = true
        log?("IPC listening on \(path)")
    }

    public func stop() {
        guard isRunning else { return }
        source?.cancel()
        source = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
        isRunning = false
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }
            workQueue.async { [self] in self.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        while let payload = FrameIO.readFrame(fd, timeoutMs: 600_000) {
            let request: IPCRequest
            do { request = try IPCCodec.decode(IPCRequest.self, payload) }
            catch {
                _ = FrameIO.writeFrame(fd, (try? IPCCodec.encode(IPCResponse.failure("bad request: \(error)"))) ?? Data())
                continue
            }
            let sema = DispatchSemaphore(value: 0)
            var response = IPCResponse.failure("no response")
            service.handle(request) { r in response = r; sema.signal() }
            sema.wait()
            guard let data = try? IPCCodec.encode(response), FrameIO.writeFrame(fd, data) else { return }
            if request.kind == .exit { return }
        }
    }
}

public enum IPCError: Error, Equatable {
    case socket(Int32), bind(Int32), listen(Int32), connect(Int32), pathTooLong, timeout, closed, decode(String), notRunning
}
