import Testing
import Foundation
@testable import EverythingCore

@Suite struct FileListTests {
    @Test func efuRoundTrip() throws {
        let dm: Int64 = 1_700_000_000_000_000_000
        var list = FileList(entries: [
            FileListEntry(path: "/Users/x/a.txt", isFolder: false, size: 10, dateModified: dm, dateCreated: dm, attributes: 0x20),
            FileListEntry(path: "/Users/x/dir", isFolder: true),
            FileListEntry(path: "/Users/x/comma, \"quoted\".txt", isFolder: false, size: 1),
        ])
        let text = list.renderEFU()
        #expect(text.hasPrefix("Filename,Size,Date Modified,Date Created,Attributes\r\n"))
        #expect(text.contains("/Users/x/a.txt,10,\(Timestamps.toFiletime(dm)),\(Timestamps.toFiletime(dm)),32\r\n"))
        #expect(text.contains("/Users/x/dir,,,,16\r\n"))
        let back = FileList.parseEFU(text)
        #expect(back.entries == list.entries)
        // Windows-style EFU
        let win = "Filename,Size,Date Modified,Attributes\r\nC:\\Users\\x\\b.txt,5,2026-01-02T03:04:05,32\r\nC:\\Users\\x\\d\\,,,16\r\n"
        let w = FileList.parseEFU(win)
        #expect(w.entries.count == 2)
        #expect(w.entries[0].path == "/Users/x/b.txt")
        #expect(w.entries[0].dateModified == DateFormat.parse("2026-01-02T03:04:05"))
        #expect(w.entries[1].isFolder && w.entries[1].path == "/Users/x/d")
        // duplicates: last wins
        let dup = FileList.parseEFU("Filename,Size\r\n/a,1\r\n/a,2\r\n")
        #expect(dup.entries.count == 1 && dup.entries[0].size == 2)
        // text list
        let t = FileList.parseText("/tmp/one.txt\n\"/tmp/two.txt\"\n/tmp/dir/\n")
        #expect(t.entries.map { $0.path } == ["/tmp/one.txt", "/tmp/two.txt", "/tmp/dir"])
        #expect(t.entries[2].isFolder)
        list.removeDuplicates()
        #expect(list.entries.count == 3)
    }

    @Test func createFromDiskAndLoadIntoIndex() throws {
        let tree = try Fixtures.makeTree(files: 4, depth: 1, fanout: 1, unicode: false)
        defer { tree.cleanup() }
        let list = FileList.create(from: [tree.root.path])
        #expect(list.entries.count == tree.files + tree.folders + 1)
        let index = Index()
        let root = list.load(into: index, label: "test.efu")
        #expect(root.kind == .fileList)
        let p = tree.root.appendingPathComponent("file0_1.jpg").path
        let found = index.store.find(path: p, roots: [root.item])
        #expect(found.map { index.store.fullPath($0) } == p)
        #expect(found != nil)
        if let f = found { #expect(index.store.flags(f).contains(.fileList)); #expect(index.store.size(f) == 10) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("evt-\(UUID().uuidString).efu")
        try list.write(to: url)
        let read = try FileList.read(url)
        #expect(read.entries.count == list.entries.count)
        #expect(read.sourceURL == url)
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite struct ExportTests {
    func world() -> (Index, EvalContext, [ItemID]) {
        let index = Index()
        let root = index.addRoot(kind: .volume, path: "/", label: "x").item
        let s = index.store
        let d = s.add(ItemRecord(name: "docs", parent: root, flags: [.folder], dateModified: 1_700_000_000_000_000_000))
        let f = s.add(ItemRecord(name: "a, \"b\".txt", parent: d, size: 1234, dateModified: 1_700_000_000_000_000_000))
        let ctx = EvalContext(index: index, paths: PathTable(store: s, roots: [root]), properties: PropertyReader())
        return (index, ctx, [d, f])
    }

    @Test func formats() {
        let (_, ctx, ids) = world()
        var csv = Exporter(format: .csv, columns: ["name", "path", "size", "date-modified"])
        csv.dateFormat = .iso8601
        let c = csv.render(ids, ctx: ctx)
        #expect(c == "Name,Path,Size,Date Modified\r\ndocs,/,,\(DateFormat.iso(1_700_000_000_000_000_000))\r\n\"a, \"\"b\"\".txt\",/docs,1234,\(DateFormat.iso(1_700_000_000_000_000_000))\r\n")
        let txt = Exporter(format: .txt, columns: ["full-path"]).render(ids, ctx: ctx)
        #expect(txt == "/docs/\r\n/docs/a, \"b\".txt\r\n")
        let efu = Exporter(format: .efu).render(ids, ctx: ctx)
        #expect(efu.hasPrefix("Filename,Size,Date Modified,Date Created,Attributes\r\n/docs,,\(Timestamps.toFiletime(1_700_000_000_000_000_000)),,16\r\n"))
        let json = Exporter(format: .json, columns: ["name", "size", "date-modified"]).render(ids, ctx: ctx)
        #expect(json.contains("\"totalResults\" : 2"))
        #expect(json.contains("\"date_modified\""))
        #expect(json.contains("\"type\" : \"folder\""))
        let m3u = Exporter(format: .m3u8).render(ids, ctx: ctx)
        #expect(m3u.hasPrefix("#EXTM3U\r\n#EXTINF:-1,docs\r\n/docs\r\n"))
        let tsv = Exporter(format: .tsv, columns: ["name", "size"]).render([ids[1]], ctx: ctx)
        #expect(tsv == "Name\tSize\r\na, \"b\".txt\t1234\r\n")
        var dq = Exporter(format: .txt); dq.doubleQuote = true
        #expect(dq.render([ids[1]], ctx: ctx) == "\"/docs/a, \"b\".txt\"\r\n")
    }
}

@Suite struct FilterBookmarkOmissionTests {
    @Test func filtersPersistAndMacros() throws {
        let store = FilterStore()
        #expect(store.filters.count == 8)
        #expect(store.filter(named: "audio")?.search.hasPrefix("ext:") == true)
        let m = store.macros
        #expect(m["audio"] != nil && m["pic"] == m["image"] && m["doc"] != nil && m["zip"] != nil)
        store.add(Filter(name: "Swift", search: "ext:swift", macro: "sw", matchCase: true, key: "cmd+8"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("evt-\(UUID().uuidString)-Filters.csv")
        try store.save(to: url)
        let loaded = FilterStore.load(from: url)
        #expect(loaded.filters.count == 9)
        #expect(loaded.filter(named: "Swift") == store.filter(named: "Swift"))
        #expect(loaded.macros["sw"] == "ext:swift")
        loaded.move(from: 8, to: 1)
        #expect(loaded.filters[1].name == "Swift")
        loaded.remove(named: "Swift")
        #expect(loaded.filters.count == 8)
        // legacy 1.4 header
        let legacy = "Name,Case,Whole Word,Path,Diacritics,Regex,Search,Macro,Key\r\nAudio,0,0,0,0,0,ext:mp3,audio,\r\n"
        try legacy.write(to: url, atomically: true, encoding: .utf8)
        let l = FilterStore.load(from: url)
        #expect(l.filters.count == 1 && l.filters[0].macro == "audio")
        try? FileManager.default.removeItem(at: url)
    }

    @Test func bookmarksPersist() throws {
        let store = BookmarkStore()
        store.add(Bookmark(name: "Big videos", search: "size:>1gb video:", filter: "Video", sort: "size", sortAscending: false, matchCase: false, key: "cmd+shift+1"))
        store.add(Bookmark(name: "Recent", search: "dm:today"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("evt-\(UUID().uuidString)-Bookmarks.csv")
        try store.save(to: url)
        let loaded = BookmarkStore.load(from: url)
        #expect(loaded.bookmarks == store.bookmarks)
        #expect(loaded.bookmark(named: "big videos")?.sortAscending == false)
        loaded.update(Bookmark(name: "Recent2", search: "dm:yesterday"), originalName: "Recent")
        #expect(loaded.bookmark(named: "Recent") == nil && loaded.bookmark(named: "Recent2") != nil)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func omissions() throws {
        let index = Index()
        let root = index.addRoot(kind: .volume, path: "/", label: "x").item
        let s = index.store
        let lib = s.add(ItemRecord(name: "Library", parent: root, flags: [.folder]))
        let caches = s.add(ItemRecord(name: "Caches", parent: lib, flags: [.folder]))
        let cached = s.add(ItemRecord(name: "x.db", parent: caches))
        let tmp = s.add(ItemRecord(name: "a.tmp", parent: root))
        let doc = s.add(ItemRecord(name: "doc.txt", parent: root))
        let node = s.add(ItemRecord(name: "node_modules", parent: root, flags: [.folder]))
        let inNode = s.add(ItemRecord(name: "index.js", parent: node))
        let engine = SearchEngine(index: index)
        let om = OmissionStore()
        om.omitPath("/Library/Caches")
        om.omitExtension(".tmp")
        om.add(Omission(kind: .filter, value: "*/node_modules", omitFolders: true))
        engine.omissions = om
        var req = QueryRequest(text: "")
        req.omissionsEnabled = true
        let r = engine.search(req)
        #expect(!r.ids.contains(cached) && !r.ids.contains(caches) && !r.ids.contains(tmp) && !r.ids.contains(node) && !r.ids.contains(inNode))
        #expect(r.ids.contains(doc) && r.ids.contains(lib))
        req.omissionsEnabled = false
        #expect(engine.search(req).count == s.count)
        #expect(engine.search(QueryRequest(text: "disable-result-omissions:")).count == s.count)
        var on = QueryRequest(text: "enable-result-omissions:")
        on.omissionsEnabled = false
        #expect(engine.search(on).count == s.count - 5)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("evt-\(UUID().uuidString)-Omit.csv")
        try om.save(to: url)
        let loaded = OmissionStore.load(from: url)
        #expect(loaded.omissions == om.omissions)
        try? FileManager.default.removeItem(at: url)
        // temporary omissions
        let temp = OmissionStore(temporary: true)
        temp.omitPath("/doc.txt")
        engine.tempOmissions = temp
        var t = QueryRequest(text: ""); t.tempOmissionsEnabled = true
        #expect(!engine.search(t).ids.contains(doc))
    }
}

@Suite struct HistoryUndoTests {
    @Test func searchHistory() throws {
        let h = SearchHistory()
        h.record("alpha", date: 1); h.record("alphabet", date: 2); h.record("beta", date: 3); h.record("alpha", date: 4)
        #expect(h.suggestions(for: "alp") == ["alpha", "alphabet"])
        #expect(h.autocomplete("alp") == "alpha")
        #expect(h.all(sortedBy: .count).first?.search == "alpha")
        #expect(h.all(sortedBy: .search).map { $0.search } == ["alpha", "alphabet", "beta"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("evt-\(UUID().uuidString)-SearchHistory.csv")
        try h.save(to: url)
        let l = SearchHistory.load(from: url)
        #expect(l.count == 3)
        #expect(l.all(sortedBy: .count).first?.count == 2)
        l.keepDays = 1
        l.prune(now: 10 * 86_400 * 1_000_000_000)
        #expect(l.count == 0)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func runHistory() throws {
        let r = RunHistory()
        #expect(r.increment("/a") == 1)
        #expect(r.increment("/a") == 2)
        r.increment("/b")
        #expect(r.runCount(forPath: "/a") == 2)
        #expect(r.mostRun(among: ["/b", "/a", "/c"]) == "/a")
        r.set("/c", count: 9)
        #expect(r.mostRun(among: ["/b", "/a", "/c"]) == "/c")
        r.rename(from: "/a", to: "/z")
        #expect(r.runCount(forPath: "/z") == 2 && r.runCount(forPath: "/a") == 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("evt-\(UUID().uuidString)-RunHistory.csv")
        try r.save(to: url)
        let l = RunHistory.load(from: url)
        #expect(l.runCount(forPath: "/z") == 2 && l.dateRun(forPath: "/z") > 0)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func undoRenameMoveTrash() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("evt-undo-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt").path
        try "a".write(toFile: a, atomically: true, encoding: .utf8)
        let log = UndoLog()
        let renamed = try log.rename(a, to: "b.txt")
        #expect(fm.fileExists(atPath: renamed) && !fm.fileExists(atPath: a))
        try log.undoLast()
        #expect(fm.fileExists(atPath: a) && !fm.fileExists(atPath: renamed))
        let moved = try log.move([a], to: dir.appendingPathComponent("sub").path)
        #expect(fm.fileExists(atPath: moved[0]))
        try log.undoLast()
        #expect(fm.fileExists(atPath: a))
        let copies = try log.copy([a], to: dir.appendingPathComponent("sub").path)
        #expect(fm.fileExists(atPath: copies[0]))
        try log.undoLast()
        #expect(!fm.fileExists(atPath: copies[0]))
        let trashed = try log.trash([a])
        #expect(!fm.fileExists(atPath: a) && !trashed[0].isEmpty)
        try log.undoLast()
        #expect(fm.fileExists(atPath: a))
        #expect(log.entries.count == 4 && log.undoable.isEmpty)
        let url = dir.appendingPathComponent("undo.json")
        try log.save(to: url)
        #expect(UndoLog.load(from: url).entries.count == 4)
    }

    @Test func advancedRename() {
        var o = AdvancedRename.Options()
        o.mode = .findReplace; o.find = "IMG_"; o.replace = "Holiday "
        #expect(AdvancedRename.apply(["IMG_001.jpg", "img_002.JPG", "other.txt"], options: o) == ["Holiday 001.jpg", "Holiday 002.JPG", "other.txt"])
        o.mode = .changeExtension; o.newExtension = ".jpeg"
        #expect(AdvancedRename.apply(["a.jpg", "b"], options: o) == ["a.jpeg", "b.jpeg"])
        o.mode = .regex; o.pattern = "^(\\w+)_(\\d+)$"; o.template = "$2-$1"
        #expect(AdvancedRename.apply(["IMG_001.jpg"], options: o) == ["001-IMG.jpg"])
        o.mode = .editAll; o.template = "x.txt\n\ny.txt"
        #expect(AdvancedRename.apply(["a.txt", "b.txt", "c.txt"], options: o) == ["x.txt", "b.txt", "y.txt"])
        o.mode = .numbering; o.template = "Photo ###"; o.numberStart = 5; o.numberStep = 5
        #expect(AdvancedRename.apply(["a.jpg", "b.jpg"], options: o) == ["Photo 005.jpg", "Photo 010.jpg"])
    }
}
