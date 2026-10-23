import Foundation

/// Interns file extensions (lowercased, without the dot) to small integer IDs.
/// ID 0 is the empty extension.
public final class ExtensionTable {
    private var names: [String] = [""]
    private var lowerNames: [String] = [""]
    private var ids: [String: UInt16] = ["": 0]
    private let lock = NSLock()

    public init() {}

    public var count: Int { lock.lock(); defer { lock.unlock() }; return names.count }

    public func id(for ext: String) -> UInt16 {
        let key = ext.lowercased()
        lock.lock(); defer { lock.unlock() }
        if let i = ids[key] { return i }
        guard names.count < 65535 else { return 0 }
        let i = UInt16(names.count)
        names.append(ext)
        lowerNames.append(key)
        ids[key] = i
        return i
    }

    public func lookup(_ ext: String) -> UInt16? {
        lock.lock(); defer { lock.unlock() }
        return ids[ext.lowercased()]
    }

    public func name(_ id: UInt16) -> String {
        lock.lock(); defer { lock.unlock() }
        return Int(id) < names.count ? names[Int(id)] : ""
    }

    public func lowerName(_ id: UInt16) -> String {
        lock.lock(); defer { lock.unlock() }
        return Int(id) < lowerNames.count ? lowerNames[Int(id)] : ""
    }

    public var allNames: [String] { lock.lock(); defer { lock.unlock() }; return names }

    /// IDs whose extension matches a wildcard pattern (`*`, `?`) or exact name.
    public func ids(matching pattern: String) -> Set<UInt16> {
        lock.lock(); defer { lock.unlock() }
        let p = pattern.lowercased()
        if !p.contains("*") && !p.contains("?") {
            return ids[p].map { [$0] } ?? []
        }
        let w = WildcardPattern(p, extended: false)
        var out = Set<UInt16>()
        for (i, n) in lowerNames.enumerated() where w.matches(n) { out.insert(UInt16(i)) }
        return out
    }

    /// Rebuild from a saved list (DB load). Order defines IDs.
    public func load(names list: [String]) {
        lock.lock(); defer { lock.unlock() }
        names = list.isEmpty ? [""] : list
        lowerNames = names.map { $0.lowercased() }
        ids = [:]
        for (i, n) in lowerNames.enumerated() where ids[n] == nil { ids[n] = UInt16(i) }
    }
}
