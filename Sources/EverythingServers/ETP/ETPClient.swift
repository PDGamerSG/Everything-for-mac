import Foundation
import Darwin
import EverythingCore
import EverythingIPC

/// Small ETP client used by the app's remote-index workspace and command-line integrations.
public final class ETPClient: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var host: String
        public var port: UInt16
        public var username: String
        public var password: String
        public init(host: String, port: UInt16 = 21, username: String = "", password: String = "") {
            self.host = host; self.port = port; self.username = username; self.password = password
        }
    }
    public enum ClientError: Error, Equatable { case socket(Int32), protocolError(String), authentication }
    public let configuration: Configuration
    public init(configuration: Configuration) { self.configuration = configuration }

    public func query(_ params: IPCQueryParams) throws -> IPCQueryResult {
        let fd = try connect()
        defer { close(fd) }
        guard let greeting = etpClientReadLine(fd), String(data: greeting, encoding: .utf8)?.hasPrefix("220") == true else { throw ClientError.protocolError("missing greeting") }
        etpClientSend(fd, "USER \(configuration.username)")
        let userResponse = try response(fd)
        if userResponse.hasPrefix("331") {
            etpClientSend(fd, "PASS \(configuration.password)")
            guard try response(fd).hasPrefix("230") else { throw ClientError.authentication }
        } else if !userResponse.hasPrefix("230") {
            throw ClientError.authentication
        }
        etpClientSend(fd, "SITE EVERYTHING SEARCH \(params.search)")
        guard try response(fd).hasPrefix("200") else { throw ClientError.protocolError("search rejected") }
        etpClientSend(fd, "SITE EVERYTHING QUERY")
        let queryResponse = try response(fd)
        guard queryResponse.hasPrefix("200") else { throw ClientError.protocolError(queryResponse) }
        let items = parseRows(String(queryResponse.dropFirst(4)).trimmingCharacters(in: .whitespaces))
        etpClientSend(fd, "QUIT"); _ = etpClientReadLine(fd)
        return IPCQueryResult(totalFiles: items.count, totalFolders: 0, totalResults: items.count, items: items,
                              generation: 0, seconds: 0, errors: [])
    }

    private func connect() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.socket(errno) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = configuration.port.bigEndian
        guard let ip = etpClientAddress(configuration.host) else { close(fd); throw ClientError.protocolError("invalid address") }
        address.sin_addr = ip
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        } }
        guard result == 0 else { let e = errno; close(fd); throw ClientError.socket(e) }
        var noSigPipe: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private func response(_ fd: Int32) throws -> String {
        guard let data = etpClientReadLine(fd), let line = String(data: data, encoding: .utf8) else { throw ClientError.protocolError("connection closed") }
        return line
    }

    private func parseRows(_ payload: String) -> [IPCItem] {
        guard !payload.isEmpty else { return [] }
        return payload.components(separatedBy: " | ").compactMap { row in
            let fields = row.split(separator: "\t", maxSplits: 1).map(String.init)
            guard let fullPath = fields.first, !fullPath.isEmpty else { return nil }
            var item = IPCItem(type: "file", name: Paths.lastComponent(fullPath), path: Paths.parent(fullPath), fullPath: fullPath, itemID: -1)
            if fields.count == 2, let size = UInt64(fields[1]), !fields[1].isEmpty { item.size = size }
            return item
        }
    }
}

private func etpClientAddress(_ value: String) -> in_addr? { var address = in_addr(); return inet_aton(value, &address) == 0 ? nil : address }
private func etpClientSend(_ fd: Int32, _ line: String) {
    let data = Data((line + "\r\n").utf8)
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < data.count {
            let count = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
            if count <= 0 { break }
            offset += count
        }
    }
}
private func etpClientReadLine(_ fd: Int32) -> Data? {
    var bytes: [UInt8] = []
    while true {
        var byte: UInt8 = 0; let count = Darwin.read(fd, &byte, 1)
        if count <= 0 { return bytes.isEmpty ? nil : Data(bytes) }
        if byte == 10 { return Data(bytes) }
        if byte != 13 { bytes.append(byte) }
    }
}
