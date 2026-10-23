import Foundation
import EverythingCore
import EverythingIPC
import EverythingServers

/// Owns the long-lived index, persistence, monitor, IPC, and optional network services.
/// UI code talks to this object instead of reaching into the core directly.
public final class AppEngine: @unchecked Sendable {
    public let settings: Settings
    public let supportDirectory: URL
    public let databaseURL: URL
    public let journalURL: URL
    public let runHistoryURL: URL
    public let index: Index
    public let search: SearchEngine
    public let journal: IndexJournal
    public let runHistory: RunHistory
    public let omissions: OmissionStore
    public let temporaryOmissions: OmissionStore
    public let monitor: ChangeMonitor
    public let service: EngineService
    public let socketPath: String
    public private(set) var ipc: IPCServer?
    public private(set) var http: HTTPServer?
    public private(set) var etp: ETPServer?
    public private(set) var netIndex: NetIndexServer?
    public private(set) var isRunning = false
    public private(set) var isScanning = false
    public var log: ((String) -> Void)? {
        didSet { monitor.log = log; ipc?.log = log; http?.log = log; etp?.log = log; netIndex?.log = log }
    }

    private let lock = NSLock()
    private let scanQueue = DispatchQueue(label: "everything.app.initial-scan", qos: .utility)
    private let scanGroup = DispatchGroup()
    private let volumeProvider: @Sendable () -> [VolumeInfo]
    private var scanTask: DispatchWorkItem?

    public init(settings: Settings = Settings(), supportDirectory: URL = AppPaths.supportDirectory,
                volumeProvider: @escaping @Sendable () -> [VolumeInfo] = { Volumes.mounted() }) {
        self.settings = settings
        self.supportDirectory = supportDirectory
        self.volumeProvider = volumeProvider
        databaseURL = supportDirectory.appendingPathComponent("Everything.db")
        journalURL = supportDirectory.appendingPathComponent("Journal.db")
        runHistoryURL = supportDirectory.appendingPathComponent("Run History.csv")
        let preferredSocket = supportDirectory.appendingPathComponent("everything.sock").path
        socketPath = preferredSocket.utf8.count < 100 ? preferredSocket : (NSTemporaryDirectory() as NSString).appendingPathComponent("everything-\(UUID().uuidString).sock")
        if let loaded = try? IndexDB.load(from: databaseURL) {
            index = loaded
        } else {
            index = Index()
        }
        let maxJournalKB = max(64, settings.int("journal_max_size"))
        journal = IndexJournal.load(from: journalURL, maxKB: maxJournalKB) ?? IndexJournal(maxKB: maxJournalKB)
        runHistory = RunHistory.load(from: runHistoryURL)
        omissions = OmissionStore.load(from: supportDirectory.appendingPathComponent("Omit Results.csv"))
        temporaryOmissions = OmissionStore(temporary: true)
        search = SearchEngine(index: index)
        search.runHistory = runHistory
        search.recentChanges = journal
        search.omissions = omissions
        search.tempOmissions = temporaryOmissions
        monitor = ChangeMonitor(index: index, journal: journal)
        service = EngineService(engine: search)
        service.journal = journal
        service.runHistory = runHistory
        service.dbLoaded = { [weak index] in index?.dbLoaded ?? false }
    }

    public func start(scan: Bool = true, servers: Bool = true) throws {
        lock.lock(); defer { lock.unlock() }
        guard !isRunning else { return }
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        wireService()
        let needsInitialScan = scan && !index.dbLoaded
        if !needsInitialScan {
            startMonitors()
        }
        let server = IPCServer(path: socketPath, service: service)
        server.log = log
        try server.start()
        ipc = server
        if servers && settings.bool("http_server_enabled") {
            let config = HTTPServer.Configuration(bindAddress: settings.string("http_server_bind").isEmpty ? "127.0.0.1" : settings.string("http_server_bind"),
                                                  port: UInt16(max(0, settings.int("http_server_port"))),
                                                  username: settings.string("http_server_username"), password: settings.string("http_server_password"),
                                                  allowDownloads: settings.bool("http_server_allow_file_download"),
                                                  itemsPerPage: max(1, settings.int("http_server_items_per_page")))
            let httpServer = HTTPServer(service: service, configuration: config)
            httpServer.log = log
            try httpServer.start(); http = httpServer
        }
        if servers && settings.bool("etp_server_enabled") {
            let config = ETPServer.Configuration(bindAddress: settings.string("etp_server_bind").isEmpty ? "127.0.0.1" : settings.string("etp_server_bind"),
                                                  port: UInt16(max(0, settings.int("etp_server_port"))),
                                                  username: settings.string("etp_server_username"), password: settings.string("etp_server_password"),
                                                  allowDownloads: settings.bool("etp_server_allow_file_download"))
            let etpServer = ETPServer(service: service, configuration: config)
            etpServer.log = log
            try etpServer.start(); etp = etpServer
        }
        if servers && settings.bool("everything_server_enabled") {
            let config = NetIndexServer.Configuration(bindAddress: settings.string("everything_server_bind").isEmpty ? "127.0.0.1" : settings.string("everything_server_bind"),
                                                       port: UInt16(max(0, settings.int("everything_server_port"))),
                                                       users: parseNetworkUsers(settings.string("everything_server_users")),
                                                       includeOnly: settings.list("everything_server_include_only"))
            let server = NetIndexServer(service: service, configuration: config)
            server.log = log
            try server.start(); netIndex = server
        }
        isRunning = true
        if needsInitialScan {
            isScanning = true
            scanGroup.enter()
            let task = DispatchWorkItem { [weak self] in
                defer { self?.scanGroup.leave() }
                self?.scanConfiguredVolumes()
            }
            scanTask = task
            scanQueue.async(execute: task)
        }
    }

    public func stop() {
        lock.lock()
        guard isRunning else { lock.unlock(); return }
        scanTask?.cancel()
        monitor.stopAll(); http?.stop(); http = nil; etp?.stop(); etp = nil; netIndex?.stop(); netIndex = nil; ipc?.stop(); ipc = nil
        isRunning = false
        lock.unlock()
        scanGroup.wait()
        try? save()
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try IndexDB.save(index, to: databaseURL)
        try journal.save(to: journalURL)
        try runHistory.save(to: runHistoryURL)
        try omissions.save(to: supportDirectory.appendingPathComponent("Omit Results.csv"))
        index.dbLoaded = true
    }

    public func rebuild() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let roots = self.index.read { self.index.roots }
            for root in roots {
                let devices = Volumes.deviceID(of: root.path).map { Set([$0]) } ?? []
                _ = VolumeScanner(index: self.index, rules: .none, allowedDevices: devices).scan(rootPath: root.path, rootItem: root.item)
            }
            self.index.dbLoaded = true
            try? self.save()
        }
    }

    private func startMonitors() {
        let roots = index.read { index.roots }
        for root in roots where root.monitor {
            monitor.start(root: root, sinceEventID: root.lastEventID == 0 ? nil : root.lastEventID)
        }
    }

    private func scanConfiguredVolumes() {
        let volumes = Volumes.selected(from: volumeProvider(), settings: settings)
        let task = scanTask
        for volume in volumes {
            guard !(task?.isCancelled ?? true) else { break }
            let root = index.write {
                index.addRoot(kind: volume.isNetwork ? .network : .volume, path: volume.mountPoint, label: volume.name,
                              uuid: volume.uuid, deviceID: volume.deviceID, fileSystem: volume.fileSystem)
            }
            _ = VolumeScanner(index: index, rules: .none, allowedDevices: volume.allDeviceIDs).scan(
                rootPath: volume.mountPoint, rootItem: root.item, cancel: { task?.isCancelled ?? true })
        }
        lock.lock()
        let shouldPublish = isRunning && !(task?.isCancelled ?? true)
        if shouldPublish { index.dbLoaded = true; startMonitors() }
        isScanning = false
        scanTask = nil
        lock.unlock()
        if shouldPublish { try? save() }
    }

    private func wireService() {
        service.onRebuildDB = { [weak self] in self?.rebuild() }
        service.onSaveDB = { [weak self] in try? self?.save() }
        service.onSaveRunHistory = { [weak self] in try? self?.runHistory.save(to: self?.runHistoryURL ?? AppPaths.runHistoryFile) }
        service.onExit = { [weak self] in self?.stop() }
        service.onRescanAll = { [weak self] in self?.rebuild() }
        service.onMonitorPause = { [weak self] paused in paused ? self?.monitor.pause() : self?.monitor.resume() }
        service.statistics = { [weak self] in
            guard let self else { return [:] }
            let s = self.monitor.statistics
            return ["monitor.created": String(s.created), "monitor.removed": String(s.removed), "monitor.modified": String(s.modified), "monitor.events": String(s.events)]
        }
    }

    private func parseNetworkUsers(_ value: String) -> [String: String] {
        var users: [String: String] = [:]
        for pair in value.split(separator: ";") {
            let parts = pair.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, !parts[0].isEmpty { users[parts[0]] = parts[1] }
        }
        return users
    }
}
