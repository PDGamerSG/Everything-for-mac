import Foundation
import Darwin
import EverythingCore
import EverythingIPC

/// A compact, authenticated network-index protocol used by Everything Server peers.
/// Control messages are UTF-8 JSON lines so the protocol remains inspectable with nc.
public struct NetIndexItem: Codable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var folder: Bool
    public var flags: UInt16
    public var size: UInt64
    public var dateModified: Int64

    public init(path: String, name: String, folder: Bool, flags: UInt16, size: UInt64, dateModified: Int64) {
        self.path = path; self.name = name; self.folder = folder; self.flags = flags
        self.size = size; self.dateModified = dateModified
    }
}

public struct NetIndexSnapshot: Codable, Equatable, Sendable {
    public var rootPath: String
    public var label: String
    public var generation: UInt64
    public var nextChangeID: UInt64
    public var items: [NetIndexItem]

    public init(rootPath: String, label: String, generation: UInt64, nextChangeID: UInt64, items: [NetIndexItem]) {
        self.rootPath = rootPath; self.label = label; self.generation = generation
        self.nextChangeID = nextChangeID; self.items = items
    }
}

public struct NetIndexJournalBatch: Codable, Equatable, Sendable {
    public var nextChangeID: UInt64
    public var entries: [JournalEntry]
    public init(nextChangeID: UInt64, entries: [JournalEntry]) { self.nextChangeID = nextChangeID; self.entries = entries }
}

public final class NetIndexServer: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var bindAddress: String
        public var port: UInt16
        public var users: [String: String]
        public var includeOnly: [String]
        public init(bindAddress: String = "127.0.0.1", port: UInt16 = 14630,
                    users: [String: String] = [:], includeOnly: [String] = []) {
            self.bindAddress = bindAddress; self.port = port; self.users = users
            self.includeOnly = includeOnly.map(Paths.normalize)
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
    private let stateLock = NSLock()
    private let acceptQueue = DispatchQueue(label: "everything.net-index.accept", qos: .utility)
    private let workQueue = DispatchQueue(label: "everything.net-index.work", qos: .utility, attributes: .concurrent)

    public init(service: EngineService, configuration: Configuration = Configuration()) {
        self.service = service; self.configuration = configuration; self.port = configuration.port
    }
    deinit { stop() }

    public func start() throws {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !isRunning else { return }
        guard let address = netIndexAddress(configuration.bindAddress) else { throw ServerError.invalidAddress }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket(errno) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var endpoint = sockaddr_in()
        endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); endpoint.sin_family = sa_family_t(AF_INET)
        endpoint.sin_port = configuration.port.bigEndian; endpoint.sin_addr = address
        let bound = withUnsafePointer(to: &endpoint) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        } }
        guard bound == 0 else { let e = errno; close(fd); throw ServerError.bind(e) }
        guard listen(fd, 64) == 0 else { let e = errno; close(fd); throw ServerError.listen(e) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var actual = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) } }
        port = UInt16(bigEndian: actual.sin_port); listenFD = fd
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        readSource.setEventHandler { [weak self] in self?.acceptPending() }
        readSource.setCancelHandler { close(fd) }; readSource.resume(); source = readSource; isRunning = true
        log?("Network index listening on (configuration.bindAddress):(port)")
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
            _ = fcntl(client, F_SETFL, 0)
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            workQueue.async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        let nonce = UUID().uuidString
        netIndexSendLine(fd, "HELLO \(nonce)")
        guard let authData = netIndexReadLine(fd), let auth = try? JSONDecoder().decode(NetIndexAuth.self, from: authData),
              authenticate(auth, nonce: nonce) else { netIndexSendLine(fd, "530 Authentication failed"); return }
        netIndexSendLine(fd, "200 Authenticated")
        while let data = netIndexReadLine(fd), let request = try? JSONDecoder().decode(NetIndexRequest.self, from: data) {
            switch request.command.uppercased() {
            case "SNAPSHOT":
                guard let payload = try? JSONEncoder().encode(NetIndexEnvelope(snapshot: makeSnapshot())) else { netIndexSendLine(fd, "451 Snapshot failed"); continue }
                netIndexSendLine(fd, payload)
            case "JOURNAL":
                let batch = makeJournal(since: request.since ?? 0)
                guard let payload = try? JSONEncoder().encode(NetIndexEnvelope(journal: batch)) else { netIndexSendLine(fd, "451 Journal failed"); continue }
                netIndexSendLine(fd, payload)
            case "QUIT": netIndexSendLine(fd, "221 Goodbye"); return
            default: netIndexSendLine(fd, "502 Command not implemented")
            }
        }
    }

    private func authenticate(_ auth: NetIndexAuth, nonce: String) -> Bool {
        guard let password = configuration.users[auth.username] ?? (configuration.users.isEmpty && auth.username.isEmpty ? "" : nil) else { return false }
        let expected = Hashes.hmacSHA256(key: Data(password.utf8), message: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
        return auth.proof.caseInsensitiveCompare(expected) == .orderedSame
    }

    private func makeSnapshot() -> NetIndexSnapshot {
        let index = service.engine.index
        return index.read {
            let roots = index.roots
            let sourceRoot = roots.first?.path ?? "/"
            let label = roots.first?.label ?? "Everything"
            let store = index.store
            var items: [NetIndexItem] = []
            items.reserveCapacity(store.liveCount)
            for i in 0..<store.slotCount {
                let id = ItemID(i)
                guard store.isAlive(id) else { continue }
                let path = store.fullPath(id)
                guard allowed(path) else { continue }
                items.append(NetIndexItem(path: path, name: store.name(id), folder: store.isFolder(id), flags: store.flags(id).rawValue,
                                          size: store.fileSize(id), dateModified: store.dateModified(id)))
            }
            return NetIndexSnapshot(rootPath: sourceRoot, label: label, generation: store.generation,
                                    nextChangeID: service.journal?.nextChangeID ?? 0, items: items)
        }
    }

    private func makeJournal(since: UInt64) -> NetIndexJournalBatch {
        guard let journal = service.journal else { return NetIndexJournalBatch(nextChangeID: 0, entries: []) }
        var query = IndexJournal.Query(); query.fromChangeID = since
        let entries = journal.query(query).filter { allowed($0.fullPath) || (!$0.newFullPath.isEmpty && allowed($0.newFullPath)) }
        return NetIndexJournalBatch(nextChangeID: journal.nextChangeID, entries: entries)
    }

    private func allowed(_ path: String) -> Bool {
        guard !configuration.includeOnly.isEmpty else { return true }
        let normalized = Paths.normalize(path)
        return configuration.includeOnly.contains { prefix in normalized == prefix || normalized.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/") }
    }
}

public final class NetIndexClient: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var host: String
        public var port: UInt16
        public var username: String
        public var password: String
        public var mountAs: String
        public init(host: String, port: UInt16 = 14630, username: String = "", password: String = "", mountAs: String = "/Network") {
            self.host = host; self.port = port; self.username = username; self.password = password; self.mountAs = Paths.normalize(mountAs)
        }
    }
    public enum ClientError: Error, Equatable { case socket(Int32), protocolError(String), authentication, server(String), invalidSnapshot }
    public let configuration: Configuration
    public init(configuration: Configuration) { self.configuration = configuration }

    @discardableResult
    public func syncSnapshot(into index: Index) throws -> UInt64 {
        let (fd, _) = try connectAndAuthenticate()
        defer { close(fd) }
        try send(fd, NetIndexRequest(command: "SNAPSHOT"))
        let envelope = try receive(fd)
        guard let snapshot = envelope.snapshot else { throw ClientError.invalidSnapshot }
        apply(snapshot, to: index)
        return snapshot.nextChangeID
    }

    public func syncJournal(since: UInt64, into index: Index) throws {
        let (fd, _) = try connectAndAuthenticate()
        defer { close(fd) }
        try send(fd, NetIndexRequest(command: "JOURNAL", since: since))
        let envelope = try receive(fd)
        guard let batch = envelope.journal else { throw ClientError.protocolError("missing journal") }
        apply(batch.entries, to: index)
    }

    private func connectAndAuthenticate() throws -> (Int32, String) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.socket(errno) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = configuration.port.bigEndian; guard let ip = netIndexAddress(configuration.host) else { close(fd); throw ClientError.protocolError("invalid address") }
        address.sin_addr = ip
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        } }
        guard connected == 0 else { let e = errno; close(fd); throw ClientError.socket(e) }
        var noSigPipe: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        guard let hello = netIndexReadLine(fd), let line = String(data: hello, encoding: .utf8), line.hasPrefix("HELLO ") else { close(fd); throw ClientError.protocolError("missing challenge") }
        let nonce = String(line.dropFirst(6))
        let proof = Hashes.hmacSHA256(key: Data(configuration.password.utf8), message: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
        let auth = NetIndexAuth(username: configuration.username, proof: proof)
        guard let data = try? JSONEncoder().encode(auth) else { close(fd); throw ClientError.protocolError("encode auth") }
        netIndexSendLine(fd, data)
        guard let result = netIndexReadLine(fd), String(data: result, encoding: .utf8)?.hasPrefix("200") == true else { close(fd); throw ClientError.authentication }
        return (fd, nonce)
    }

    private func send(_ fd: Int32, _ request: NetIndexRequest) throws {
        guard let data = try? JSONEncoder().encode(request) else { throw ClientError.protocolError("encode request") }
        netIndexSendLine(fd, data)
    }

    private func receive(_ fd: Int32) throws -> NetIndexEnvelope {
        guard let data = netIndexReadLine(fd) else { throw ClientError.protocolError("connection closed") }
        if let line = String(data: data, encoding: .utf8), line.hasPrefix("4") || line.hasPrefix("5") { throw ClientError.server(line) }
        guard let envelope = try? JSONDecoder().decode(NetIndexEnvelope.self, from: data) else { throw ClientError.protocolError("invalid response") }
        return envelope
    }

    private func apply(_ snapshot: NetIndexSnapshot, to index: Index) {
        let mount = configuration.mountAs
        index.write {
            let root: Root
            if let existing = index.roots.first(where: { $0.kind == .network && $0.path == mount }) {
                for child in index.store.children(of: existing.item) { index.store.remove(child) }
                root = existing
            } else {
                root = index.addRoot(kind: .network, path: mount, label: snapshot.label, itemName: mount)
            }
            for item in snapshot.items.sorted(by: { $0.path.filter({ $0 == "/" }).count < $1.path.filter({ $0 == "/" }).count }) {
                let local = remap(item.path, from: snapshot.rootPath, to: mount)
                guard local != mount else { continue }
                guard let parent = index.ensureFolder(path: Paths.parent(local)) else { continue }
                if let existing = index.lookup(path: local) {
                    index.store.update(existing, size: item.size, dateModified: item.dateModified, flags: ItemFlags(rawValue: item.flags))
                } else {
                    _ = index.store.add(ItemRecord(name: item.name, parent: parent, flags: ItemFlags(rawValue: item.flags), size: item.size, dateModified: item.dateModified))
                }
            }
            _ = root
        }
        index.dbLoaded = true
    }

    private func apply(_ entries: [JournalEntry], to index: Index) {
        index.write {
            for entry in entries {
                let oldPath = remap(entry.fullPath, from: "/", to: configuration.mountAs)
                let newPath = entry.newFullPath.isEmpty ? "" : remap(entry.newFullPath, from: "/", to: configuration.mountAs)
                switch entry.action {
                case .fileCreate, .folderCreate:
                    guard let parent = index.ensureFolder(path: Paths.parent(oldPath)), index.lookup(path: oldPath) == nil else { continue }
                    _ = index.store.add(ItemRecord(name: Paths.lastComponent(oldPath), parent: parent, flags: entry.action.isFolder ? [.folder] : [], size: entry.size))
                case .fileDelete, .folderDelete:
                    if let id = index.lookup(path: oldPath) { index.store.remove(id) }
                case .fileModify, .folderModify:
                    if let id = index.lookup(path: oldPath) { index.store.update(id, size: entry.size) }
                case .fileRename, .folderRename, .fileMove, .folderMove:
                    guard let id = index.lookup(path: oldPath), !newPath.isEmpty, let parent = index.ensureFolder(path: Paths.parent(newPath)) else { continue }
                    index.store.rename(id, to: Paths.lastComponent(newPath)); index.store.move(id, toParent: parent)
                }
            }
        }
    }

    private func remap(_ path: String, from source: String, to mount: String) -> String {
        let normalized = Paths.normalize(path), root = Paths.normalize(source)
        let suffix = normalized == root ? "" : String(normalized.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return suffix.isEmpty ? mount : Paths.join(mount, suffix)
    }
}

private struct NetIndexAuth: Codable { var username: String; var proof: String }
private struct NetIndexRequest: Codable { var command: String; var since: UInt64? = nil }
private struct NetIndexEnvelope: Codable { var snapshot: NetIndexSnapshot? = nil; var journal: NetIndexJournalBatch? = nil
    init(snapshot: NetIndexSnapshot? = nil, journal: NetIndexJournalBatch? = nil) { self.snapshot = snapshot; self.journal = journal }
}

private func netIndexAddress(_ value: String) -> in_addr? { var address = in_addr(); return inet_aton(value, &address) == 0 ? nil : address }
private func netIndexSendLine(_ fd: Int32, _ value: String) { netIndexSendLine(fd, Data(value.utf8)) }
private func netIndexSendLine(_ fd: Int32, _ data: Data) {
    var payload = data; payload.append(10)
    payload.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < payload.count {
            let count = Darwin.write(fd, base.advanced(by: offset), payload.count - offset)
            if count <= 0 { break }
            offset += count
        }
    }
}
private func netIndexReadLine(_ fd: Int32) -> Data? {
    var bytes: [UInt8] = []
    while bytes.count < 64 * 1024 * 1024 {
        var byte: UInt8 = 0; let count = Darwin.read(fd, &byte, 1)
        if count <= 0 { return bytes.isEmpty ? nil : Data(bytes) }
        if byte == 10 { return Data(bytes) }
        if byte != 13 { bytes.append(byte) }
    }
    return nil
}
