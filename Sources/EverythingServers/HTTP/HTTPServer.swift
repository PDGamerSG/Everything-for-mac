import Foundation
import Darwin
import EverythingCore
import EverythingIPC

/// HTTP/1.1 JSON/search endpoint and controlled file download server.
public final class HTTPServer: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var bindAddress: String
        public var port: UInt16
        public var username: String
        public var password: String
        public var allowDownloads: Bool
        public var downloadRoots: [String]
        public var itemsPerPage: Int
        public init(bindAddress: String = "127.0.0.1", port: UInt16 = 8080,
                    username: String = "", password: String = "", allowDownloads: Bool = true,
                    downloadRoots: [String] = [], itemsPerPage: Int = 32) {
            self.bindAddress = bindAddress; self.port = port; self.username = username; self.password = password
            self.allowDownloads = allowDownloads
            self.downloadRoots = downloadRoots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            self.itemsPerPage = max(1, itemsPerPage)
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
    private let acceptQueue = DispatchQueue(label: "everything.http.accept", qos: .utility)
    private let workQueue = DispatchQueue(label: "everything.http.work", qos: .utility, attributes: .concurrent)
    private let stateLock = NSLock()

    public init(service: EngineService, configuration: Configuration = Configuration()) {
        self.service = service; self.configuration = configuration; self.port = configuration.port
    }
    deinit { stop() }

    public func start() throws {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !isRunning else { return }
        guard let address = inetAddress(configuration.bindAddress) else { throw ServerError.invalidAddress }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket(errno) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var endpoint = sockaddr_in()
        endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); endpoint.sin_family = sa_family_t(AF_INET)
        endpoint.sin_port = configuration.port.bigEndian; endpoint.sin_addr = address
        let bound = withUnsafePointer(to: &endpoint) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { let e = errno; close(fd); throw ServerError.bind(e) }
        guard listen(fd, 64) == 0 else { let e = errno; close(fd); throw ServerError.listen(e) }
        var actual = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) } }
        port = UInt16(bigEndian: actual.sin_port); listenFD = fd
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        readSource.setEventHandler { [weak self] in self?.acceptPending() }
        readSource.setCancelHandler { close(fd) }; readSource.resume(); source = readSource; isRunning = true
        log?("HTTP listening on \(configuration.bindAddress):\(port)")
    }

    public func stop() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard isRunning else { return }
        source?.cancel(); source = nil; listenFD = -1; isRunning = false
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }
            workQueue.async { [weak self] in self?.serve(client) }
        }
    }
    private struct Request { var method: String; var target: String; var headers: [String: String] }
    private func serve(_ fd: Int32) { defer { close(fd) }; guard let request = readRequest(fd) else { return }; _ = writeAll(fd, route(request)) }
    private func readRequest(_ fd: Int32) -> Request? {
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 1_048_576 {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return nil }; data.append(buffer, count: n)
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard let text = String(data: data, encoding: .utf8), let header = text.components(separatedBy: "\r\n\r\n").first else { return nil }
        let lines = header.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ", maxSplits: 2).map(String.init); guard parts.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() { guard let colon = line.firstIndex(of: ":") else { continue }; headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
        return Request(method: parts[0].uppercased(), target: parts[1], headers: headers)
    }

    private func route(_ request: Request) -> Data {
        guard request.method == "GET" || request.method == "HEAD" else { return response(405, "Method Not Allowed", Data()) }
        guard authorized(request) else { return response(401, "Unauthorized", Data(), extra: ["WWW-Authenticate": "Basic realm=Everything"]) }
        guard let components = URLComponents(string: "http://localhost\(request.target)") else { return response(400, "Bad Request", Data()) }
        switch components.path {
        case "/json", "/api/search": return jsonResponse(components.queryItems ?? [], head: request.method == "HEAD")
        case "/download": return downloadResponse(components.queryItems ?? [], head: request.method == "HEAD")
        case "/", "/index.html":
            let html = "<html><head><title>Everything</title></head><body><form action=\"/json\"><input name=\"search\" autofocus><button>Search</button></form></body></html>"
            return response(200, "OK", Data(html.utf8), contentType: "text/html; charset=utf-8", head: request.method == "HEAD")
        default: return response(404, "Not Found", Data())
        }
    }
    private func authorized(_ request: Request) -> Bool {
        guard !configuration.username.isEmpty || !configuration.password.isEmpty else { return true }
        let expected = Data("\(configuration.username):\(configuration.password)".utf8).base64EncodedString()
        return request.headers["authorization"] == "Basic \(expected)"
    }
    private func jsonResponse(_ items: [URLQueryItem], head: Bool) -> Data {
        var query = IPCQueryParams(search: value("search", items) ?? value("q", items) ?? "")
        query.columns = (value("columns", items) ?? "name,path,full-path").split(separator: ",").map { QueryParser.canonical(String($0)) }
        query.sort = value("sort", items).map(QueryParser.canonical); query.ascending = bool("ascending", items)
        query.offset = Int(value("offset", items) ?? "0") ?? 0; query.count = Int(value("count", items) ?? String(configuration.itemsPerPage)) ?? configuration.itemsPerPage
        query.matchCase = bool("case", items); query.matchWholeWord = bool("whole", items); query.matchPath = bool("path", items); query.regex = bool("regex", items)
        query.highlight = bool("highlight", items) ?? false; query.filter = value("filter", items)
        guard let result = service.runQuery(query).query else { return response(500, "Internal Server Error", Data()) }
        let rows: [[String: Any]] = result.items.map { item in
            var row: [String: Any] = ["type": item.type, "name": item.name, "path": item.path, "fullPath": item.fullPath]
            if let size = item.size { row["size"] = size }; if let date = item.dateModified { row["dateModified"] = date }
            if let ext = item.extensionName { row["extension"] = ext }; if let attrs = item.attributes { row["attributes"] = attrs }
            if let props = item.properties { row["properties"] = props }; if let highlighted = item.highlightedName { row["highlightedName"] = highlighted }
            return row
        }
        let object: [String: Any] = ["totalResults": result.totalResults, "totalFiles": result.totalFiles, "totalFolders": result.totalFolders, "results": rows]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]) else { return response(500, "Internal Server Error", Data()) }
        return response(200, "OK", data, contentType: "application/json; charset=utf-8", head: head)
    }
    private func downloadResponse(_ items: [URLQueryItem], head: Bool) -> Data {
        guard configuration.allowDownloads else { return response(403, "Forbidden", Data()) }
        guard let raw = value("path", items), !raw.isEmpty else { return response(400, "Bad Request", Data()) }
        let decoded = raw.removingPercentEncoding ?? raw
        guard !decoded.split(separator: "/", omittingEmptySubsequences: true).contains("..") else { return response(400, "Bad Request", Data()) }
        let url = URL(fileURLWithPath: decoded).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path), isAllowedDownload(url.path), let data = try? Data(contentsOf: url) else { return response(404, "Not Found", Data()) }
        let filename = url.lastPathComponent.replacingOccurrences(of: "\"", with: "")
        return response(200, "OK", data, contentType: mimeType(url.pathExtension), head: head, extra: ["Content-Disposition": "attachment; filename=\"\(filename)\""])
    }
    private func isAllowedDownload(_ path: String) -> Bool {
        guard !configuration.downloadRoots.isEmpty else { return true }
        return configuration.downloadRoots.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
    private func value(_ key: String, _ items: [URLQueryItem]) -> String? { items.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }?.value }
    private func bool(_ key: String, _ items: [URLQueryItem]) -> Bool? {
        guard let value = value(key, items)?.lowercased() else { return nil }
        if ["1", "true", "yes", "on"].contains(value) { return true }; if ["0", "false", "no", "off"].contains(value) { return false }; return nil
    }
    private func response(_ status: Int, _ reason: String, _ body: Data, contentType: String = "text/plain; charset=utf-8", head: Bool = false, extra: [String: String] = [:]) -> Data {
        var headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nContent-Type: \(contentType)\r\nConnection: close\r\n"
        for (key, value) in extra { headers += "\(key): \(value)\r\n" }; headers += "\r\n"
        return Data(headers.utf8) + (head ? Data() : body)
    }
    private func inetAddress(_ string: String) -> in_addr? { var address = in_addr(); return inet_aton(string, &address) == 0 ? nil : address }
    private func mimeType(_ ext: String) -> String {
        switch ext.lowercased() { case "txt", "log", "csv": return "text/plain; charset=utf-8"; case "html", "htm": return "text/html; charset=utf-8"; case "json": return "application/json"; case "jpg", "jpeg": return "image/jpeg"; case "png": return "image/png"; case "pdf": return "application/pdf"; default: return "application/octet-stream" }
    }
}

private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var sent = 0
    return data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return true }
        while sent < data.count { let n = Darwin.write(fd, base.advanced(by: sent), data.count - sent); if n <= 0 { return false }; sent += n }
        return true
    }
}
