import Foundation
import Darwin
import Testing
import EverythingCore
import EverythingIPC
@testable import EverythingServers

private func etpFixture() -> EngineService {
    let index = Index()
    let root = index.addRoot(kind: .volume, path: "/", label: "Macintosh HD").item
    let docs = index.store.add(ItemRecord(name: "Docs", parent: root, flags: [.folder]))
    index.store.add(ItemRecord(name: "hello.txt", parent: docs, flags: [], size: 5))
    return EngineService(engine: SearchEngine(index: index))
}

private final class ETPConnection {
    let fd: Int32
    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "socket", code: Int(errno)) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { close(fd); throw NSError(domain: "connect", code: Int(errno)) }
    }
    deinit { close(fd) }
    func readLine() -> String {
        var bytes: [UInt8] = []
        while true { var b: UInt8 = 0; let n = read(fd, &b, 1); if n <= 0 { break }; if b == 10 { break }; if b != 13 { bytes.append(b) } }
        return String(decoding: bytes, as: UTF8.self)
    }
    func send(_ line: String) { let data = Data((line + "\r\n").utf8); _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) } }

    func openPassiveData(from response: String) throws -> Int32 {
        let values = response.split(whereSeparator: { !$0.isNumber }).compactMap { UInt16($0) }
        guard values.count >= 2 else {
            throw NSError(domain: "pasv", code: 1, userInfo: [NSLocalizedDescriptionKey: response])
        }
        let port = values[values.count - 2] * 256 + values[values.count - 1]
        let dataFD = socket(AF_INET, SOCK_STREAM, 0)
        guard dataFD >= 0 else { throw NSError(domain: "data-socket", code: Int(errno)) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(dataFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { close(dataFD); throw NSError(domain: "data-connect", code: Int(errno)) }
        return dataFD
    }

    func readData(_ dataFD: Int32) -> Data {
        defer { close(dataFD) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(dataFD, $0.baseAddress, $0.count) }
            if count <= 0 { return data }
            data.append(buffer, count: count)
        }
    }
}

@Suite(.serialized) struct ETPTests {
    @Test func authFeaturesAndEverythingQuery() throws {
        let server = ETPServer(service: etpFixture(), configuration: .init(port: 0, username: "u", password: "p"))
        try server.start(); defer { server.stop() }
        let c = try ETPConnection(port: server.port)
        #expect(c.readLine().hasPrefix("220"))
        c.send("USER u"); #expect(c.readLine().hasPrefix("331"))
        c.send("PASS p"); #expect(c.readLine().hasPrefix("230"))
        c.send("FEAT"); let feat = c.readLine(); #expect(feat.hasPrefix("211")); #expect(c.readLine().contains("EVERYTHING"))
        while !c.readLine().hasPrefix("211") {} // end FEAT block
        c.send("SITE EVERYTHING SEARCH hello"); #expect(c.readLine().hasPrefix("200"))
        c.send("SITE EVERYTHING QUERY"); let result = c.readLine(); #expect(result.contains("hello.txt")); c.send("QUIT"); #expect(c.readLine().hasPrefix("221"))
    }

    @Test func unauthenticatedAndDownloadPolicy() throws {
        let server = ETPServer(service: etpFixture(), configuration: .init(port: 0, allowDownloads: false))
        try server.start(); defer { server.stop() }
        let c = try ETPConnection(port: server.port); _ = c.readLine()
        c.send("RETR /tmp/nope"); #expect(c.readLine().hasPrefix("550"))
    }

    @Test func passiveRetrStreamsFixtureFile() throws {
        let fixture = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("everything-etp-\(UUID().uuidString).txt")
        let contents = Data("ETP payload ✓\n".utf8)
        try contents.write(to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let server = ETPServer(service: etpFixture(), configuration: .init(port: 0, allowDownloads: true))
        try server.start(); defer { server.stop() }
        let c = try ETPConnection(port: server.port); #expect(c.readLine().hasPrefix("220"))
        c.send("PASV")
        let passive = c.readLine(); #expect(passive.hasPrefix("227"))
        let dataFD = try c.openPassiveData(from: passive)
        c.send("RETR \(fixture.path)")
        #expect(c.readLine().hasPrefix("150"))
        #expect(c.readData(dataFD) == contents)
        #expect(c.readLine().hasPrefix("226"))
        c.send("QUIT"); #expect(c.readLine().hasPrefix("221"))
    }

    @Test func clientAuthenticatesAndQueriesServer() throws {
        let server = ETPServer(service: etpFixture(), configuration: .init(port: 0, username: "u", password: "p"))
        try server.start(); defer { server.stop() }
        let client = ETPClient(configuration: .init(host: "127.0.0.1", port: server.port, username: "u", password: "p"))
        let result = try client.query(IPCQueryParams(search: "hello"))
        #expect(result.items.contains { $0.name == "hello.txt" })
    }
}
