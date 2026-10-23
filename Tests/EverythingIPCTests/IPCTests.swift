import Testing
import Foundation
@testable import EverythingIPC
@testable import EverythingCore

final class EchoService: IPCService {
    var received: [IPCRequest] = []
    func handle(_ request: IPCRequest, completion: @escaping (IPCResponse) -> Void) {
        received.append(request)
        switch request.kind {
        case .version: var r = IPCResponse(); r.version = "test"; completion(r)
        case .query:
            var r = IPCResponse()
            let big = (0..<20_000).map { IPCItem(type: "file", name: "file\($0).txt", path: "/tmp/dir\($0)", fullPath: "/tmp/dir\($0)/file\($0).txt", itemID: Int32($0)) }
            r.query = IPCQueryResult(totalFiles: big.count, totalFolders: 0, totalResults: big.count, items: big, generation: 1, seconds: 0, errors: [])
            completion(r)
        default: completion(.value(request.path ?? ""))
        }
    }
}

@Suite(.serialized) struct IPCTests {
    /// Waits for an async service response.
    func call(_ service: IPCService, _ r: IPCRequest) -> IPCResponse {
        let sema = DispatchSemaphore(value: 0)
        var out = IPCResponse.failure("none")
        service.handle(r) { out = $0; sema.signal() }
        _ = sema.wait(timeout: .now() + 10)
        return out
    }
    func tempSocket() -> String { (NSTemporaryDirectory() as NSString).appendingPathComponent("evt-\(UUID().uuidString.prefix(8)).sock") }

    @Test func roundTripAndLargeFrames() throws {
        let path = tempSocket()
        let service = EchoService()
        let server = IPCServer(path: path, service: service)
        try server.start()
        defer { server.stop() }
        let client = IPCClient(path: path)
        #expect(try client.version() == "test")
        #expect(IPCClient.isRunning(path: path))
        let result = try client.query(IPCQueryParams(search: "x"))
        #expect(result.items.count == 20_000)
        #expect(result.items[19_999].fullPath == "/tmp/dir19999/file19999.txt")
        var r = IPCRequest(kind: .runCountGet); r.path = "/a/b"
        #expect(try client.send(r).string == "/a/b")
        #expect(service.received.count == 4)
        // multiple sequential clients
        for _ in 0..<5 { let c = IPCClient(path: path); #expect(try c.version() == "test") }
        // concurrent clients
        let group = DispatchGroup()
        var ok = 0
        let lock = NSLock()
        for _ in 0..<8 { group.enter(); DispatchQueue.global().async { if (try? IPCClient(path: path).version()) == "test" { lock.lock(); ok += 1; lock.unlock() }; group.leave() } }
        group.wait()
        #expect(ok == 8)
    }

    @Test func clientFailsWhenNoServer() {
        let path = tempSocket()
        let c = IPCClient(path: path)
        c.timeoutMs = 500
        #expect(throws: IPCError.self) { try c.version() }
        #expect(!IPCClient.isRunning(path: path))
    }

    @Test func engineServiceQuery() throws {
        let index = Index()
        let root = index.addRoot(kind: .volume, path: "/", label: "x").item
        let s = index.store
        let d = s.add(ItemRecord(name: "Docs", parent: root, flags: [.folder]))
        s.add(ItemRecord(name: "Alpha.txt", parent: d, size: 10, dateModified: 5))
        s.add(ItemRecord(name: "beta.txt", parent: d, size: 20, dateModified: 6))
        s.add(ItemRecord(name: "gamma.jpg", parent: root, size: 30, dateModified: 7))
        let engine = SearchEngine(index: index)
        let service = EngineService(engine: engine)
        let rh = RunHistory(); rh.increment("/Docs/beta.txt"); service.runHistory = rh
        service.filters = FilterStore()
        let journal = IndexJournal(); service.journal = journal
        var q = IPCQueryParams(search: "txt")
        q.columns = ["size", "date-modified", "run-count", "attributes"]
        q.highlight = true
        q.sort = "size"; q.ascending = false
        let r = service.runQuery(q).query!
        #expect(r.totalResults == 2)
        #expect(r.items.map { $0.name } == ["beta.txt", "Alpha.txt"])
        #expect(r.items[1].highlightedName == "Alpha.*txt*")
        #expect(r.items[0].runCount == 1 && r.items[1].runCount == 0)
        #expect(r.items[0].size == 20 && r.items[0].dateModified == 6)
        #expect(r.items[0].attributes == "N")
        #expect(r.totalSize == 30)
        // filter by name
        var f = IPCQueryParams(search: ""); f.filter = "Picture"
        #expect(service.runQuery(f).query!.items.map { $0.name } == ["gamma.jpg"])
        // offset/count
        var oc = IPCQueryParams(search: ""); oc.offset = 1; oc.count = 2; oc.sort = "name"
        let p = service.runQuery(oc).query!
        #expect(p.items.count == 2 && p.totalResults == 5)
        // run count ops through handle()
        var inc = IPCRequest(kind: .runCountInc); inc.path = "/Docs/Alpha.txt"
        var got: IPCResponse? = call(service, inc)
        #expect(got?.int == 1)
        var get = IPCRequest(kind: .runCountGet); get.path = "/Docs/Alpha.txt"
        got = call(service, get)
        #expect(got?.int == 1)
        // folder size
        var fs = IPCRequest(kind: .folderSize); fs.path = "/Docs"
        got = call(service, fs)
        #expect(got?.uint64 == 30)
        // journal query + watch
        journal.append(.fileCreate, name: "n.txt", path: "/Docs")
        var jr = IPCRequest(kind: .journal); var jp = IPCJournalParams(); jp.text = "n.txt"; jr.journal = jp
        got = call(service, jr)
        #expect(got?.journal?.entries.count == 1)
        var watch = IPCRequest(kind: .journal); var wp = IPCJournalParams(); wp.watch = true; wp.timeoutMs = 3000; wp.text = "later.txt"; wp.fromChangeID = journal.nextChangeID; watch.journal = wp
        let sema = DispatchSemaphore(value: 0)
        var watched: IPCResponse? = nil
        service.handle(watch) { watched = $0; sema.signal() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { journal.append(.fileCreate, name: "later.txt", path: "/Docs") }
        #expect(sema.wait(timeout: .now() + 5) == .success)
        #expect(watched?.journal?.entries.first?.name == "later.txt")
        // statistics & roots
        got = call(service, IPCRequest(kind: .statistics))
        #expect(got?.dictionary?["files"] == "3")
        got = call(service, IPCRequest(kind: .roots))
        #expect(got?.roots?.first?.label == "x")
        #expect(EngineService.mark("a*b", [("a*b".startIndex)..<("a*b".index(after: "a*b".startIndex))]) == "*a***b")
    }

    @Test func endToEndOverSocket() throws {
        let index = Index()
        let root = index.addRoot(kind: .volume, path: "/", label: "x").item
        index.store.add(ItemRecord(name: "hello.txt", parent: root, size: 1))
        let service = EngineService(engine: SearchEngine(index: index))
        let path = tempSocket()
        let server = IPCServer(path: path, service: service)
        try server.start()
        defer { server.stop() }
        let client = IPCClient(path: path)
        let r = try client.query(IPCQueryParams(search: "hello"))
        #expect(r.items.map { $0.fullPath } == ["/hello.txt"])
        #expect(try client.version() == everythingVersion)
    }
}
