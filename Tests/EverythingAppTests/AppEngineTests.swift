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
}
