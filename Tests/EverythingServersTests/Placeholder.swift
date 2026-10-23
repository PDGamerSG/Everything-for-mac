import Foundation
import Darwin
import Testing
import EverythingCore
import EverythingIPC
@testable import EverythingServers

private func makeRequest(port: UInt16, _ request: String) throws -> String {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #expect(fd >= 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    #expect(connected == 0)
    let bytes = Array(request.utf8)
    _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, bytes.count) }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
        let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if n <= 0 { break }
        data.append(buffer, count: n)
    }
    return String(decoding: data, as: UTF8.self)
}

private func body(_ response: String) -> String {
    response.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
}

private func serviceWithFixture() -> EngineService {
    let index = Index()
    let root = index.addRoot(kind: .volume, path: "/", label: "Macintosh HD").item
    let docs = index.store.add(ItemRecord(name: "Docs", parent: root, flags: [.folder]))
    index.store.add(ItemRecord(name: "hello.txt", parent: docs, size: 42))
    index.store.add(ItemRecord(name: "other.jpg", parent: root, size: 3))
    return EngineService(engine: SearchEngine(index: index))
}

@Suite(.serialized) struct HTTPTests {
    @Test func jsonSearchAndPaging() throws {
        let server = HTTPServer(service: serviceWithFixture(), configuration: .init(port: 0, itemsPerPage: 32))
        try server.start()
        defer { server.stop() }
        let response = try makeRequest(port: server.port, "GET /json?search=hello&columns=name,full-path&count=1 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        #expect(response.hasPrefix("HTTP/1.1 200 OK"))
        let data = try #require(body(response).data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["totalResults"] as? Int == 1)
        #expect((object["results"] as? [[String: Any]])?.first?["name"] as? String == "hello.txt")
    }

    @Test func basicAuthRejectsAndAccepts() throws {
        let config = HTTPServer.Configuration(port: 0, username: "user", password: "secret")
        let server = HTTPServer(service: serviceWithFixture(), configuration: config)
        try server.start()
        defer { server.stop() }
        let denied = try makeRequest(port: server.port, "GET /json HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        #expect(denied.hasPrefix("HTTP/1.1 401 Unauthorized"))
        let token = Data("user:secret".utf8).base64EncodedString()
        let accepted = try makeRequest(port: server.port, "GET /json HTTP/1.1\r\nHost: localhost\r\nAuthorization: Basic \(token)\r\nConnection: close\r\n\r\n")
        #expect(accepted.hasPrefix("HTTP/1.1 200 OK"))
    }

    @Test func downloadPolicyAndTraversalProtection() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("everything-http-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("hello.txt"))
        defer { try? FileManager.default.removeItem(at: root) }
        let disabled = HTTPServer(service: serviceWithFixture(), configuration: .init(port: 0, allowDownloads: false))
        try disabled.start()
        defer { disabled.stop() }
        let encodedRoot = root.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let forbidden = try makeRequest(port: disabled.port, "GET /download?path=\(encodedRoot) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        #expect(forbidden.hasPrefix("HTTP/1.1 403 Forbidden"))

        let enabled = HTTPServer(service: serviceWithFixture(), configuration: .init(port: 0, allowDownloads: true, downloadRoots: [root.path]))
        try enabled.start()
        defer { enabled.stop() }
        let traversal = try makeRequest(port: enabled.port, "GET /download?path=\(encodedRoot)%2F..%2Fsecret HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        #expect(traversal.hasPrefix("HTTP/1.1 400 Bad Request"))
        let filePath = root.appendingPathComponent("hello.txt").path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let downloaded = try makeRequest(port: enabled.port, "GET /download?path=\(filePath) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        #expect(downloaded.hasPrefix("HTTP/1.1 200 OK"))
        #expect(body(downloaded) == "hello")
    }
}
