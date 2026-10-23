import Foundation
import Darwin
import EverythingCore
import EverythingIPC

/// Everything's FTP-like control protocol. The `SITE EVERYTHING` commands expose
/// native search results while standard FTP commands make the index usable by clients.
public final class ETPServer: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var bindAddress: String
        public var port: UInt16
        public var username: String
        public var password: String
        public var allowDownloads: Bool
        public init(bindAddress: String = "127.0.0.1", port: UInt16 = 21, username: String = "", password: String = "", allowDownloads: Bool = true) {
            self.bindAddress = bindAddress; self.port = port; self.username = username; self.password = password; self.allowDownloads = allowDownloads
        }
    }
    public enum ServerError: Error, Equatable { case socket(Int32), bind(Int32), listen(Int32), invalidAddress }
    public let service: EngineService
    public let configuration: Configuration
    public private(set) var port: UInt16
    public private(set) var isRunning = false
    public var log: ((String) -> Void)?
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "everything.etp.accept", qos: .utility)
    private let workQueue = DispatchQueue(label: "everything.etp.work", qos: .utility, attributes: .concurrent)
    private let lock = NSLock()

    public init(service: EngineService, configuration: Configuration = Configuration()) { self.service = service; self.configuration = configuration; self.port = configuration.port }
    deinit { stop() }
    public func start() throws {
        lock.lock(); defer { lock.unlock() }; guard !isRunning else { return }
        guard let address = etpAddress(configuration.bindAddress) else { throw ServerError.invalidAddress }
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw ServerError.socket(errno) }
        var reuse: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var endpoint = sockaddr_in(); endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); endpoint.sin_family = sa_family_t(AF_INET); endpoint.sin_port = configuration.port.bigEndian; endpoint.sin_addr = address
        let bound = withUnsafePointer(to: &endpoint) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { let e = errno; close(fd); throw ServerError.bind(e) }
        guard listen(fd, 64) == 0 else { let e = errno; close(fd); throw ServerError.listen(e) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var actual = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) } }
        port = UInt16(bigEndian: actual.sin_port); listenFD = fd
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        readSource.setEventHandler { [weak self] in self?.acceptPending() }; readSource.setCancelHandler { close(fd) }; readSource.resume(); source = readSource; isRunning = true
        log?("ETP listening on \(configuration.bindAddress):\(port)")
    }
    public func stop() { lock.lock(); defer { lock.unlock() }; guard isRunning else { return }; source?.cancel(); source = nil; listenFD = -1; isRunning = false }
    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }
            _ = fcntl(client, F_SETFL, 0)
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            workQueue.async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        sendLine(fd, "220 Everything ETP ready")
        var userOK = configuration.username.isEmpty && configuration.password.isEmpty
        var pendingSearch = ""
        var passiveFD: Int32 = -1
        defer { if passiveFD >= 0 { close(passiveFD) } }
        while let line = readLine(fd) {
            let split = line.split(separator: " ", maxSplits: 1).map(String.init); let command = split.first?.uppercased() ?? ""; let argument = split.count > 1 ? split[1] : ""
            log?("ETP \(command) \(argument)")
            switch command {
            case "USER":
                userOK = configuration.username.isEmpty || argument == configuration.username
                sendLine(fd, userOK && configuration.password.isEmpty ? "230 Logged in" : "331 Password required")
            case "PASS":
                if configuration.username.isEmpty && configuration.password.isEmpty { userOK = true; sendLine(fd, "230 Logged in") }
                else if userOK && argument == configuration.password { userOK = true; sendLine(fd, "230 Logged in") }
                else { userOK = false; sendLine(fd, "530 Login incorrect") }
            case "QUIT": sendLine(fd, "221 Goodbye"); return
            case "FEAT":
                sendLine(fd, "211-Features"); sendLine(fd, " EVERYTHING"); sendLine(fd, " UTF8"); sendLine(fd, " MLSD"); sendLine(fd, "211 End")
            case "SYST": sendLine(fd, "215 UNIX Type: L8")
            case "NOOP": sendLine(fd, "200 OK")
            case "PWD": sendLine(fd, "257 \"/\" is current directory")
            case "TYPE": sendLine(fd, "200 Type set")
            case "SITE":
                guard userOK else { sendLine(fd, "530 Not logged in"); continue }
                let site = argument.split(separator: " ", maxSplits: 2).map(String.init)
                if site.count >= 2 && site[0].uppercased() == "EVERYTHING" {
                    if site[1].uppercased() == "SEARCH" { pendingSearch = site.count == 3 ? site[2] : ""; sendLine(fd, "200 Search accepted") }
                    else if site[1].uppercased() == "QUERY" {
                        var q = IPCQueryParams(search: pendingSearch); q.columns = ["name", "path", "fullpath", "size"]
                        let rows = service.runQuery(q).query?.items.map { "\($0.fullPath)\t\($0.size.map(String.init) ?? "")" }.joined(separator: " | ") ?? ""
                        sendLine(fd, "200 \(rows)")
                    } else { sendLine(fd, "500 Unknown Everything command") }
                } else { sendLine(fd, "500 Unknown SITE command") }
            case "PASV", "EPSV":
                guard userOK else { sendLine(fd, "530 Not logged in"); continue }
                if passiveFD >= 0 { close(passiveFD) }
                guard let passive = makePassiveSocket() else { sendLine(fd, "425 Can't open data connection"); continue }
                let p = passive.port
                passiveFD = passive.fd
                if command == "EPSV" { sendLine(fd, "229 Entering Extended Passive Mode (|||\(p)|)") }
                else { let high = p / 256, low = p % 256; sendLine(fd, "227 Entering Passive Mode (127,0,0,1,\(high),\(low))") }
            case "LIST", "MLSD":
                guard userOK else { sendLine(fd, "530 Not logged in"); continue }
                guard passiveFD >= 0 else { sendLine(fd, "425 Use PASV first"); continue }
                let path = argument.isEmpty ? "/" : argument
                guard let entries = try? DirectoryLister.list(path) else { sendLine(fd, "550 Failed to list"); continue }
                let dataFD = accept(passiveFD, nil, nil)
                guard dataFD >= 0 else { sendLine(fd, "550 Failed to open data connection"); continue }
                close(passiveFD); passiveFD = -1; sendLine(fd, "150 Opening data connection")
                for entry in entries { let line = command == "MLSD" ? "type=\(entry.kind == .directory ? "dir" : "file");size=\(entry.size);modify=\(entry.dateModified) \(entry.name)" : "-rw-r--r-- 1 owner group \(entry.size) Jan 01 00:00 \(entry.name)"; sendLine(dataFD, line) }
                shutdown(dataFD, SHUT_WR); close(dataFD); sendLine(fd, "226 Transfer complete")
            case "RETR":
                guard userOK else { sendLine(fd, "530 Not logged in"); continue }
                guard configuration.allowDownloads else { sendLine(fd, "550 Downloads disabled"); continue }
                guard !argument.contains(".."), let data = try? Data(contentsOf: URL(fileURLWithPath: argument)) else { sendLine(fd, "550 File unavailable"); continue }
                guard passiveFD >= 0 else { sendLine(fd, "425 Use PASV first"); continue }
                let dataFD = accept(passiveFD, nil, nil); close(passiveFD); passiveFD = -1
                guard dataFD >= 0 else { sendLine(fd, "425 Can't open data connection"); continue }
                sendLine(fd, "150 Opening binary mode data connection"); _ = writeAllETP(dataFD, data); shutdown(dataFD, SHUT_WR); close(dataFD); sendLine(fd, "226 Transfer complete")
            default: sendLine(fd, "502 Command not implemented")
            }
        }
    }
}

private func etpAddress(_ value: String) -> in_addr? { var address = in_addr(); return inet_aton(value, &address) == 0 ? nil : address }
private func readLine(_ fd: Int32) -> String? { var bytes: [UInt8] = []; while true { var b: UInt8 = 0; let n = Darwin.read(fd, &b, 1); if n <= 0 { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }; if b == 10 { break }; if b != 13 { bytes.append(b) } }; return String(decoding: bytes, as: UTF8.self) }
private func sendLine(_ fd: Int32, _ line: String) { let data = Data((line + "\r\n").utf8); _ = writeAllETP(fd, data) }
private func writeAllETP(_ fd: Int32, _ data: Data) -> Bool { var offset = 0; return data.withUnsafeBytes { raw in guard let base = raw.baseAddress else { return true }; while offset < data.count { let n = Darwin.write(fd, base.advanced(by: offset), data.count - offset); if n <= 0 { return false }; offset += n }; return true } }
private func makePassiveSocket() -> (fd: Int32, port: UInt16)? {
    let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { return nil }; var reuse: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var endpoint = sockaddr_in(); endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); endpoint.sin_family = sa_family_t(AF_INET); endpoint.sin_port = 0; endpoint.sin_addr = etpAddress("127.0.0.1")!
    let bound = withUnsafePointer(to: &endpoint) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }; guard bound == 0, listen(fd, 1) == 0 else { close(fd); return nil }
    var actual = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size); withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) } }
    return (fd, UInt16(bigEndian: actual.sin_port))
}
