import Foundation
import Testing
import EverythingCore
import EverythingIPC
@testable import EverythingServers

private func networkFixture() -> (EngineService, Index, IndexJournal) {
    let index = Index()
    let root = index.addRoot(kind: .volume, path: "/", label: "Remote")
    let docs = index.store.add(ItemRecord(name: "Docs", parent: root.item, flags: [.folder]))
    index.store.add(ItemRecord(name: "hello.txt", parent: docs, size: 42))
    index.store.add(ItemRecord(name: "secret.txt", parent: root.item, size: 7))
    let journal = IndexJournal()
    let service = EngineService(engine: SearchEngine(index: index))
    service.journal = journal
    return (service, index, journal)
}

@Suite(.serialized) struct NetIndexTests {
    @Test func authenticatesFiltersSnapshotAndAppliesJournal() throws {
        let (service, index, journal) = networkFixture()
        let server = NetIndexServer(service: service, configuration: .init(port: 0, users: ["alice": "secret"], includeOnly: ["/Docs"]))
        try server.start(); defer { server.stop() }

        let clientIndex = Index()
        let client = NetIndexClient(configuration: .init(host: "127.0.0.1", port: server.port, username: "alice", password: "secret", mountAs: "/Remote"))
        let next = try client.syncSnapshot(into: clientIndex)
        #expect(clientIndex.lookup(path: "/Remote/Docs/hello.txt") != nil)
        #expect(clientIndex.lookup(path: "/Remote/secret.txt") == nil)

        let docs = try #require(index.lookup(path: "/Docs"))
        let added = index.store.add(ItemRecord(name: "new.txt", parent: docs, size: 3))
        #expect(added >= 0)
        journal.append(.fileCreate, name: "new.txt", path: "/Docs", size: 3)
        try client.syncJournal(since: next, into: clientIndex)
        #expect(clientIndex.lookup(path: "/Remote/Docs/new.txt") != nil)
    }

    @Test func rejectsWrongPassword() throws {
        let (service, _, _) = networkFixture()
        let server = NetIndexServer(service: service, configuration: .init(port: 0, users: ["alice": "secret"]))
        try server.start(); defer { server.stop() }
        let client = NetIndexClient(configuration: .init(host: "127.0.0.1", port: server.port, username: "alice", password: "wrong", mountAs: "/Remote"))
        #expect(throws: NetIndexClient.ClientError.self) { try client.syncSnapshot(into: Index()) }
    }
}
