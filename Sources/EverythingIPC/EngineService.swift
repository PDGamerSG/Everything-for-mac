import Foundation
import EverythingCore

/// Adapts a `SearchEngine` (and surrounding state) to the IPC protocol. Used by the app's IPC server,
/// the HTTP/ETP servers, and `es` in standalone (read-only database) mode.
public final class EngineService: IPCService, @unchecked Sendable {
    public let engine: SearchEngine
    public var defaults = MatchDefaults()
    public var journal: IndexJournal?
    public var runHistory: RunHistory?
    public var filters: FilterStore?
    public var dbLoaded: () -> Bool = { true }
    public var isAdmin = false
    public var sizeStandard: SizeStandard = .jedec
    /// App-level hooks (nil in standalone mode).
    public var onRebuildDB: (() -> Void)?
    public var onSaveDB: (() -> Void)?
    public var onSaveRunHistory: (() -> Void)?
    public var onUpdateAllFolderIndexes: (() -> Void)?
    public var onExit: (() -> Void)?
    public var onCommand: (([String]) -> IPCResponse)?
    public var onRescanAll: (() -> Void)?
    public var onMonitorPause: ((Bool) -> Void)?
    public var settingsGet: ((String) -> String?)?
    public var settingsSet: ((String, String) -> Void)?
    public var statistics: (() -> [String: String])?
    public var maxJournalWatchMs = 600_000
    private let queue = DispatchQueue(label: "everything.ipc.service", attributes: .concurrent)

    public init(engine: SearchEngine) { self.engine = engine }

    public func handle(_ request: IPCRequest, completion: @escaping (IPCResponse) -> Void) {
        switch request.kind {
        case .ping: completion(IPCResponse())
        case .version: var r = IPCResponse(); r.version = everythingVersion; completion(r)
        case .isDBLoaded: completion(.value(dbLoaded()))
        case .isAdmin: completion(.value(isAdmin))
        case .rebuildDB: onRebuildDB?(); completion(.value(onRebuildDB != nil))
        case .saveDB: onSaveDB?(); completion(.value(onSaveDB != nil))
        case .saveRunHistory: onSaveRunHistory?(); completion(.value(onSaveRunHistory != nil))
        case .deleteRunHistory: runHistory?.clear(); completion(.value(runHistory != nil))
        case .updateAllFolderIndexes: onUpdateAllFolderIndexes?(); completion(.value(onUpdateAllFolderIndexes != nil))
        case .rescanAll: onRescanAll?(); completion(.value(onRescanAll != nil))
        case .monitorPause: onMonitorPause?(true); completion(.value(onMonitorPause != nil))
        case .monitorResume: onMonitorPause?(false); completion(.value(onMonitorPause != nil))
        case .exit: completion(.value(onExit != nil)); DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.onExit?() }
        case .query:
            guard let q = request.query else { completion(.failure("missing query")); return }
            queue.async { completion(self.runQuery(q)) }
        case .runCountGet:
            guard let p = request.path else { completion(.failure("missing path")); return }
            completion(.value(runHistory?.runCount(forPath: Paths.normalize(p)) ?? 0))
        case .runCountSet:
            guard let p = request.path, let c = request.count else { completion(.failure("missing path/count")); return }
            runHistory?.set(Paths.normalize(p), count: c); completion(.value(runHistory != nil))
        case .runCountInc:
            guard let p = request.path else { completion(.failure("missing path")); return }
            completion(.value(runHistory?.increment(Paths.normalize(p)) ?? 0))
        case .journal:
            guard let j = journal else { completion(.failure("journal disabled")); return }
            let params = request.journal ?? IPCJournalParams()
            queue.async { self.runJournal(j, params, completion: completion) }
        case .folderSize:
            guard let p = request.path else { completion(.failure("missing path")); return }
            queue.async { completion(.value(self.folderSize(Paths.normalize(p)))) }
        case .command:
            completion(onCommand?(request.args ?? []) ?? .failure("not supported"))
        case .statistics:
            var r = IPCResponse()
            var d = statistics?() ?? [:]
            let st = engine.index.read { engine.index.statistics }
            d["files"] = String(st.files); d["folders"] = String(st.folders); d["total"] = String(st.total); d["roots"] = String(st.roots)
            d["generation"] = String(st.generation); d["nameBytes"] = String(st.nameBytes)
            r.dictionary = d
            completion(r)
        case .roots, .indexRoots:
            var r = IPCResponse()
            r.roots = engine.index.read {
                engine.index.roots.map { root in
                    IPCRootInfo(kind: "\(root.kind)", path: root.path, label: root.label,
                                itemCount: PropertyAccess.descendantCount(root.item, engine.index.store, files: true, folders: true), online: root.online)
                }
            }
            completion(r)
        case .settingsGet:
            guard let k = request.key else { completion(.failure("missing key")); return }
            if let v = settingsGet?(k) { completion(.value(v)) } else { completion(.failure("unknown setting")) }
        case .settingsSet:
            guard let k = request.key, let v = request.value else { completion(.failure("missing key/value")); return }
            settingsSet?(k, v); completion(.value(settingsSet != nil))
        }
    }

    // MARK: query

    public func makeRequest(_ q: IPCQueryParams) -> QueryRequest {
        var req = QueryRequest(text: q.search)
        var d = defaults
        if let v = q.matchCase { d.matchCase = v }
        if let v = q.matchWholeWord { d.matchWholeWords = v }
        if let v = q.matchPath { d.matchPath = v }
        if let v = q.matchDiacritics { d.matchDiacritics = v }
        if let v = q.matchPrefix { d.matchPrefix = v }
        if let v = q.matchSuffix { d.matchSuffix = v }
        if let v = q.ignorePunctuation { d.ignorePunctuation = v }
        if let v = q.ignoreWhitespace { d.ignoreWhitespace = v }
        if let v = q.regex { d.regex = v }
        req.defaults = d
        if let s = q.sort {
            var key = SortKey.parse(s)
            if let a = q.ascending { key.ascending = a }
            req.sort = [key]
        } else if let a = q.ascending { req.sort = [SortKey("name", ascending: a)] }
        if let f = q.foldersFirst, let ff = FoldersFirst(rawValue: f) { req.foldersFirst = ff }
        req.offset = q.offset
        req.count = q.count
        if let t = q.maxThreads { req.maxThreads = t }
        if let o = q.omissions { req.omissionsEnabled = o }
        if let fname = q.filter, let f = filters?.filter(named: fname), !f.isEverything {
            req.filterSearch = f.search
            req.filterDefaults = f.defaults
        }
        if let fs = q.filterSearch, !fs.isEmpty {
            req.filterSearch = req.filterSearch.isEmpty ? fs : "<\(req.filterSearch)> <\(fs)>"
        }
        return req
    }

    public func runQuery(_ q: IPCQueryParams) -> IPCResponse {
        let req = makeRequest(q)
        let rs = engine.search(req)
        var r = IPCResponse()
        r.query = convert(rs, params: q)
        return r
    }

    public func convert(_ rs: ResultSet, params q: IPCQueryParams) -> IPCQueryResult {
        let s = rs.context.store
        let cols = Set(q.columns.map(QueryParser.canonical))
        var items: [IPCItem] = []
        items.reserveCapacity(rs.count)
        for id in rs.ids where s.isAlive(id) {
            let name = s.name(id)
            let path = rs.parentPath(id)
            let isFolder = s.isFolder(id)
            var item = IPCItem(type: s.flags(id).contains(.root) ? "volume" : (isFolder ? "folder" : "file"), name: name, path: path, fullPath: Paths.join(path, name), itemID: id)
            if cols.contains("size") { item.size = isFolder && !s.trackFolderSize ? nil : s.size(id) }
            if cols.contains("datemodified") { item.dateModified = s.dateModified(id) }
            if cols.contains("datecreated") { item.dateCreated = s.dateCreated(id) }
            if cols.contains("dateaccessed") { item.dateAccessed = s.dateAccessed(id) }
            if cols.contains("attributes") { item.attributes = s.flags(id).letters; item.attributesValue = s.flags(id).windowsAttributes }
            if cols.contains("extension") { item.extensionName = s.extensionName(id) }
            if cols.contains("runcount") { item.runCount = runHistory?.runCount(forPath: item.fullPath) ?? 0 }
            if cols.contains("daterun") { item.dateRun = runHistory?.dateRun(forPath: item.fullPath) ?? 0 }
            if cols.contains("daterecentlychanged") { item.dateRecentlyChanged = journal?.dateRecentlyChanged(forPath: item.fullPath) ?? 0 }
            if cols.contains("filelistfilename") { item.fileListFilename = engine.fileListFilenames[s.root(of: id)] ?? "" }
            if q.highlight {
                let h = rs.highlightRanges(name: name, path: path)
                item.highlightedName = EngineService.mark(name, h.name)
                item.highlightedPath = EngineService.mark(path, h.path)
            }
            let extra = cols.subtracting(["size", "datemodified", "datecreated", "dateaccessed", "attributes", "extension", "runcount", "daterun", "daterecentlychanged", "filelistfilename", "name", "path", "fullpath"])
            if !extra.isEmpty {
                var props: [String: String] = [:]
                for c in extra { props[c] = PropertyAccess.text(c, id: id, ctx: rs.context) }
                item.properties = props
            }
            items.append(item)
        }
        return IPCQueryResult(totalFiles: rs.fileCount, totalFolders: rs.folderCount, totalResults: rs.totalBeforeLimit, items: items,
                              generation: rs.generation, seconds: rs.seconds, errors: rs.errors, totalSize: rs.totalSize)
    }

    /// Everything-style highlighting: matched text wrapped in `*`, literal asterisks doubled.
    static func mark(_ s: String, _ ranges: [Range<String.Index>]) -> String {
        guard !ranges.isEmpty else { return s.replacingOccurrences(of: "*", with: "**") }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var out = ""
        var cur = s.startIndex
        for r in sorted where r.lowerBound >= cur {
            out += s[cur..<r.lowerBound].replacingOccurrences(of: "*", with: "**")
            out += "*" + s[r].replacingOccurrences(of: "*", with: "**") + "*"
            cur = r.upperBound
        }
        out += s[cur...].replacingOccurrences(of: "*", with: "**")
        return out
    }

    // MARK: journal

    private func runJournal(_ j: IndexJournal, _ p: IPCJournalParams, completion: @escaping (IPCResponse) -> Void) {
        var q = IndexJournal.Query()
        q.fromChangeID = p.fromChangeID; q.toChangeID = p.toChangeID; q.fromDate = p.fromDate; q.toDate = p.toDate
        q.text = p.text; q.regex = p.regex; q.addedOnly = p.addedOnly; q.removedOnly = p.removedOnly
        if let a = p.actions { q.actions = Set(a.compactMap { JournalEntry.Action(rawValue: $0) }) }
        func result(_ entries: [JournalEntry]) -> IPCResponse {
            var r = IPCResponse()
            r.journal = IPCJournalResult(journalID: j.journalID, nextChangeID: j.nextChangeID, firstChangeID: j.firstChangeID, entries: entries)
            return r
        }
        let now = j.query(q)
        if !p.watch || !now.isEmpty { completion(result(now)); return }
        // watch: wait for the next matching change (or timeout)
        let sema = DispatchSemaphore(value: 0)
        var hit: [JournalEntry] = []
        let lock = NSLock()
        let token = j.watch { e in
            var single = q; single.fromChangeID = e.changeID; single.toChangeID = e.changeID + 1
            if !j.query(single).isEmpty { lock.lock(); if hit.isEmpty { hit = [e]; sema.signal() }; lock.unlock() }
        }
        let timeout = p.timeoutMs > 0 ? min(p.timeoutMs, maxJournalWatchMs) : maxJournalWatchMs
        _ = sema.wait(timeout: .now() + .milliseconds(timeout))
        j.unwatch(token)
        lock.lock(); let h = hit; lock.unlock()
        completion(result(h))
    }

    // MARK: folder size

    public func folderSize(_ path: String) -> UInt64 {
        engine.index.read {
            guard let id = engine.index.lookup(path: path) else { return 0 }
            let s = engine.index.store
            if !s.isFolder(id) { return s.size(id) }
            if s.trackFolderSize { return s.size(id) }
            var total: UInt64 = 0
            var stack: [ItemID] = [id]
            while let cur = stack.popLast() { s.forEachChild(of: cur) { c in if s.isFolder(c) { stack.append(c) } else { total &+= s.size(c) } } }
            return total
        }
    }
}
