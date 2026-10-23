import Foundation

/// Run-history access used by `run-count:` / `date-run:` and sorting.
public protocol RunHistoryProviding: AnyObject {
    func runCount(forPath path: String) -> Int
    func dateRun(forPath path: String) -> Int64
}

/// Recent-change access used by `date-recently-changed:` / `rc:`.
public protocol RecentChangesProviding: AnyObject {
    func dateRecentlyChanged(forPath path: String) -> Int64
}

/// Per-query evaluation context. Thread-safe for concurrent `eval` calls.
public final class EvalContext: @unchecked Sendable {
    public let index: Index
    public let store: ItemStore
    public let paths: PathTable
    public let properties: PropertyReader
    public let now: Date
    public let runHistory: RunHistoryProviding?
    public let recentChanges: RecentChangesProviding?
    public let fileListFilenames: [ItemID: String]   // root item → file list filename
    public let cancelled: () -> Bool

    public init(index: Index, paths: PathTable, properties: PropertyReader, now: Date = Date(), runHistory: RunHistoryProviding? = nil,
                recentChanges: RecentChangesProviding? = nil, fileListFilenames: [ItemID: String] = [:], cancelled: @escaping () -> Bool = { false }) {
        self.index = index; self.store = index.store; self.paths = paths; self.properties = properties; self.now = now
        self.runHistory = runHistory; self.recentChanges = recentChanges; self.fileListFilenames = fileListFilenames; self.cancelled = cancelled
    }

    public func fullPath(_ id: ItemID) -> String {
        var scratch: [UInt8] = []
        paths.fullPathBytes(id, store: store, folded: false, into: &scratch)
        return String(decoding: scratch, as: UTF8.self)
    }

    public func parentPath(_ id: ItemID) -> String {
        var scratch: [UInt8] = []
        paths.parentPathBytes(id, store: store, folded: false, into: &scratch)
        return String(decoding: scratch, as: UTF8.self)
    }

    /// Thread-local scratch buffers to avoid per-item allocation.
    public var scratch: [UInt8] {
        get { (Thread.current.threadDictionary["evt.scratch"] as? [UInt8]) ?? [] }
        set { Thread.current.threadDictionary["evt.scratch"] = newValue }
    }
}

/// Compiled filter node.
public protocol Predicate: AnyObject {
    /// Relative cost: 1 = index-only cheap, 10 = string materialization, 100 = property read, 1000 = content read.
    var cost: Int { get }
    func eval(_ id: ItemID, _ ctx: EvalContext) -> Bool
}

public final class AllPredicate: Predicate {
    public init() {}
    public var cost: Int { 0 }
    public func eval(_ id: ItemID, _ ctx: EvalContext) -> Bool { true }
}

public final class NonePredicate: Predicate {
    public init() {}
    public var cost: Int { 0 }
    public func eval(_ id: ItemID, _ ctx: EvalContext) -> Bool { false }
}

public final class AndPredicate: Predicate {
    public let children: [Predicate]
    public init(_ children: [Predicate], reorder: Bool = true) {
        self.children = reorder ? children.sorted { $0.cost < $1.cost } : children
    }
    public var cost: Int { children.map { $0.cost }.max() ?? 0 }
    public func eval(_ id: ItemID, _ ctx: EvalContext) -> Bool {
        for c in children where !c.eval(id, ctx) { return false }
        return true
    }
}

public final class OrPredicate: Predicate {
    public let children: [Predicate]
    public init(_ children: [Predicate], reorder: Bool = true) {
        self.children = reorder ? children.sorted { $0.cost < $1.cost } : children
    }
    public var cost: Int { children.map { $0.cost }.max() ?? 0 }
    public func eval(_ id: ItemID, _ ctx: EvalContext) -> Bool {
        for c in children where c.eval(id, ctx) { return true }
        return false
    }
}

public final class NotPredicate: Predicate {
    public let child: Predicate
    public init(_ child: Predicate) { self.child = child }
    public var cost: Int { child.cost }
    public func eval(_ id: ItemID, _ ctx: EvalContext) -> Bool { !child.eval(id, ctx) }
}

public final class ClosurePredicate: Predicate {
    public let cost: Int
    let body: (ItemID, EvalContext) -> Bool
    public init(cost: Int, _ body: @escaping (ItemID, EvalContext) -> Bool) { self.cost = cost; self.body = body }
    public func eval(_ id: ItemID, _ ctx: EvalContext) -> Bool { body(id, ctx) }
}

/// Which string of an item a text matcher applies to.
public enum TextScope: Equatable, Sendable { case name, stem, ext, fullPath, parentPath }

/// Text match on name / path with byte fast paths.
public final class TextPredicate: Predicate {
    public let matcher: TextMatcher
    public let scope: TextScope
    public init(matcher: TextMatcher, scope: TextScope) { self.matcher = matcher; self.scope = scope }
    public var cost: Int {
        switch scope {
        case .name, .ext: return matcher.usesFoldedBytes || matcher.usesRawBytes ? 1 : 5
        case .stem: return 6
        case .fullPath, .parentPath: return matcher.usesFoldedBytes || matcher.usesRawBytes ? 3 : 12
        }
    }

    public func eval(_ id: ItemID, _ ctx: EvalContext) -> Bool {
        let store = ctx.store
        switch scope {
        case .name:
            if matcher.usesFoldedBytes { return store.withUnicodeFoldedBytes(id) { matcher.matchesFolded($0) } }
            if matcher.usesRawBytes { return store.withNameBytes(id) { matcher.matchesRaw($0) } }
            return matcher.matches(store.name(id))
        case .ext:
            return matcher.matches(store.extensionName(id))
        case .stem:
            return matcher.matches(store.stem(id))
        case .fullPath, .parentPath:
            var scratch = ctx.scratch
            defer { ctx.scratch = scratch }
            if matcher.usesFoldedBytes {
                if scope == .fullPath { ctx.paths.fullPathBytes(id, store: store, folded: true, into: &scratch) }
                else { ctx.paths.parentPathBytes(id, store: store, folded: true, into: &scratch) }
                return scratch.withUnsafeBufferPointer { matcher.matchesFolded($0) }
            }
            if matcher.usesRawBytes {
                if scope == .fullPath { ctx.paths.fullPathBytes(id, store: store, folded: false, into: &scratch) }
                else { ctx.paths.parentPathBytes(id, store: store, folded: false, into: &scratch) }
                return scratch.withUnsafeBufferPointer { matcher.matchesRaw($0) }
            }
            let s = scope == .fullPath ? ctx.fullPath(id) : ctx.parentPath(id)
            return matcher.matches(s)
        }
    }
}
