import Foundation

/// Result omission hook (permanent + temporary omissions).
public protocol OmissionProviding: AnyObject {
    var isEmpty: Bool { get }
    func omits(_ id: ItemID, ctx: EvalContext) -> Bool
}

public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    public func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
}

public struct QueryRequest: Equatable, Sendable {
    public var text: String
    public var defaults = MatchDefaults()
    /// Active filter: search text AND-ed with the query, with its own match options.
    public var filterSearch: String = ""
    public var filterDefaults: MatchDefaults? = nil
    public var sort: [SortKey] = [SortKey("name")]
    public var foldersFirst: FoldersFirst? = nil       // nil → engine default (folders first for name/path/ext)
    public var sortMix: Bool? = nil
    public var offset = 0
    public var count = 0                                // 0 = unlimited
    public var maxThreads = 0
    public var omissionsEnabled = false
    public var tempOmissionsEnabled = false
    /// Restrict to items under these root items (file list scope / volume selection). nil = all.
    public var rootScope: Set<ItemID>? = nil
    public var searchCurrentResults = true
    public var fileListSlots: [Int: [String]] = [:]

    public init(text: String) { self.text = text }

    /// Everything-style default: folders first when sorting by name/path/extension/type.
    public var effectiveFoldersFirst: FoldersFirst {
        if let f = foldersFirst { return f }
        if sortMix == true { return .mixed }
        let p = sort.first?.property ?? "name"
        return ["name", "path", "extension", "type", "kind"].contains(p) ? .first : .mixed
    }
}

public final class ResultSet: @unchecked Sendable {
    public private(set) var ids: [ItemID]
    public let request: QueryRequest
    public let query: CompiledQuery
    public let filterQuery: CompiledQuery?
    public let generation: UInt64
    public let sortKeys: [SortKey]
    public let foldersFirst: FoldersFirst
    public private(set) var groupStarts: [Int]
    public let duplicateOptions: DuplicateOptions
    public let totalBeforeLimit: Int
    public let seconds: Double
    let sorter: ResultSorter
    let ctx: EvalContext
    private var _totalSize: UInt64? = nil
    private var _counts: (files: Int, folders: Int)? = nil
    private let lock = NSLock()

    init(ids: [ItemID], request: QueryRequest, query: CompiledQuery, filterQuery: CompiledQuery?, generation: UInt64, sortKeys: [SortKey],
         foldersFirst: FoldersFirst, groupStarts: [Int], duplicateOptions: DuplicateOptions, totalBeforeLimit: Int, seconds: Double, sorter: ResultSorter, ctx: EvalContext) {
        self.ids = ids; self.request = request; self.query = query; self.filterQuery = filterQuery; self.generation = generation
        self.sortKeys = sortKeys; self.foldersFirst = foldersFirst; self.groupStarts = groupStarts; self.duplicateOptions = duplicateOptions
        self.totalBeforeLimit = totalBeforeLimit; self.seconds = seconds; self.sorter = sorter; self.ctx = ctx
    }

    public var count: Int { ids.count }
    public var errors: [String] { query.errors + (filterQuery?.errors ?? []) }

    public var fileCount: Int { counts().files }
    public var folderCount: Int { counts().folders }

    private func counts() -> (files: Int, folders: Int) {
        lock.lock(); defer { lock.unlock() }
        if let c = _counts { return c }
        var f = 0, d = 0
        let s = ctx.store
        for id in ids { if s.isAlive(id) && s.isFolder(id) { d += 1 } else { f += 1 } }
        _counts = (f, d)
        return (f, d)
    }

    /// Total size of all results (files; folders count when folder sizes are indexed).
    public var totalSize: UInt64 {
        lock.lock(); defer { lock.unlock() }
        if let t = _totalSize { return t }
        var t: UInt64 = 0
        let s = ctx.store
        for id in ids where s.isAlive(id) { t &+= s.isFolder(id) && !s.trackFolderSize ? 0 : s.size(id) }
        _totalSize = t
        return t
    }

    public func totalSize(of selection: [ItemID]) -> UInt64 {
        let s = ctx.store
        var t: UInt64 = 0
        for id in selection where s.isAlive(id) { t &+= s.isFolder(id) && !s.trackFolderSize ? 0 : s.size(id) }
        return t
    }

    public func fullPath(_ id: ItemID) -> String { ctx.fullPath(id) }
    public func parentPath(_ id: ItemID) -> String { ctx.parentPath(id) }
    public var context: EvalContext { ctx }

    /// Highlight ranges for the name (and path) of an item.
    public func highlightRanges(name: String, path: String) -> (name: [Range<String.Index>], path: [Range<String.Index>]) {
        var n: [Range<String.Index>] = [], p: [Range<String.Index>] = []
        for h in query.highlighters + (filterQuery?.highlighters ?? []) {
            switch h.scope {
            case .name, .stem: n.append(contentsOf: h.matcher.ranges(in: name))
            case .ext:
                if let dot = name.lastIndex(of: ".") { n.append(contentsOf: h.matcher.ranges(in: String(name[name.index(after: dot)...])).map { r in
                    let off = name.distance(from: name.startIndex, to: name.index(after: dot))
                    let lo = name.index(name.startIndex, offsetBy: off + name.distance(from: name.startIndex, to: r.lowerBound))
                    let hi = name.index(name.startIndex, offsetBy: off + name.distance(from: name.startIndex, to: r.upperBound))
                    return lo..<hi } ) }
            case .fullPath:
                let full = Paths.join(path, name)
                for r in h.matcher.ranges(in: full) {
                    let lo = full.distance(from: full.startIndex, to: r.lowerBound), hi = full.distance(from: full.startIndex, to: r.upperBound)
                    let split = path.count + (path.hasSuffix("/") ? 0 : 1)
                    if hi <= path.count { p.append(path.index(path.startIndex, offsetBy: lo)..<path.index(path.startIndex, offsetBy: hi)) }
                    else if lo >= split { n.append(name.index(name.startIndex, offsetBy: lo - split)..<name.index(name.startIndex, offsetBy: min(name.count, hi - split))) }
                    else { p.append(path.index(path.startIndex, offsetBy: lo)..<path.endIndex); n.append(name.startIndex..<name.index(name.startIndex, offsetBy: min(name.count, hi - split))) }
                }
            case .parentPath: p.append(contentsOf: h.matcher.ranges(in: path))
            }
        }
        return (n, p)
    }

    // MARK: live updates

    /// Result of applying index changes.
    public struct Delta: Equatable, Sendable {
        public var inserted: [Int] = []     // final positions
        public var removed: [Int] = []      // positions in the old list, descending order
        public var updated: [Int] = []      // positions in the new list
        public var isEmpty: Bool { inserted.isEmpty && removed.isEmpty && updated.isEmpty }
    }

    /// Re-evaluates changed items against the query and patches the sorted list in place.
    public func apply(created: [ItemID], removed: [ItemID], modified: [ItemID]) -> Delta {
        lock.lock(); defer { lock.unlock() }
        var delta = Delta()
        guard duplicateOptions.mode == .none else { return delta } // dupe views refresh via F5
        let removedSet = Set(removed)
        let modifiedSet = Set(modified)
        var position: [ItemID: Int] = [:]
        if !removedSet.isEmpty || !modifiedSet.isEmpty {
            position.reserveCapacity(ids.count)
            for (i, id) in ids.enumerated() { position[id] = i }
        }
        // removals (and modified items that no longer match)
        var toRemove: [Int] = []
        for id in removed { if let p = position[id] { toRemove.append(p) } }
        var toInsert: [ItemID] = []
        for id in modified where ctx.store.isAlive(id) {
            var inScope = true
            if let scope = request.rootScope { inScope = scope.contains(ctx.store.root(of: id)) }
            let matches = inScope && evaluate(id)
            if let p = position[id] {
                if matches { delta.updated.append(p) } else { toRemove.append(p) }
            } else if matches {
                toInsert.append(id)
            }
        }
        for id in created where ctx.store.isAlive(id) && position[id] == nil {
            if let scope = request.rootScope, !scope.contains(ctx.store.root(of: id)) { continue }
            if evaluate(id) { toInsert.append(id) }
        }
        toRemove.sort(by: >)
        var seen = Set<Int>()
        for p in toRemove where !seen.contains(p) { seen.insert(p); ids.remove(at: p); delta.removed.append(p) }
        if !toRemove.isEmpty { delta.updated = [] }
        for id in toInsert {
            var lo = 0, hi = ids.count
            while lo < hi { let mid = (lo + hi) / 2; if sorter.less(ids[mid], id) { lo = mid + 1 } else { hi = mid } }
            ids.insert(id, at: lo)
            delta.inserted.append(lo)
        }
        if !delta.isEmpty { _totalSize = nil; _counts = nil }
        return delta
    }

    private func evaluate(_ id: ItemID) -> Bool {
        if !query.predicate.eval(id, ctx) { return false }
        if let f = filterQuery, !f.predicate.eval(id, ctx) { return false }
        return true
    }
}

/// Executes queries against an `Index`.
public final class SearchEngine: @unchecked Sendable {
    public let index: Index
    public let properties: PropertyReader
    public var runHistory: RunHistoryProviding?
    public var recentChanges: RecentChangesProviding?
    public var omissions: OmissionProviding?
    public var tempOmissions: OmissionProviding?
    public var macros: [String: String] = [:]
    public var sizeStandard: SizeStandard = .jedec
    public var wholeFilenameForWildcards = true
    public var pinyinDefault = false
    public var parseOptions = ParseOptions()
    public var contentSizeLimit = 32 * 1024 * 1024
    public var fileListFilenames: [ItemID: String] = [:]
    /// Test hook invoked after a search acquires the index read lock.
    internal var beforeSearchContext: (@Sendable () -> Void)?
    public let fastSort: FastSort
    private var pathTable: PathTable?
    private let pathLock = NSLock()
    private var lastResult: ResultSet?
    private let lastLock = NSLock()

    public init(index: Index, properties: PropertyReader = PropertyReader()) {
        self.index = index
        self.properties = properties
        self.fastSort = FastSort(index: index)
    }

    /// Path table cached per generation.
    public func currentPathTable() -> PathTable {
        // Always acquire the index lock before the cache lock. Searches already hold
        // the index read lock while building their context; taking another read lock
        // from there can deadlock when a scanner writer is queued.
        index.read { currentPathTableLocked() }
    }

    public func makeContext(now: Date = Date(), cancel: CancelToken? = nil) -> EvalContext {
        index.read { makeContextLocked(now: now, cancel: cancel) }
    }

    private func currentPathTableLocked() -> PathTable {
        pathLock.lock(); defer { pathLock.unlock() }
        if let t = pathTable, t.generation == index.store.generation { return t }
        let t = PathTable(store: index.store, roots: index.rootItems)
        pathTable = t
        return t
    }

    /// Builds a context while the caller already holds the index read lock.
    private func makeContextLocked(now: Date, cancel: CancelToken?) -> EvalContext {
        EvalContext(index: index, paths: currentPathTableLocked(), properties: properties, now: now, runHistory: runHistory,
                    recentChanges: recentChanges, fileListFilenames: fileListFilenames, cancelled: { cancel?.isCancelled ?? false })
    }

    public func compileEnv(defaults: MatchDefaults, request: QueryRequest? = nil, now: Date = Date()) -> CompileEnv {
        var env = CompileEnv()
        env.defaults = defaults
        env.wholeFilenameForWildcards = wholeFilenameForWildcards
        env.sizeStandard = sizeStandard
        env.pinyinDefault = pinyinDefault
        env.macros = macros
        env.fileListSlots = request?.fileListSlots ?? [:]
        env.contentSizeLimit = contentSizeLimit
        env.now = now
        env.index = index
        env.parseOptions = parseOptions
        return env
    }

    public func compile(_ text: String, defaults: MatchDefaults, request: QueryRequest? = nil, now: Date = Date()) -> CompiledQuery {
        let env = compileEnv(defaults: defaults, request: request, now: now)
        if defaults.regex {
            // Regex mode: the whole search is one regular expression; normal syntax is disabled.
            var mods = ModifierSet(); mods.regex = true
            let term = Term(modifiers: mods, function: nil, value: text, quoted: true, literalRest: true, range: 0..<text.count)
            let parsed = ParsedQuery(root: text.isEmpty ? .empty : .term(term), original: text)
            return QueryCompiler.compile(parsed, env: env)
        }
        return QueryCompiler.compile(text, env: env)
    }

    /// Runs a query synchronously (call from a background queue).
    public func search(_ request: QueryRequest, cancel: CancelToken? = nil, now: Date = Date()) -> ResultSet {
        let start = Date()
        return index.read {
            beforeSearchContext?()
            let ctx = makeContextLocked(now: now, cancel: cancel)
            let query = compile(request.text, defaults: request.defaults, request: request, now: now)
            var filterQuery: CompiledQuery? = nil
            if !request.filterSearch.isEmpty {
                filterQuery = compile(request.filterSearch, defaults: request.filterDefaults ?? request.defaults, request: request, now: now)
            }
            // Directives
            var sortKeys = request.sort
            var foldersFirst = request.effectiveFoldersFirst
            var limit = request.count
            var maxThreads = request.maxThreads
            var searchCurrent = request.searchCurrentResults
            var omissionsOn = request.omissionsEnabled
            var tempOmissionsOn = request.tempOmissionsEnabled
            for d in query.directives {
                switch d {
                case .sort(let names): sortKeys = names.map(SortKey.parse)
                case .sortAscending: if !sortKeys.isEmpty { sortKeys[0].ascending = true }
                case .sortDescending: if !sortKeys.isEmpty { sortKeys[0].ascending = false }
                case .sortMix(let mix): foldersFirst = mix ? .mixed : .first
                case .foldersFirst(let f): foldersFirst = (f ?? true) ? .first : .last
                case .count(let n): limit = n
                case .maxThreads(let n): maxThreads = n
                case .newSearch, .noNewResults: searchCurrent = false
                case .nothing: break
                default: break
                }
            }
            let gm = query.parsed.globalModifiers
            if let o = gm.resultOmissions { omissionsOn = o }
            if let o = gm.tempResultOmissions { tempOmissionsOn = o }
            if let s = gm.searchCurrentResults { searchCurrent = s }
            for t in query.parsed.root.terms {
                if let o = t.modifiers.resultOmissions { omissionsOn = o }
                if let o = t.modifiers.tempResultOmissions { tempOmissionsOn = o }
                if let s = t.modifiers.searchCurrentResults { searchCurrent = s }
            }
            let dupOpts = DuplicateOptions.from(directives: query.directives)
            let omit = omissionsOn ? omissions : nil
            let tomit = tempOmissionsOn ? tempOmissions : nil
            let store = index.store

            // Candidate set: previous results when refining.
            var candidates: [ItemID]? = nil
            if searchCurrent, let prev = currentLastResult(), prev.generation == store.generation, prev.duplicateOptions.mode == .none,
               prev.request.defaults == request.defaults, prev.request.filterSearch == request.filterSearch, prev.request.rootScope == request.rootScope,
               prev.request.omissionsEnabled == request.omissionsEnabled, prev.request.tempOmissionsEnabled == request.tempOmissionsEnabled,
               prev.totalBeforeLimit == prev.count, SearchEngine.isRefinement(old: prev.request.text, new: request.text) {
                candidates = prev.ids
            }

            // Evaluate
            let pred = query.predicate
            let fpred = filterQuery?.predicate
            let scope = request.rootScope
            let needsRoot = scope != nil
            let threads = maxThreads > 0 ? maxThreads : ProcessInfo.processInfo.activeProcessorCount
            var matched: [ItemID]
            if let cands = candidates {
                matched = SearchEngine.evaluate(ids: cands, threads: threads, cancel: cancel) { id in
                    store.isAlive(id) && pred.eval(id, ctx) && (fpred?.eval(id, ctx) ?? true) && !(omit?.omits(id, ctx: ctx) ?? false) && !(tomit?.omits(id, ctx: ctx) ?? false)
                }
            } else {
                let n = store.slotCount
                matched = SearchEngine.evaluate(range: 0..<n, threads: threads, cancel: cancel) { i in
                    let id = ItemID(i)
                    guard store.isAlive(id) else { return false }
                    if needsRoot, !scope!.contains(store.root(of: id)) { return false }
                    if !pred.eval(id, ctx) { return false }
                    if let f = fpred, !f.eval(id, ctx) { return false }
                    if let o = omit, o.omits(id, ctx: ctx) { return false }
                    if let o = tomit, o.omits(id, ctx: ctx) { return false }
                    return true
                }
            }
            let total = matched.count
            // Sort
            let sorter = ResultSorter(keys: sortKeys, foldersFirst: foldersFirst, ctx: ctx, fastSort: fastSort)
            if !(cancel?.isCancelled ?? false) {
                matched = sorter.sort(matched)
            }
            // Duplicates
            var groupStarts: [Int] = []
            if dupOpts.mode != .none {
                let r = Duplicates.apply(matched, options: dupOpts, ctx: ctx, sorter: sorter)
                matched = r.ids; groupStarts = r.groupStarts
            }
            // Limit / offset
            if request.offset > 0 { matched = Array(matched.dropFirst(request.offset)) }
            if limit > 0 && matched.count > limit { matched = Array(matched.prefix(limit)) }
            let rs = ResultSet(ids: matched, request: request, query: query, filterQuery: filterQuery, generation: store.generation, sortKeys: sortKeys,
                               foldersFirst: foldersFirst, groupStarts: groupStarts, duplicateOptions: dupOpts, totalBeforeLimit: total,
                               seconds: Date().timeIntervalSince(start), sorter: sorter, ctx: ctx)
            if !(cancel?.isCancelled ?? false) && request.offset == 0 && limit == 0 { setLastResult(rs) }
            return rs
        }
    }

    private func currentLastResult() -> ResultSet? { lastLock.lock(); defer { lastLock.unlock() }; return lastResult }
    private func setLastResult(_ r: ResultSet) { lastLock.lock(); lastResult = r; lastLock.unlock() }
    public func clearLastResult() { lastLock.lock(); lastResult = nil; lastLock.unlock() }

    /// A new search refines the old one when it only appends plain text to the previous (non-empty) search.
    static func isRefinement(old: String, new: String) -> Bool {
        guard !old.isEmpty, new.count > old.count, new.hasPrefix(old) else { return false }
        let added = new.dropFirst(old.count)
        if added.contains(where: { "|!<>\":".contains($0) }) { return false }
        // appending to a quoted/regex/function term can widen matches (e.g. size:>1 → size:>10); only allow when the
        // last term of the old search is plain text and no regex/wildcard is involved
        if old.contains("\"") || old.contains("regex:") || old.contains("*") || old.contains("?") || old.contains(":") || added.contains("*") || added.contains("?") { return false }
        return true
    }

    static func evaluate(range: Range<Int>, threads: Int, cancel: CancelToken?, _ test: @escaping (Int) -> Bool) -> [ItemID] {
        let n = range.count
        guard n > 0 else { return [] }
        let chunk = max(4096, (n + threads * 4 - 1) / (threads * 4))
        let chunks = (n + chunk - 1) / chunk
        var results = [[ItemID]](repeating: [], count: chunks)
        results.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                if cancel?.isCancelled ?? false { return }
                let lo = range.lowerBound + c * chunk, hi = min(range.upperBound, lo + chunk)
                var out: [ItemID] = []
                for i in lo..<hi {
                    // A query can be superseded while a predicate is evaluating a large
                    // chunk. Poll periodically so stale UI searches release the index lock
                    // promptly instead of waiting for the whole chunk to finish.
                    if (i - lo) & 127 == 0, cancel?.isCancelled ?? false { break }
                    if test(i) { out.append(ItemID(i)) }
                }
                buf[c] = out
            }
        }
        if cancel?.isCancelled ?? false { return [] }
        var merged: [ItemID] = []
        merged.reserveCapacity(results.reduce(0) { $0 + $1.count })
        for r in results { merged.append(contentsOf: r) }
        return merged
    }

    static func evaluate(ids: [ItemID], threads: Int, cancel: CancelToken?, _ test: @escaping (ItemID) -> Bool) -> [ItemID] {
        let n = ids.count
        guard n > 0 else { return [] }
        let chunk = max(2048, (n + threads * 4 - 1) / (threads * 4))
        let chunks = (n + chunk - 1) / chunk
        var results = [[ItemID]](repeating: [], count: chunks)
        results.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                if cancel?.isCancelled ?? false { return }
                let lo = c * chunk, hi = min(n, lo + chunk)
                var out: [ItemID] = []
                for i in lo..<hi {
                    if (i - lo) & 127 == 0, cancel?.isCancelled ?? false { break }
                    if test(ids[i]) { out.append(ids[i]) }
                }
                buf[c] = out
            }
        }
        if cancel?.isCancelled ?? false { return [] }
        var merged: [ItemID] = []
        for r in results { merged.append(contentsOf: r) }
        return merged
    }
}
