import Testing
import Foundation
@testable import EverythingCore

@Suite struct SearchEngineTests {
    /// Deterministic random tree.
    static func makeIndex(items: Int, seed: UInt64 = 42) -> Index {
        let index = Index()
        let root = index.addRoot(kind: .volume, path: "/", label: "Macintosh HD").item
        var rng = seed
        func next() -> UInt64 { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return rng >> 33 }
        var folders: [ItemID] = [root]
        let words = ["alpha", "Beta", "gamma", "Delta", "photo", "Report", "notes", "Music", "video", "archive", "résumé", "日本", "file", "data", "backup", "img"]
        let exts = ["txt", "jpg", "mp3", "pdf", "swift", "zip", "mov", "", "DOCX", "h"]
        let s = index.store
        for i in 0..<items {
            let parent = folders[Int(next() % UInt64(folders.count))]
            let w = words[Int(next() % UInt64(words.count))]
            if next() % 9 == 0 {
                folders.append(s.add(ItemRecord(name: "\(w)-dir\(i)", parent: parent, flags: [.folder], dateModified: Int64(i) * 1_000_000_000)))
            } else {
                let e = exts[Int(next() % UInt64(exts.count))]
                let name = "\(w)\(i % 50)" + (e.isEmpty ? "" : ".\(e)")
                s.add(ItemRecord(name: name, parent: parent, flags: i % 11 == 0 ? [.hidden] : [], size: UInt64(next() % 10_000_000),
                                 dateModified: Int64(1_600_000_000 + i * 37) * 1_000_000_000, dateCreated: Int64(i) * 1_000_000_000))
            }
        }
        return index
    }

    @Test func correctnessVsBruteForce() {
        let index = SearchEngineTests.makeIndex(items: 20_000)
        let engine = SearchEngine(index: index)
        let s = index.store
        func brute(_ test: (ItemID) -> Bool) -> Set<ItemID> {
            var out = Set<ItemID>()
            for i in 0..<s.slotCount where s.isAlive(ItemID(i)) && test(ItemID(i)) { out.insert(ItemID(i)) }
            return out
        }
        let r1 = engine.search(QueryRequest(text: "alpha"))
        #expect(Set(r1.ids) == brute { s.name($0).lowercased().contains("alpha") })
        let r2 = engine.search(QueryRequest(text: "alpha jpg|mp3"))
        #expect(Set(r2.ids) == brute { let n = s.name($0).lowercased(); return n.contains("alpha") && (n.contains("jpg") || n.contains("mp3")) })
        let r3 = engine.search(QueryRequest(text: "!alpha !beta ext:txt"))
        #expect(Set(r3.ids) == brute { let n = s.name($0).lowercased(); return !n.contains("alpha") && !n.contains("beta") && n.hasSuffix(".txt") })
        let r4 = engine.search(QueryRequest(text: "size:>5mb folder:|ext:pdf"))
        #expect(Set(r4.ids) == brute { s.size($0) > 5 * 1024 * 1024 && !s.isFolder($0) && (s.isFolder($0) || s.name($0).hasSuffix(".pdf")) })
        let r5 = engine.search(QueryRequest(text: "resume"))
        #expect(Set(r5.ids) == brute { ItemStore.fold(s.name($0)).contains("resume") })
        #expect(r5.count > 0)
        let r6 = engine.search(QueryRequest(text: "日本"))
        #expect(Set(r6.ids) == brute { s.name($0).contains("日本") })
        #expect(r6.count > 0)
        let empty = engine.search(QueryRequest(text: ""))
        #expect(empty.count == s.count)
        #expect(empty.fileCount + empty.folderCount == s.count)
    }

    @Test func sorting() {
        let index = SearchEngineTests.makeIndex(items: 5_000)
        let engine = SearchEngine(index: index)
        let s = index.store
        var req = QueryRequest(text: "")
        req.sort = [SortKey("name")]
        let byName = engine.search(req)
        // folders first, then natural name order
        var seenFile = false
        var prev: ItemID? = nil
        for id in byName.ids {
            if s.isFolder(id) { #expect(!seenFile) } else { seenFile = true }
            if let p = prev, s.isFolder(p) == s.isFolder(id) {
                #expect(NaturalOrder.compare(s.name(p), s.name(id)) <= 0, "\(s.name(p)) > \(s.name(id))")
            }
            prev = id
        }
        req.sort = [SortKey("size", ascending: false)]
        req.foldersFirst = .mixed
        let bySize = engine.search(req)
        for (a, b) in zip(bySize.ids, bySize.ids.dropFirst()) { #expect(s.size(a) >= s.size(b)) }
        req.sort = [SortKey("date-modified", ascending: true)]
        let byDate = engine.search(req)
        for (a, b) in zip(byDate.ids, byDate.ids.dropFirst()) { #expect(s.dateModified(a) <= s.dateModified(b)) }
        req.sort = [SortKey("extension")]
        let byExt = engine.search(req)
        for (a, b) in zip(byExt.ids, byExt.ids.dropFirst()) { #expect(s.extensionName(a).lowercased() <= s.extensionName(b).lowercased()) }
        req.sort = [SortKey("path")]
        let byPath = engine.search(req)
        for (a, b) in zip(byPath.ids, byPath.ids.dropFirst()) { #expect(NaturalOrder.compare(byPath.parentPath(a), byPath.parentPath(b)) <= 0) }
        // directive sort
        let viaDirective = engine.search(QueryRequest(text: "sort:size-descending"))
        for (a, b) in zip(viaDirective.ids.prefix(200), viaDirective.ids.dropFirst().prefix(200)) where !s.isFolder(a) && !s.isFolder(b) { #expect(s.size(a) >= s.size(b)) }
        // count directive and request count
        #expect(engine.search(QueryRequest(text: "count:10 alpha")).count == 10)
        var limited = QueryRequest(text: "alpha"); limited.count = 5; limited.offset = 2
        let l = engine.search(limited)
        #expect(l.count == 5)
        #expect(l.totalBeforeLimit > 5)
        #expect(l.ids[0] == byName.ids.filter { s.name($0).lowercased().contains("alpha") }[2])
    }

    @Test func naturalOrder() {
        #expect(NaturalOrder.compare("file2.txt", "file10.txt") < 0)
        #expect(NaturalOrder.compare("File10.txt", "file9.txt") > 0)
        #expect(NaturalOrder.compare("abc", "ABC") == 0)
        #expect(NaturalOrder.compare("résumé", "resume") == 0)
        #expect(NaturalOrder.compare("a", "b") < 0)
        #expect(NaturalOrder.compare("a1", "a01") < 0)
        #expect(NaturalOrder.compare("", "a") < 0)
    }

    @Test func fastSortMatchesDirect() {
        let index = SearchEngineTests.makeIndex(items: 8_000)
        let engine = SearchEngine(index: index)
        engine.fastSort.rebuild()
        #expect(engine.fastSort.canOrder("name"))
        let ctx = engine.makeContext()
        let all = (0..<index.store.slotCount).map { ItemID($0) }.filter { index.store.isAlive($0) }
        let direct = ResultSorter(keys: [SortKey("name")], foldersFirst: .mixed, ctx: ctx).sortDirect(all)
        let fast = engine.fastSort.order(all, by: "name", ascending: true)
        // names equal in order (ties may differ only between identical folded names)
        #expect(direct.map { ItemStore.fold(index.store.name($0)) } == fast.map { ItemStore.fold(index.store.name($0)) })
        let fastPath = engine.fastSort.order(all, by: "path", ascending: true)
        for (a, b) in zip(fastPath, fastPath.dropFirst()) { #expect(NaturalOrder.compare(ctx.parentPath(a), ctx.parentPath(b)) <= 0) }
    }

    @Test func duplicates() {
        let index = Index()
        let root = index.addRoot(kind: .volume, path: "/", label: "x").item
        let s = index.store
        let a = s.add(ItemRecord(name: "a", parent: root, flags: [.folder]))
        let b = s.add(ItemRecord(name: "b", parent: root, flags: [.folder]))
        s.add(ItemRecord(name: "same.txt", parent: a, size: 10))
        s.add(ItemRecord(name: "same.txt", parent: b, size: 10))
        s.add(ItemRecord(name: "SAME.txt", parent: root, size: 99))
        s.add(ItemRecord(name: "only.txt", parent: a, size: 5))
        s.add(ItemRecord(name: "pair.txt", parent: a, size: 7))
        s.add(ItemRecord(name: "pair.txt", parent: b, size: 7))
        let engine = SearchEngine(index: index)
        let dupe = engine.search(QueryRequest(text: "dupe:name"))
        #expect(dupe.ids.map { s.name($0).lowercased() } == ["pair.txt", "pair.txt", "same.txt", "same.txt", "same.txt"])
        #expect(dupe.groupStarts == [0, 2])
        let dupeSize = engine.search(QueryRequest(text: "dupe:name;size"))
        #expect(dupeSize.ids.map { s.name($0).lowercased() } == ["pair.txt", "pair.txt", "same.txt", "same.txt"])
        let unique = engine.search(QueryRequest(text: "unique:name file:"))
        #expect(unique.ids.map { s.name($0) } == ["only.txt"])
        let distinct = engine.search(QueryRequest(text: "distinct:name file:"))
        #expect(distinct.ids.map { s.name($0).lowercased() } == ["only.txt", "pair.txt", "same.txt"])
        let from = engine.search(QueryRequest(text: "dupe:name dupe-from:/b"))
        #expect(from.count == 5)
        let min3 = engine.search(QueryRequest(text: "dupe:name dupe-min:3"))
        #expect(min3.count == 3)
        let cnt = engine.search(QueryRequest(text: "dupe:name dupe-count:1"))
        #expect(cnt.count == 2)
    }

    @Test func filterAndScope() {
        let index = SearchEngineTests.makeIndex(items: 3_000)
        let engine = SearchEngine(index: index)
        let s = index.store
        var req = QueryRequest(text: "alpha")
        req.filterSearch = "ext:jpg;mp3"
        let r = engine.search(req)
        #expect(r.count > 0)
        #expect(r.ids.allSatisfy { let e = s.extensionName($0).lowercased(); return e == "jpg" || e == "mp3" })
        // macros from filters
        engine.macros = ["pic": "ext:jpg"]
        let m = engine.search(QueryRequest(text: "pic:"))
        #expect(m.ids.allSatisfy { s.extensionName($0).lowercased() == "jpg" })
        // root scope
        let other = index.addRoot(kind: .folder, path: "/tmp/x", label: "x").item
        s.add(ItemRecord(name: "alpha-in-x.txt", parent: other))
        var scoped = QueryRequest(text: "alpha")
        scoped.rootScope = [other]
        #expect(engine.search(scoped).count == 1)
    }

    @Test func refinementAndLiveUpdates() {
        let index = SearchEngineTests.makeIndex(items: 3_000)
        let engine = SearchEngine(index: index)
        let s = index.store
        let first = engine.search(QueryRequest(text: "alp"))
        let second = engine.search(QueryRequest(text: "alpha"))
        #expect(SearchEngine.isRefinement(old: "alp", new: "alpha"))
        #expect(!SearchEngine.isRefinement(old: "alp", new: "alp|x"))
        #expect(!SearchEngine.isRefinement(old: "", new: "a"))
        #expect(second.count <= first.count)
        let brute = (0..<s.slotCount).map { ItemID($0) }.filter { s.isAlive($0) && s.name($0).lowercased().contains("alpha") }
        #expect(Set(second.ids) == Set(brute))
        // live update: add a matching file → inserted in sorted position
        let root = index.roots[0].item
        let newID = index.write { s.add(ItemRecord(name: "Alpha-zzz.txt", parent: root, size: 1)) }
        let delta = second.apply(created: [newID], removed: [], modified: [])
        #expect(delta.inserted.count == 1)
        #expect(second.ids.contains(newID))
        let pos = delta.inserted[0]
        if pos > 0 { #expect(second.sorter.less(second.ids[pos - 1], newID) || s.isFolder(second.ids[pos - 1])) }
        if pos + 1 < second.ids.count { #expect(!second.sorter.less(second.ids[pos + 1], newID)) }
        // rename out of the match → removed
        index.write { s.rename(newID, to: "zzz.txt") }
        let d2 = second.apply(created: [], removed: [], modified: [newID])
        #expect(d2.removed.count == 1)
        #expect(!second.ids.contains(newID))
        // non-matching creation → no-op
        let other = index.write { s.add(ItemRecord(name: "nothing.txt", parent: root)) }
        #expect(second.apply(created: [other], removed: [], modified: []).isEmpty)
        // removal
        let victim = second.ids[0]
        index.write { s.remove(victim) }
        let d3 = second.apply(created: [], removed: [victim], modified: [])
        #expect(d3.removed == [0])
    }

    @Test func cancellation() {
        let index = SearchEngineTests.makeIndex(items: 50_000)
        let engine = SearchEngine(index: index)
        let token = CancelToken()
        token.cancel()
        let r = engine.search(QueryRequest(text: "alpha"), cancel: token)
        #expect(r.count == 0)
    }

    @Test func searchCanBuildContextWhileScannerWriterIsQueued() {
        let index = Index()
        let root = index.addRoot(kind: .folder, path: "/Fixture", label: "Fixture")
        index.store.add(ItemRecord(name: "invoice.txt", parent: root.item))
        let engine = SearchEngine(index: index)
        let writerRequested = DispatchSemaphore(value: 0)
        let writerAcquired = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        engine.beforeSearchContext = {
            writerRequested.signal()
            #expect(writerAcquired.wait(timeout: .now() + 0.05) == .timedOut)
        }
        DispatchQueue.global(qos: .utility).async {
            _ = writerRequested.wait(timeout: .now() + 1)
            index.write {
                writerAcquired.signal()
                _ = releaseWriter.wait(timeout: .now() + 1)
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = engine.search(QueryRequest(text: "invoice"))
            #expect(result.count == 1)
            finished.signal()
        }
        #expect(finished.wait(timeout: .now() + 2) == .success)
        releaseWriter.signal()
    }

    @Test func highlightRanges() {
        let index = SearchEngineTests.makeIndex(items: 500)
        let engine = SearchEngine(index: index)
        let r = engine.search(QueryRequest(text: "alpha txt"))
        let id = r.ids.first { !index.store.isFolder($0) }!
        let name = index.store.name(id)
        let h = r.highlightRanges(name: name, path: r.parentPath(id))
        #expect(h.name.count >= 2)
        #expect(h.name.map { name[$0].lowercased() }.contains("alpha"))
        let p = engine.search(QueryRequest(text: "path:dir"))
        let pid = p.ids.first { !index.store.isFolder($0) && p.parentPath($0).lowercased().contains("dir") }!
        let ph = p.highlightRanges(name: index.store.name(pid), path: p.parentPath(pid))
        #expect(!ph.path.isEmpty)
    }

    @Test func benchmarkMillionNames() {
        // Debug builds are ~8x slower than release; `scripts/bench.sh` runs this in release with 1M items.
        let release = ProcessInfo.processInfo.environment["EVT_BENCH_RELEASE"] != nil
        let index = SearchEngineTests.makeIndex(items: release ? 1_000_000 : 200_000)
        let engine = SearchEngine(index: index)
        _ = engine.search(QueryRequest(text: "warmup"))
        let t0 = Date()
        let r = engine.search(QueryRequest(text: "alpha"))
        let dt = Date().timeIntervalSince(t0)
        print("BENCH \(index.store.count) substring search: \(r.count) results in \(Int(dt * 1000)) ms (sort incl.)")
        if release { #expect(dt < 0.8) }
        let t1 = Date()
        let all = engine.search(QueryRequest(text: ""))
        print("BENCH empty search (name sort, direct): \(all.count) results in \(Int(Date().timeIntervalSince(t1) * 1000)) ms")
        engine.fastSort.rebuild()
        let t2 = Date()
        let all2 = engine.search(QueryRequest(text: ""))
        print("BENCH empty search (fast sort): \(all2.count) results in \(Int(Date().timeIntervalSince(t2) * 1000)) ms")
        #expect(all2.count == all.count)
    }
}
