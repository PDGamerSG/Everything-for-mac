import Foundation

/// Search history (autocomplete, Ctrl+Space, Alt+Down, History window).
public final class SearchHistory: @unchecked Sendable {
    public struct Entry: Equatable, Codable, Sendable { public var search: String; public var count: Int; public var date: Int64 }
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    public var enabled = true
    public var keepDays = 0           // 0 = forever
    public var maxEntries = 10_000

    public init() {}

    public static func load(from url: URL = AppPaths.searchHistoryFile) -> SearchHistory {
        let h = SearchHistory()
        guard let t = CSVTable.load(url) else { return h }
        for r in t.rows {
            guard let s = t.value(r, "Search"), !s.isEmpty else { continue }
            let count = Int(t.value(r, "Count") ?? "1") ?? 1
            let date = DateFormat.parse(t.value(r, "Date") ?? "") ?? Int64((t.value(r, "Date") ?? "0").split(separator: ".").first.flatMap { Int64($0) } ?? 0)
            h.entries[s] = Entry(search: s, count: count, date: date)
        }
        return h
    }

    public func save(to url: URL = AppPaths.searchHistoryFile) throws {
        lock.lock()
        var t = CSVTable(headers: ["Search", "Count", "Date"])
        for e in entries.values.sorted(by: { $0.date > $1.date }) { t.rows.append([e.search, String(e.count), DateFormat.iso(e.date)]) }
        lock.unlock()
        try t.write(to: url)
    }

    public func record(_ search: String, date: Int64 = Timestamps.now()) {
        let s = search.trimmingCharacters(in: .whitespaces)
        guard enabled, !s.isEmpty else { return }
        lock.lock()
        if var e = entries[s] { e.count += 1; e.date = date; entries[s] = e } else { entries[s] = Entry(search: s, count: 1, date: date) }
        if entries.count > maxEntries {
            let victims = entries.values.sorted { $0.date < $1.date }.prefix(entries.count - maxEntries)
            for v in victims { entries[v.search] = nil }
        }
        lock.unlock()
    }

    public func remove(_ search: String) { lock.lock(); entries[search] = nil; lock.unlock() }
    public func clear() { lock.lock(); entries.removeAll(); lock.unlock() }
    public var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    public enum Sort { case date, count, search }

    public func all(sortedBy sort: Sort = .date) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        switch sort {
        case .date: return entries.values.sorted { $0.date > $1.date }
        case .count: return entries.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.date > $1.date }
        case .search: return entries.values.sorted { $0.search.localizedCaseInsensitiveCompare($1.search) == .orderedAscending }
        }
    }

    /// Suggestions whose text starts with (or contains) the prefix, most recent first.
    public func suggestions(for prefix: String, limit: Int = 20) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let p = prefix.lowercased()
        let starts = entries.values.filter { p.isEmpty || $0.search.lowercased().hasPrefix(p) }.sorted { $0.date > $1.date }
        var out = starts.map { $0.search }
        if out.count < limit && !p.isEmpty {
            let contains = entries.values.filter { !$0.search.lowercased().hasPrefix(p) && $0.search.lowercased().contains(p) }.sorted { $0.date > $1.date }
            out.append(contentsOf: contains.map { $0.search })
        }
        return Array(out.prefix(limit))
    }

    /// Longest-common autocomplete for Ctrl+Space.
    public func autocomplete(_ prefix: String) -> String? { suggestions(for: prefix, limit: 1).first { $0.lowercased().hasPrefix(prefix.lowercased()) && $0.count > prefix.count } }

    public func prune(now: Int64 = Timestamps.now()) {
        guard keepDays > 0 else { return }
        let cutoff = now - Int64(keepDays) * 86_400 * 1_000_000_000
        lock.lock()
        for (k, e) in entries where e.date < cutoff { entries[k] = nil }
        lock.unlock()
    }
}

/// Run history: how often and when each item was opened from Everything.
public final class RunHistory: RunHistoryProviding, @unchecked Sendable {
    public struct Entry: Equatable, Codable, Sendable { public var path: String; public var count: Int; public var dateRun: Int64 }
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    public var enabled = true
    public var keepDays = 0
    public var onChange: ((String) -> Void)?

    public init() {}

    public static func load(from url: URL = AppPaths.runHistoryFile) -> RunHistory {
        let h = RunHistory()
        guard let t = CSVTable.load(url) else { return h }
        for r in t.rows {
            guard let p = t.value(r, "Filename") ?? t.value(r, "Path"), !p.isEmpty else { continue }
            let count = Int(t.value(r, "Count") ?? "1") ?? 1
            let d = t.value(r, "Date Run") ?? ""
            let date = DateFormat.parse(d) ?? 0
            h.entries[p] = Entry(path: p, count: count, dateRun: date)
        }
        return h
    }

    public func save(to url: URL = AppPaths.runHistoryFile) throws {
        lock.lock()
        var t = CSVTable(headers: ["Filename", "Count", "Date Run"])
        for e in entries.values.sorted(by: { $0.dateRun > $1.dateRun }) { t.rows.append([e.path, String(e.count), DateFormat.iso(e.dateRun)]) }
        lock.unlock()
        try t.write(to: url)
    }

    public func runCount(forPath path: String) -> Int { lock.lock(); defer { lock.unlock() }; return entries[path]?.count ?? 0 }
    public func dateRun(forPath path: String) -> Int64 { lock.lock(); defer { lock.unlock() }; return entries[path]?.dateRun ?? 0 }

    @discardableResult
    public func increment(_ path: String, date: Int64 = Timestamps.now()) -> Int {
        guard enabled else { return 0 }
        lock.lock()
        var e = entries[path] ?? Entry(path: path, count: 0, dateRun: 0)
        e.count += 1; e.dateRun = date
        entries[path] = e
        lock.unlock()
        onChange?(path)
        return e.count
    }

    public func set(_ path: String, count: Int, date: Int64 = Timestamps.now()) {
        lock.lock()
        if count <= 0 { entries[path] = nil } else { entries[path] = Entry(path: path, count: count, dateRun: entries[path]?.dateRun ?? date) }
        lock.unlock()
        onChange?(path)
    }

    public func rename(from old: String, to new: String) {
        lock.lock()
        if var e = entries.removeValue(forKey: old) { e.path = new; entries[new] = e }
        // descendants
        let prefix = old.hasSuffix("/") ? old : old + "/"
        for (k, var e) in entries where k.hasPrefix(prefix) { entries[k] = nil; e.path = new + String(k.dropFirst(old.count)); entries[e.path] = e }
        lock.unlock()
    }

    public func clear() { lock.lock(); entries.removeAll(); lock.unlock(); onChange?("") }
    public var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    public func all() -> [Entry] { lock.lock(); defer { lock.unlock() }; return Array(entries.values) }

    /// Most frequently run item among `ids` (Enter in the search box).
    public func mostRun(among paths: [String]) -> String? {
        lock.lock(); defer { lock.unlock() }
        var best: (String, Int, Int64)? = nil
        for p in paths { if let e = entries[p], e.count > 0, best == nil || e.count > best!.1 || (e.count == best!.1 && e.dateRun > best!.2) { best = (p, e.count, e.dateRun) } }
        return best?.0
    }

    public func prune(now: Int64 = Timestamps.now()) {
        guard keepDays > 0 else { return }
        let cutoff = now - Int64(keepDays) * 86_400 * 1_000_000_000
        lock.lock()
        for (k, e) in entries where e.dateRun < cutoff { entries[k] = nil }
        lock.unlock()
    }
}
