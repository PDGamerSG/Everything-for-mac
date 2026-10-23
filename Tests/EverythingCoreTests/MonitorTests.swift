import Testing
import Foundation
@testable import EverythingCore

@Suite(.serialized) struct MonitorTests {
    /// Waits until `cond` holds or `timeout` elapses.
    func wait(_ timeout: TimeInterval = 6, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.05) }
        return cond()
    }

    func setup() throws -> (Index, Root, ChangeMonitor, IndexJournal, URL, [IndexChange]) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("evt-mon-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "a".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: dir.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)
        let real = URL(fileURLWithPath: dir.path).resolvingSymlinksInPath()   // /private/var/... vs /var/...
        let index = Index()
        let root = index.addRoot(kind: .folder, path: real.path, label: "fixture")
        VolumeScanner(index: index).scan(rootPath: real.path, rootItem: root.item)
        let journal = IndexJournal()
        let monitor = ChangeMonitor(index: index, journal: journal)
        monitor.latency = 0.1
        return (index, root, monitor, journal, real, [])
    }

    @Test func createRenameMoveDeleteModify() throws {
        let (index, root, monitor, journal, dir, _) = try setup()
        let lock = NSLock()
        var changes: [IndexChange] = []
        monitor.onChanges = { c in lock.lock(); changes.append(contentsOf: c); lock.unlock() }
        monitor.start(root: root)
        defer { monitor.stopAll(); try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        // create
        let newFile = dir.appendingPathComponent("new.txt")
        try "hello".write(to: newFile, atomically: true, encoding: .utf8)
        #expect(wait { index.lookup(path: newFile.path) != nil })
        let id = index.lookup(path: newFile.path)!
        #expect(index.store.size(id) == 5)
        // modify
        try "hello world".write(to: newFile, atomically: false, encoding: .utf8)
        #expect(wait { index.store.size(id) == 11 })
        // rename (same id kept)
        let renamed = dir.appendingPathComponent("renamed.txt")
        try fm.moveItem(at: newFile, to: renamed)
        #expect(wait { index.lookup(path: renamed.path) == id })
        #expect(index.lookup(path: newFile.path) == nil)
        // move into sub (same id kept)
        let moved = dir.appendingPathComponent("sub/renamed.txt")
        try fm.moveItem(at: renamed, to: moved)
        #expect(wait { index.lookup(path: moved.path) == id })
        #expect(index.store.fullPath(id) == moved.path)
        // delete
        try fm.removeItem(at: moved)
        #expect(wait { index.lookup(path: moved.path) == nil })
        #expect(!index.store.isAlive(id))
        // new folder with contents
        let nd = dir.appendingPathComponent("newdir/inner")
        try fm.createDirectory(at: nd, withIntermediateDirectories: true)
        try "x".write(to: nd.appendingPathComponent("deep.txt"), atomically: true, encoding: .utf8)
        #expect(wait { index.lookup(path: nd.appendingPathComponent("deep.txt").path) != nil })
        // folder rename keeps descendants
        let nd2 = dir.appendingPathComponent("newdir2")
        try fm.moveItem(at: dir.appendingPathComponent("newdir"), to: nd2)
        #expect(wait { index.lookup(path: nd2.appendingPathComponent("inner/deep.txt").path) != nil })
        #expect(index.lookup(path: nd.path) == nil)
        monitor.flush()
        let actions = journal.all.map { $0.action }
        #expect(actions.contains(.fileCreate))
        #expect(actions.contains(.fileModify))
        #expect(actions.contains(.fileRename))
        #expect(actions.contains(.fileMove))
        #expect(actions.contains(.fileDelete))
        #expect(actions.contains(.folderCreate))
        #expect(actions.contains(.folderRename))
        let rename = journal.all.first { $0.action == .fileRename }!
        #expect(rename.name == "new.txt" && rename.newName == "renamed.txt")
        #expect(journal.dateRecentlyChanged(forPath: nd2.appendingPathComponent("inner/deep.txt").path) == 0) // created under old path
        #expect(journal.dateRecentlyChanged(forPath: nd2.path) > 0)
        lock.lock(); let count = changes.count; lock.unlock()
        #expect(count >= 8)
        #expect(monitor.statistics.created >= 2)
        #expect(monitor.statistics.renamed >= 2)
    }

    @Test func replayMissedChangesSinceEventID() throws {
        let (index, root, monitor, _, dir, _) = try setup()
        defer { try? FileManager.default.removeItem(at: dir) }
        let since = ChangeMonitor.currentEventID
        Thread.sleep(forTimeInterval: 0.2)
        // change while not monitoring
        let late = dir.appendingPathComponent("late.txt")
        try "late".write(to: late, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("a.txt"))
        Thread.sleep(forTimeInterval: 0.5)
        monitor.start(root: root, sinceEventID: since)
        defer { monitor.stopAll() }
        #expect(wait { index.lookup(path: late.path) != nil })
        #expect(wait { index.lookup(path: dir.appendingPathComponent("a.txt").path) == nil })
    }

    @Test func fastRescanFindsChanges() throws {
        let (index, root, _, journal, dir, _) = try setup()
        defer { try? FileManager.default.removeItem(at: dir) }
        Thread.sleep(forTimeInterval: 0.05)
        try "n".write(to: dir.appendingPathComponent("sub/n.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("sub/b.txt"))
        let changes = Rescan.fast(root: root, index: index, rules: .none, allowedDevices: [], journal: journal)
        #expect(changes.contains { if case .created = $0 { return true }; return false })
        #expect(changes.contains { if case .removed = $0 { return true }; return false })
        #expect(index.lookup(path: dir.appendingPathComponent("sub/n.txt").path) != nil)
        #expect(index.lookup(path: dir.appendingPathComponent("sub/b.txt").path) == nil)
    }

    @Test func journalQueriesAndPersistence() throws {
        let j = IndexJournal(maxKB: 1)
        for i in 0..<200 { j.append(i % 2 == 0 ? .fileCreate : .fileDelete, name: "file\(i).txt", path: "/tmp/dir\(i % 3)") }
        #expect(j.count < 200)   // trimmed to 1 KB
        #expect(j.nextChangeID == 201)
        let creates = j.query({ var q = IndexJournal.Query(); q.actions = [.fileCreate]; return q }())
        #expect(creates.allSatisfy { $0.action == .fileCreate })
        let txt = j.query({ var q = IndexJournal.Query(); q.text = "*9.txt"; return q }())
        #expect(!txt.isEmpty && txt.allSatisfy { $0.name.hasSuffix("9.txt") })
        let re = j.query({ var q = IndexJournal.Query(); q.text = "^file1\\d\\d\\.txt$"; q.regex = true; return q }())
        #expect(re.allSatisfy { $0.name.count == 11 })
        let first = j.firstChangeID
        let range = j.query({ var q = IndexJournal.Query(); q.fromChangeID = first + 1; q.toChangeID = first + 5; return q }())
        #expect(range.count == 4)
        j.append(.fileRename, name: "old.txt", path: "/tmp", newName: "new.txt", newPath: "/tmp")
        #expect(j.query({ var q = IndexJournal.Query(); q.text = "new.txt"; q.addedOnly = true; return q }()).count == 1)
        #expect(j.query({ var q = IndexJournal.Query(); q.text = "new.txt"; q.removedOnly = true; return q }()).count == 0)
        #expect(j.query({ var q = IndexJournal.Query(); q.text = "old.txt"; q.removedOnly = true; return q }()).count == 1)
        #expect(j.dateRecentlyChanged(forPath: "/tmp/new.txt") > 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("evt-journal-\(UUID().uuidString).db")
        try j.save(to: url)
        let loaded = IndexJournal.load(from: url, maxKB: 1)!
        #expect(loaded.count == j.count)
        #expect(loaded.nextChangeID == j.nextChangeID)
        #expect(loaded.journalID == j.journalID)
        #expect(loaded.dateRecentlyChanged(forPath: "/tmp/new.txt") > 0)
        try? FileManager.default.removeItem(at: url)
        var watched = 0
        let token = j.watch { _ in watched += 1 }
        j.append(.fileModify, name: "w.txt", path: "/tmp")
        j.unwatch(token)
        j.append(.fileModify, name: "w2.txt", path: "/tmp")
        #expect(watched == 1)
        #expect(j.exportCSV(j.all.suffix(1)).contains("File Modify,w2.txt,/tmp"))
    }

    @Test func firmlinkRemap() {
        #expect(ChangeMonitor.remapFirmlink("/System/Volumes/Data/Users/x/a.txt") == "/Users/x/a.txt")
        #expect(ChangeMonitor.remapFirmlink("/Users/x") == "/Users/x")
    }
}
