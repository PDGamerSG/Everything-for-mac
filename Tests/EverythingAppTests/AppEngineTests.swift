import Foundation
import Testing
@testable import Everything
import EverythingCore
import EverythingIPC

@Suite(.serialized) struct AppEngineTests {
    @Test func startsIPCAndAnswersVersionWithoutScanning() throws {
        let support = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("everything-app-\(UUID().uuidString)")
        let settings = Settings()
        let engine = AppEngine(settings: settings, supportDirectory: support)
        try engine.start(scan: false, servers: false)
        defer { engine.stop() }
        let client = IPCClient(path: engine.socketPath)
        #expect(try client.version() == everythingVersion)
        #expect(try client.send(IPCRequest(kind: .isDBLoaded)).bool == false)
        #expect(engine.isRunning)
    }

    @Test func savesAndReloadsDatabase() throws {
        let support = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("everything-app-\(UUID().uuidString)")
        let settings = Settings()
        let first = AppEngine(settings: settings, supportDirectory: support)
        let root = first.index.addRoot(kind: .folder, path: support.path, label: "Fixture")
        first.index.store.add(ItemRecord(name: "hello.txt", parent: root.item, size: 9))
        try first.save()
        let second = AppEngine(settings: settings, supportDirectory: support)
        #expect(second.index.dbLoaded)
        #expect(second.index.lookup(path: support.appendingPathComponent("hello.txt").path) != nil)
    }

    @Test func startsConfiguredETPServer() throws {
        let support = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("everything-app-\(UUID().uuidString)")
        let settings = Settings()
        settings.set("etp_server_enabled", true)
        settings.set("etp_server_port", 0)
        let engine = AppEngine(settings: settings, supportDirectory: support)
        try engine.start(scan: false, servers: true)
        defer { engine.stop() }
        #expect(engine.etp != nil)
        #expect(engine.etp?.port ?? 0 > 0)
    }

    @Test func startsConfiguredNetworkIndexServer() throws {
        let support = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("everything-net-(UUID().uuidString)")
        let settings = Settings()
        settings.set("everything_server_enabled", true)
        settings.set("everything_server_port", 0)
        settings.set("everything_server_users", "user:secret")
        let engine = AppEngine(settings: settings, supportDirectory: support)
        try engine.start(scan: false, servers: true)
        defer { engine.stop() }
        #expect(engine.netIndex != nil)
        #expect(engine.netIndex?.port ?? 0 > 0)
    }

    @Test @MainActor func buildsSearchWindow() throws {
        let engine = AppEngine(settings: Settings(), supportDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("everything-ui-\(UUID().uuidString)"))
        let controller = SearchWindowController(engine: engine)
        controller.loadWindow()
        #expect(controller.window != nil)
        #expect(controller.searchField != nil)
        #expect(controller.tableView?.numberOfColumns == 4)
    }

    @Test @MainActor func buildsApplicationMenu() throws {
        let engine = AppEngine(settings: Settings(), supportDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("everything-menu-\(UUID().uuidString)"))
        let menu = MainMenuController(engine: engine).makeMenu()
        #expect(menu.item(withTitle: "File") != nil)
        #expect(menu.item(withTitle: "Search") != nil)
        #expect(menu.item(withTitle: "Index") != nil)
        #expect(menu.item(withTitle: "Help") != nil)
    }

    @Test func parsesAppCommandLine() throws {
        let options = try AppCommandLine.parse(["Everything", "-search", "report 2026", "-startup", "-rescan", "-instance", "work"])
        #expect(options.search == "report 2026")
        #expect(options.startup)
        #expect(options.rescan)
        #expect(options.instance == "work")
        #expect(try AppCommandLine.parse(["Everything", "-url", "es:invoice"]).search == "invoice")
    }

    @Test func rejectsUnknownAppSwitch() {
        #expect(throws: AppCommandLine.Error.self) { try AppCommandLine.parse(["Everything", "-not-real"]) }
    }

    @Test func scansInitialVolumeInBackgroundAndPublishesResults() throws {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("everything-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("indexed".utf8).write(to: rootURL.appendingPathComponent("indexed.txt"))
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let settings = Settings()
        settings.set("volumes", rootURL.path)
        let volume = VolumeInfo(name: "Fixture", mountPoint: rootURL.path, deviceID: Volumes.deviceID(of: rootURL.path) ?? 0)
        let support = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("everything-scan-support-\(UUID().uuidString)")
        let engine = AppEngine(settings: settings, supportDirectory: support, volumeProvider: { [volume] })
        let startedAt = Date()
        try engine.start(scan: true, servers: false)
        #expect(Date().timeIntervalSince(startedAt) < 0.5)
        #expect(engine.isScanning)
        defer { engine.stop() }

        for _ in 0..<100 where engine.isScanning { Thread.sleep(forTimeInterval: 0.01) }
        #expect(!engine.isScanning)
        #expect(engine.index.lookup(path: rootURL.appendingPathComponent("indexed.txt").path) != nil)
        #expect(engine.index.dbLoaded)
    }
}
