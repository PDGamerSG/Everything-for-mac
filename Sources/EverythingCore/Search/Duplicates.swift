import Foundation

/// Find Duplicates / distinct / unique post-processing.
public enum DuplicateMode: Equatable, Sendable { case none, dupe, unique, distinct }

public struct DuplicateOptions: Equatable, Sendable {
    public var mode: DuplicateMode = .none
    public var properties: [String] = ["name"]      // canonical property ids (max 8)
    public var distinctSort: [SortKey] = []
    public var dupeCount: Int? = nil                // items shown per group
    public var dupeMin: Int? = nil
    public var dupeMax: Int? = nil
    public var dupeFrom: String? = nil              // folder path (wildcards allowed)

    public init() {}

    public static func from(directives: [UIDirective]) -> DuplicateOptions {
        var o = DuplicateOptions()
        for d in directives {
            switch d {
            case .dupe(let p): o.mode = .dupe; if !p.isEmpty { o.properties = p.map(QueryParser.canonical) }
            case .unique(let p): o.mode = .unique; if !p.isEmpty { o.properties = p.map(QueryParser.canonical) }
            case .distinct(let p): o.mode = .distinct; if !p.isEmpty { o.properties = p.map(QueryParser.canonical) }
            case .distinctSort(let p): o.distinctSort = p.map(SortKey.parse)
            case .dupeCount(let n): o.dupeCount = n
            case .dupeMin(let n): o.dupeMin = n
            case .dupeMax(let n): o.dupeMax = n
            case .dupeFrom(let p): o.dupeFrom = Paths.normalize(p)
            default: break
            }
        }
        if o.properties.count > 8 { o.properties = Array(o.properties.prefix(8)) }
        return o
    }
}

public struct DuplicateResult: Sendable {
    public var ids: [ItemID]
    /// Indexes in `ids` where a new group starts (for divider lines). Always contains 0 when non-empty.
    public var groupStarts: [Int]
}

public enum Duplicates {
    /// Key string for an item over the given properties.
    public static func key(_ id: ItemID, properties: [String], ctx: EvalContext) -> String {
        var parts: [String] = []
        let s = ctx.store
        for p in properties {
            switch p {
            case "name": parts.append(ItemStore.fold(s.name(id)))
            case "size": parts.append(String(s.size(id)))
            case "datemodified": parts.append(String(s.dateModified(id)))
            case "datecreated": parts.append(String(s.dateCreated(id)))
            case "extension", "ext": parts.append(s.extensions.lowerName(s.extensionID(id)))
            case "stem": parts.append(ItemStore.fold(s.stem(id)))
            case "path": parts.append(ItemStore.fold(ctx.parentPath(id)))
            default:
                parts.append(ItemStore.fold(PropertyAccess.text(p, id: id, ctx: ctx)))
            }
        }
        return parts.joined(separator: "\u{1F}")
    }

    /// Applies duplicate processing to an already-sorted list. Items in the same group are kept adjacent.
    public static func apply(_ sorted: [ItemID], options: DuplicateOptions, ctx: EvalContext, sorter: ResultSorter) -> DuplicateResult {
        guard options.mode != .none, !sorted.isEmpty else { return DuplicateResult(ids: sorted, groupStarts: []) }
        // Content hashes are expensive: only compute them for items that already collide on the other properties.
        let hashProps: Set<String> = ["md5", "sha1", "sha256", "sha512", "crc32", "crc64"]
        let cheap = options.properties.filter { !hashProps.contains($0) }
        let expensive = options.properties.filter { hashProps.contains($0) }
        var groups: [String: [ItemID]] = [:]
        var order: [String] = []
        for id in sorted {
            let k = key(id, properties: cheap, ctx: ctx)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(id)
        }
        if !expensive.isEmpty {
            var refined: [String: [ItemID]] = [:]
            var refinedOrder: [String] = []
            for k in order {
                let members = groups[k]!
                if members.count < 2 && options.mode != .unique {
                    continue
                }
                for id in members {
                    if ctx.cancelled() { break }
                    let hk = k + "\u{1F}" + key(id, properties: expensive, ctx: ctx)
                    if refined[hk] == nil { refinedOrder.append(hk) }
                    refined[hk, default: []].append(id)
                }
            }
            groups = refined; order = refinedOrder
        }
        var dupeFromPattern: WildcardPattern? = nil
        if let f = options.dupeFrom { dupeFromPattern = WildcardPattern(f.contains("*") || f.contains("?") ? f : f + "*", extended: false, starAll: true) }

        var out: [ItemID] = []
        var starts: [Int] = []
        for k in order {
            guard var members = groups[k] else { continue }
            switch options.mode {
            case .unique:
                if members.count == 1 { out.append(members[0]) }
                continue
            case .distinct:
                if !options.distinctSort.isEmpty {
                    let ds = ResultSorter(keys: options.distinctSort, foldersFirst: .mixed, ctx: ctx)
                    members = ds.sort(members)
                }
                out.append(members[0])
                continue
            case .dupe:
                guard members.count >= 2 else { continue }
                if let mn = options.dupeMin, members.count < mn { continue }
                if let mx = options.dupeMax, members.count > mx { continue }
                if let pat = dupeFromPattern, !members.contains(where: { pat.matches(ctx.fullPath($0)) }) { continue }
                if let c = options.dupeCount, c > 0, members.count > c { members = Array(members.prefix(c)) }
                starts.append(out.count)
                out.append(contentsOf: members)
            case .none: break
            }
        }
        return DuplicateResult(ids: out, groupStarts: starts)
    }
}
