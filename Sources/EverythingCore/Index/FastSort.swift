import Foundation

/// Precomputed global orderings (permutations) of all items by name and path, so sorting very large result
/// sets is a linear filter over the permutation instead of a comparison sort.
public final class FastSort: @unchecked Sendable {
    private let index: Index
    private var rank: [String: [Int32]] = [:]       // property → rank per slot (position in sorted order)
    private var builtGeneration: UInt64 = .max
    private var building = false
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "everything.fastsort", qos: .utility)
    public var enabledProperties: Set<String> = ["name", "path"]

    public init(index: Index) { self.index = index }

    public var isCurrent: Bool { lock.lock(); defer { lock.unlock() }; return builtGeneration == index.store.generation && !rank.isEmpty }

    public func canOrder(_ property: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return builtGeneration == index.store.generation && rank[property] != nil
    }

    /// Kicks off a background rebuild when stale.
    public func ensureBuilt(completion: (() -> Void)? = nil) {
        lock.lock()
        if building || builtGeneration == index.store.generation { lock.unlock(); completion?(); return }
        building = true
        lock.unlock()
        queue.async { [self] in
            self.rebuild()
            completion?()
        }
    }

    public func rebuild() {
        let gen = index.store.generation
        let store = index.store
        let roots = index.read { index.rootItems }
        let paths = PathTable(store: store, roots: roots)
        var alive: [Int32] = []
        alive.reserveCapacity(store.count)
        for i in 0..<store.slotCount where store.isAlive(ItemID(i)) { alive.append(ItemID(i)) }
        var newRank: [String: [Int32]] = [:]
        if enabledProperties.contains("name") {
            var order = alive
            order.sort { a, b in
                let c = store.withUnicodeFoldedBytes(a) { pa in store.withUnicodeFoldedBytes(b) { pb in NaturalOrder.compare(pa, pb) } }
                return c != 0 ? c < 0 : a < b
            }
            var r = [Int32](repeating: -1, count: store.slotCount)
            for (pos, id) in order.enumerated() { r[Int(id)] = Int32(pos) }
            newRank["name"] = r
        }
        if enabledProperties.contains("path") {
            var order = alive
            order.sort { a, b in
                let pa = store.parent(a), pb = store.parent(b)
                if pa != pb, pa != invalidItem, pb != invalidItem, paths.hasFolder(pa), paths.hasFolder(pb) {
                    let c = paths.withFoldedFolderPath(pa) { x in paths.withFoldedFolderPath(pb) { y in NaturalOrder.compare(x, y) } }
                    if c != 0 { return c < 0 }
                }
                let c = store.withUnicodeFoldedBytes(a) { x in store.withUnicodeFoldedBytes(b) { y in NaturalOrder.compare(x, y) } }
                return c != 0 ? c < 0 : a < b
            }
            var r = [Int32](repeating: -1, count: store.slotCount)
            for (pos, id) in order.enumerated() { r[Int(id)] = Int32(pos) }
            newRank["path"] = r
        }
        lock.lock()
        rank = newRank
        builtGeneration = gen
        building = false
        lock.unlock()
    }

    /// Orders `ids` by the precomputed rank (counting-sort style: O(n log n) on small ints, no string compares).
    public func order(_ ids: [ItemID], by property: String, ascending: Bool) -> [ItemID] {
        lock.lock()
        guard let r = rank[property] else { lock.unlock(); return ids }
        lock.unlock()
        var pairs: [(Int32, ItemID)] = []
        pairs.reserveCapacity(ids.count)
        for id in ids { pairs.append((Int(id) < r.count ? r[Int(id)] : Int32.max, id)) }
        pairs.sort { ascending ? $0.0 < $1.0 : $0.0 > $1.0 }
        return pairs.map { $0.1 }
    }

    public func invalidate() { lock.lock(); builtGeneration = .max; lock.unlock() }
}
