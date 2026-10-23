import Foundation

/// One change applied to the index (Index Journal entry).
public struct JournalEntry: Equatable, Codable, Sendable {
    public enum Action: String, Codable, CaseIterable, Sendable {
        case fileCreate = "File Create", folderCreate = "Folder Create"
        case fileDelete = "File Delete", folderDelete = "Folder Delete"
        case fileRename = "File Rename", folderRename = "Folder Rename"
        case fileMove = "File Move", folderMove = "Folder Move"
        case fileModify = "File Modify", folderModify = "Folder Modify"

        public var isFolder: Bool { rawValue.hasPrefix("Folder") }
        public var kind: String { String(rawValue.split(separator: " ").last ?? "") }
    }

    public var changeID: UInt64
    public var date: Int64
    public var action: Action
    public var name: String
    public var path: String          // parent path
    public var newName: String       // for rename/move
    public var newPath: String
    public var size: UInt64

    public init(changeID: UInt64, date: Int64, action: Action, name: String, path: String, newName: String = "", newPath: String = "", size: UInt64 = 0) {
        self.changeID = changeID; self.date = date; self.action = action; self.name = name; self.path = path
        self.newName = newName; self.newPath = newPath; self.size = size
    }

    public var fullPath: String { Paths.join(path, name) }
    public var newFullPath: String { newName.isEmpty ? "" : Paths.join(newPath, newName) }
    var approximateBytes: Int { 64 + name.utf8.count + path.utf8.count + newName.utf8.count + newPath.utf8.count }
}

/// Bounded ring of index changes, persisted to Journal.db. Also serves `date-recently-changed:`.
public final class IndexJournal: RecentChangesProviding, @unchecked Sendable {
    public let journalID: UInt64
    public private(set) var nextChangeID: UInt64
    public var maxBytes: Int
    public var enabled = true
    private(set) var entries: [JournalEntry] = []
    private var bytes = 0
    private var recent: [String: Int64] = [:]        // full path → date of last change
    private var recentOrder: [String] = []
    public var maxRecent = 200_000
    private let lock = NSLock()
    public var onAppend: ((JournalEntry) -> Void)?
    private var watchers: [(UUID, (JournalEntry) -> Void)] = []

    public init(journalID: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000), maxKB: Int = 1024) {
        self.journalID = journalID
        self.nextChangeID = 1
        self.maxBytes = maxKB * 1024
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    public var all: [JournalEntry] { lock.lock(); defer { lock.unlock() }; return entries }
    public var firstChangeID: UInt64 { lock.lock(); defer { lock.unlock() }; return entries.first?.changeID ?? nextChangeID }

    @discardableResult
    public func append(_ action: JournalEntry.Action, name: String, path: String, newName: String = "", newPath: String = "", size: UInt64 = 0, date: Int64 = Timestamps.now()) -> JournalEntry? {
        lock.lock()
        let e = JournalEntry(changeID: nextChangeID, date: date, action: action, name: name, path: path, newName: newName, newPath: newPath, size: size)
        nextChangeID += 1
        // recent changes always tracked (cheap), journal entries only when enabled
        let key = e.newName.isEmpty ? e.fullPath : e.newFullPath
        if recent[key] == nil { recentOrder.append(key) }
        recent[key] = date
        if recentOrder.count > maxRecent {
            let drop = recentOrder.prefix(maxRecent / 10)
            for k in drop { recent[k] = nil }
            recentOrder.removeFirst(drop.count)
        }
        guard enabled else { lock.unlock(); return nil }
        entries.append(e)
        bytes += e.approximateBytes
        while bytes > maxBytes, let first = entries.first { bytes -= first.approximateBytes; entries.removeFirst() }
        let ws = watchers
        lock.unlock()
        onAppend?(e)
        for (_, w) in ws { w(e) }
        return e
    }

    public func clear() { lock.lock(); entries.removeAll(); bytes = 0; lock.unlock() }

    // MARK: query

    public struct Query: Equatable, Sendable {
        public var actions: Set<JournalEntry.Action>? = nil
        public var text: String = ""
        public var regex = false
        public var fromChangeID: UInt64? = nil
        public var toChangeID: UInt64? = nil          // exclusive
        public var fromDate: Int64? = nil
        public var toDate: Int64? = nil               // exclusive
        public var addedOnly = false                  // match new names only (created/renamed/moved)
        public var removedOnly = false                // match old names only (deleted/renamed/moved)
        public init() {}
    }

    public func query(_ q: Query) -> [JournalEntry] {
        lock.lock(); let snapshot = entries; lock.unlock()
        var matcher: TextMatcher? = nil
        if !q.text.isEmpty {
            var mode = MatchMode()
            mode.regex = q.regex
            mode.wholeFilenameForWildcards = true
            matcher = TextMatcher(pattern: q.text, mode: mode)
        }
        return snapshot.filter { e in
            if let a = q.actions, !a.contains(e.action) { return false }
            if let f = q.fromChangeID, e.changeID < f { return false }
            if let t = q.toChangeID, e.changeID >= t { return false }
            if let f = q.fromDate, e.date < f { return false }
            if let t = q.toDate, e.date >= t { return false }
            guard let m = matcher else { return true }
            let oldHit = m.matches(e.name) || m.matches(e.path) || m.matches(e.fullPath)
            let newHit = !e.newName.isEmpty && (m.matches(e.newName) || m.matches(e.newPath) || m.matches(e.newFullPath))
            if q.addedOnly { return (e.action.kind == "Create" && oldHit) || newHit }
            if q.removedOnly { return (e.action.kind == "Delete" && oldHit) || (!e.newName.isEmpty && oldHit) }
            return oldHit || newHit
        }
    }

    @discardableResult
    public func watch(_ body: @escaping (JournalEntry) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); watchers.append((id, body)); lock.unlock()
        return id
    }

    public func unwatch(_ id: UUID) { lock.lock(); watchers.removeAll { $0.0 == id }; lock.unlock() }

    // MARK: RecentChangesProviding

    public func dateRecentlyChanged(forPath path: String) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return recent[path] ?? 0
    }

    public func recentPaths() -> [String: Int64] { lock.lock(); defer { lock.unlock() }; return recent }

    // MARK: persistence

    private struct Snapshot: Codable { var journalID: UInt64; var nextChangeID: UInt64; var entries: [JournalEntry]; var recent: [String: Int64] }

    public func save(to url: URL) throws {
        lock.lock()
        let snap = Snapshot(journalID: journalID, nextChangeID: nextChangeID, entries: entries, recent: recent)
        lock.unlock()
        let data = try JSONEncoder().encode(snap)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public static func load(from url: URL, maxKB: Int) -> IndexJournal? {
        guard let data = try? Data(contentsOf: url), let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        let j = IndexJournal(journalID: snap.journalID, maxKB: maxKB)
        j.nextChangeID = snap.nextChangeID
        j.entries = snap.entries
        j.bytes = snap.entries.reduce(0) { $0 + $1.approximateBytes }
        j.recent = snap.recent
        j.recentOrder = snap.recent.sorted { $0.value < $1.value }.map { $0.key }
        return j
    }

    /// CSV export used by the Index Journal window and `es -journal`.
    public func exportCSV(_ entries: [JournalEntry]) -> String {
        var t = CSVTable(headers: ["Change ID", "Date", "Action", "Name", "Path", "New Name", "New Path", "Size"])
        for e in entries {
            t.rows.append([String(e.changeID), DateFormat.iso(e.date), e.action.rawValue, e.name, e.path, e.newName, e.newPath, String(e.size)])
        }
        return t.render()
    }
}
