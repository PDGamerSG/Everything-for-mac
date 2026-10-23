import Foundation

public struct SortKey: Equatable, Hashable, Codable, Sendable {
    public var property: String      // canonical property id
    public var ascending: Bool
    public init(_ property: String, ascending: Bool = true) { self.property = QueryParser.canonical(property); self.ascending = ascending }

    /// Parses `size-descending`, `name-ascending`, `dm`.
    public static func parse(_ s: String) -> SortKey {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasSuffix("-descending") || t.hasSuffix("descending") {
            return SortKey(String(t.dropLast(t.hasSuffix("-descending") ? 11 : 10)), ascending: false)
        }
        if t.hasSuffix("-ascending") || t.hasSuffix("ascending") {
            return SortKey(String(t.dropLast(t.hasSuffix("-ascending") ? 10 : 9)), ascending: true)
        }
        return SortKey(t, ascending: true)
    }
}

public enum FoldersFirst: Int, Codable, Sendable { case mixed = 0, first = 1, last = 2 }

/// Natural (numeric-aware), case/diacritic-insensitive ordering on folded UTF-8 bytes.
public enum NaturalOrder {
    /// Returns <0, 0, >0.
    @inlinable public static func compare(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Int {
        var i = 0, j = 0
        let na = a.count, nb = b.count
        while i < na && j < nb {
            let ca = a[i], cb = b[j]
            let da = ca >= 48 && ca <= 57, db = cb >= 48 && cb <= 57
            if da && db {
                // skip leading zeros
                var si = i, sj = j
                while si < na && a[si] == 48 { si += 1 }
                while sj < nb && b[sj] == 48 { sj += 1 }
                var ei = si, ej = sj
                while ei < na && a[ei] >= 48 && a[ei] <= 57 { ei += 1 }
                while ej < nb && b[ej] >= 48 && b[ej] <= 57 { ej += 1 }
                let la = ei - si, lb = ej - sj
                if la != lb { return la - lb }
                var k = 0
                while k < la {
                    if a[si + k] != b[sj + k] { return Int(a[si + k]) - Int(b[sj + k]) }
                    k += 1
                }
                // equal numbers: fewer leading zeros first
                let za = si - i, zb = sj - j
                if za != zb { return za - zb }
                i = ei; j = ej
                continue
            }
            if ca != cb { return Int(ca) - Int(cb) }
            i += 1; j += 1
        }
        return (na - i) - (nb - j)
    }

    public static func compare(_ a: String, _ b: String) -> Int {
        let fa = Array(ItemStore.fold(a).utf8), fb = Array(ItemStore.fold(b).utf8)
        return fa.withUnsafeBufferPointer { pa in fb.withUnsafeBufferPointer { pb in compare(pa, pb) } }
    }
}

/// Sorts result IDs according to sort keys with folders-first handling.
public struct ResultSorter {
    public let keys: [SortKey]
    public let foldersFirst: FoldersFirst
    public let ctx: EvalContext
    public let fastSort: FastSort?

    public init(keys: [SortKey], foldersFirst: FoldersFirst, ctx: EvalContext, fastSort: FastSort? = nil) {
        self.keys = keys.isEmpty ? [SortKey("name")] : keys
        self.foldersFirst = foldersFirst
        self.ctx = ctx
        self.fastSort = fastSort
    }

    /// Full sort pipeline.
    public func sort(_ ids: [ItemID]) -> [ItemID] {
        guard ids.count > 1 else { return ids }
        let primary = keys[0]
        var sorted: [ItemID]
        if let fs = fastSort, fs.canOrder(primary.property), ids.count > 5_000 {
            sorted = fs.order(ids, by: primary.property, ascending: primary.ascending)
        } else {
            sorted = sortDirect(ids)
        }
        switch foldersFirst {
        case .mixed: break
        case .first:
            let s = ctx.store
            var folders: [ItemID] = [], files: [ItemID] = []
            folders.reserveCapacity(sorted.count / 8); files.reserveCapacity(sorted.count)
            for id in sorted { if s.isFolder(id) { folders.append(id) } else { files.append(id) } }
            sorted = folders + files
        case .last:
            let s = ctx.store
            var folders: [ItemID] = [], files: [ItemID] = []
            for id in sorted { if s.isFolder(id) { folders.append(id) } else { files.append(id) } }
            sorted = files + folders
        }
        return sorted
    }

    /// Comparator used for incremental insertion (live updates).
    public func less(_ a: ItemID, _ b: ItemID) -> Bool {
        let s = ctx.store
        if foldersFirst != .mixed {
            let fa = s.isFolder(a), fb = s.isFolder(b)
            if fa != fb { return foldersFirst == .first ? fa : fb }
        }
        for k in keys {
            let c = compareKey(k.property, a, b)
            if c != 0 { return k.ascending ? c < 0 : c > 0 }
        }
        // tie-breakers: name, then path
        let c = compareKey("name", a, b)
        if c != 0 { return c < 0 }
        let p = compareKey("path", a, b)
        if p != 0 { return p < 0 }
        return a < b
    }

    func sortDirect(_ ids: [ItemID]) -> [ItemID] {
        let primary = keys[0]
        let s = ctx.store
        switch primary.property {
        case "size", "datemodified", "datecreated", "dateaccessed", "datechanged", "fileid", "namelength", "depth", "childcount", "runcount", "daterun", "daterecentlychanged":
            // numeric keys: decorate-sort-undecorate
            var pairs: [(Int64, ItemID)] = []
            pairs.reserveCapacity(ids.count)
            for id in ids { pairs.append((numericKey(primary.property, id), id)) }
            let asc = primary.ascending
            pairs.sort { x, y in
                if x.0 != y.0 { return asc ? x.0 < y.0 : x.0 > y.0 }
                return nameLess(x.1, y.1)
            }
            return pairs.map { $0.1 }
        case "name":
            let asc = primary.ascending
            return ids.sorted { a, b in
                let c = compareNames(a, b)
                if c != 0 { return asc ? c < 0 : c > 0 }
                return comparePaths(a, b) < 0
            }
        case "path":
            let asc = primary.ascending
            return ids.sorted { a, b in
                let c = comparePaths(a, b)
                if c != 0 { return asc ? c < 0 : c > 0 }
                return compareNames(a, b) < 0
            }
        case "extension":
            let asc = primary.ascending
            let ext = s.extensions
            return ids.sorted { a, b in
                let ea = ext.lowerName(s.extensionID(a)), eb = ext.lowerName(s.extensionID(b))
                if ea != eb { return asc ? ea < eb : ea > eb }
                return nameLess(a, b)
            }
        default:
            // generic property: materialize text or number keys once
            var textKeys: [ItemID: String] = [:]
            var numKeys: [ItemID: Double] = [:]
            var numeric = true
            for id in ids {
                let v = PropertyAccess.value(primary.property, id: id, ctx: ctx)
                switch v {
                case .number(let d)?: numKeys[id] = d
                case .date(let ns)?: numKeys[id] = Double(ns)
                case let other?: numeric = false; textKeys[id] = other.asText
                case nil: textKeys[id] = ""
                }
            }
            let asc = primary.ascending
            if numeric {
                return ids.sorted { a, b in
                    let x = numKeys[a] ?? -Double.greatestFiniteMagnitude, y = numKeys[b] ?? -Double.greatestFiniteMagnitude
                    if x != y { return asc ? x < y : x > y }
                    return nameLess(a, b)
                }
            }
            return ids.sorted { a, b in
                let x = textKeys[a] ?? "", y = textKeys[b] ?? ""
                let c = NaturalOrder.compare(x, y)
                if c != 0 { return asc ? c < 0 : c > 0 }
                return nameLess(a, b)
            }
        }
    }

    @inline(__always) func numericKey(_ prop: String, _ id: ItemID) -> Int64 {
        let s = ctx.store
        switch prop {
        case "size": return Int64(bitPattern: s.size(id))
        case "datemodified": return s.dateModified(id)
        case "datecreated": return s.dateCreated(id)
        case "dateaccessed": return s.dateAccessed(id)
        case "datechanged": return s.dateChanged(id)
        case "fileid": return Int64(bitPattern: s.inode(id))
        case "namelength": return Int64(s.nameLengthUTF8(id))
        case "depth": return Int64(s.depth(id))
        case "childcount": return Int64(s.childCount(id))
        case "runcount": return Int64(ctx.runHistory?.runCount(forPath: ctx.fullPath(id)) ?? 0)
        case "daterun": return ctx.runHistory?.dateRun(forPath: ctx.fullPath(id)) ?? 0
        case "daterecentlychanged": return ctx.recentChanges?.dateRecentlyChanged(forPath: ctx.fullPath(id)) ?? 0
        default: return 0
        }
    }

    func compareKey(_ prop: String, _ a: ItemID, _ b: ItemID) -> Int {
        switch prop {
        case "name": return compareNames(a, b)
        case "path": return comparePaths(a, b)
        case "extension":
            let ext = ctx.store.extensions
            let ea = ext.lowerName(ctx.store.extensionID(a)), eb = ext.lowerName(ctx.store.extensionID(b))
            return ea == eb ? 0 : (ea < eb ? -1 : 1)
        case "size", "datemodified", "datecreated", "dateaccessed", "datechanged", "fileid", "namelength", "depth", "childcount", "runcount", "daterun", "daterecentlychanged":
            let x = numericKey(prop, a), y = numericKey(prop, b)
            return x == y ? 0 : (x < y ? -1 : 1)
        default:
            let va = PropertyAccess.value(prop, id: a, ctx: ctx), vb = PropertyAccess.value(prop, id: b, ctx: ctx)
            if let x = va?.asNumber, let y = vb?.asNumber, va?.asDate != nil || vb?.asDate != nil || { if case .number = va { return true }; return false }() {
                return x == y ? 0 : (x < y ? -1 : 1)
            }
            return NaturalOrder.compare(va?.asText ?? "", vb?.asText ?? "")
        }
    }

    @inline(__always) func compareNames(_ a: ItemID, _ b: ItemID) -> Int {
        let s = ctx.store
        return s.withUnicodeFoldedBytes(a) { pa in s.withUnicodeFoldedBytes(b) { pb in NaturalOrder.compare(pa, pb) } }
    }

    @inline(__always) func nameLess(_ a: ItemID, _ b: ItemID) -> Bool {
        let c = compareNames(a, b)
        return c != 0 ? c < 0 : a < b
    }

    func comparePaths(_ a: ItemID, _ b: ItemID) -> Int {
        let s = ctx.store
        let pa = s.parent(a), pb = s.parent(b)
        if pa == pb { return 0 }
        let paths = ctx.paths
        if pa != invalidItem && pb != invalidItem && paths.hasFolder(pa) && paths.hasFolder(pb) {
            return paths.withFoldedFolderPath(pa) { x in paths.withFoldedFolderPath(pb) { y in NaturalOrder.compare(x, y) } }
        }
        return NaturalOrder.compare(ctx.parentPath(a), ctx.parentPath(b))
    }
}
