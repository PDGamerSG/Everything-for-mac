import Foundation

/// A saved search (search text, options, filter, sort).
public struct Bookmark: Equatable, Hashable, Codable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var search: String
    public var filter: String
    public var sort: String             // property id
    public var sortAscending: Bool
    public var matchCase: Bool
    public var matchWholeWord: Bool
    public var matchPath: Bool
    public var matchDiacritics: Bool
    public var regex: Bool
    public var matchPrefix: Bool
    public var matchSuffix: Bool
    public var ignorePunctuation: Bool
    public var ignoreWhitespace: Bool
    public var foldersFirst: Int        // 0 default, 1 first, 2 last, 3 mixed
    public var key: String
    public var useCurrentOptions: Bool  // when false, the stored options are applied

    public init(name: String, search: String, filter: String = "Everything", sort: String = "name", sortAscending: Bool = true, matchCase: Bool = false,
                matchWholeWord: Bool = false, matchPath: Bool = false, matchDiacritics: Bool = false, regex: Bool = false, matchPrefix: Bool = false,
                matchSuffix: Bool = false, ignorePunctuation: Bool = false, ignoreWhitespace: Bool = false, foldersFirst: Int = 0, key: String = "", useCurrentOptions: Bool = false) {
        self.name = name; self.search = search; self.filter = filter; self.sort = sort; self.sortAscending = sortAscending; self.matchCase = matchCase
        self.matchWholeWord = matchWholeWord; self.matchPath = matchPath; self.matchDiacritics = matchDiacritics; self.regex = regex
        self.matchPrefix = matchPrefix; self.matchSuffix = matchSuffix; self.ignorePunctuation = ignorePunctuation; self.ignoreWhitespace = ignoreWhitespace
        self.foldersFirst = foldersFirst; self.key = key; self.useCurrentOptions = useCurrentOptions
    }

    public var defaults: MatchDefaults {
        var d = MatchDefaults()
        d.matchCase = matchCase; d.matchWholeWords = matchWholeWord; d.matchPath = matchPath; d.matchDiacritics = matchDiacritics; d.regex = regex
        d.matchPrefix = matchPrefix; d.matchSuffix = matchSuffix; d.ignorePunctuation = ignorePunctuation; d.ignoreWhitespace = ignoreWhitespace
        return d
    }

    public var isSeparator: Bool { search.lowercased().contains("menu-separator:") }
}

/// Bookmarks.csv persistence.
public final class BookmarkStore: @unchecked Sendable {
    public private(set) var bookmarks: [Bookmark] = []
    private let lock = NSLock()
    public var onChange: (() -> Void)?

    public init(bookmarks: [Bookmark] = []) { self.bookmarks = bookmarks }

    public static let headers = ["Name", "Case", "Whole Word", "Path", "Diacritics", "Regex", "Search", "Filter", "Sort", "Sort Ascending", "Key", "Prefix", "Suffix", "Ignore Punctuation", "Ignore Whitespace", "Folders First", "Use Current Options"]

    public static func load(from url: URL = AppPaths.bookmarksFile) -> BookmarkStore {
        guard let t = CSVTable.load(url), t.column("Name") != nil else { return BookmarkStore() }
        var out: [Bookmark] = []
        for r in t.rows {
            guard let name = t.value(r, "Name"), !name.isEmpty else { continue }
            func b(_ c: String, _ def: Bool = false) -> Bool { INIFile.parseBool(t.value(r, c) ?? (def ? "1" : "0")) ?? def }
            out.append(Bookmark(name: name, search: t.value(r, "Search") ?? "", filter: t.value(r, "Filter") ?? "Everything", sort: t.value(r, "Sort") ?? "name",
                                sortAscending: b("Sort Ascending", true), matchCase: b("Case"), matchWholeWord: b("Whole Word"), matchPath: b("Path"),
                                matchDiacritics: b("Diacritics"), regex: b("Regex"), matchPrefix: b("Prefix"), matchSuffix: b("Suffix"),
                                ignorePunctuation: b("Ignore Punctuation"), ignoreWhitespace: b("Ignore Whitespace"), foldersFirst: Int(t.value(r, "Folders First") ?? "0") ?? 0,
                                key: t.value(r, "Key") ?? "", useCurrentOptions: b("Use Current Options")))
        }
        return BookmarkStore(bookmarks: out)
    }

    public func table() -> CSVTable {
        lock.lock(); defer { lock.unlock() }
        var t = CSVTable(headers: BookmarkStore.headers)
        for b in bookmarks {
            t.rows.append([b.name, b.matchCase ? "1" : "0", b.matchWholeWord ? "1" : "0", b.matchPath ? "1" : "0", b.matchDiacritics ? "1" : "0", b.regex ? "1" : "0",
                           b.search, b.filter, b.sort, b.sortAscending ? "1" : "0", b.key, b.matchPrefix ? "1" : "0", b.matchSuffix ? "1" : "0",
                           b.ignorePunctuation ? "1" : "0", b.ignoreWhitespace ? "1" : "0", String(b.foldersFirst), b.useCurrentOptions ? "1" : "0"])
        }
        return t
    }

    public func save(to url: URL = AppPaths.bookmarksFile) throws { try table().write(to: url) }

    public func bookmark(named name: String) -> Bookmark? {
        lock.lock(); defer { lock.unlock() }
        return bookmarks.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
    public func set(_ list: [Bookmark]) { lock.lock(); bookmarks = list; lock.unlock(); onChange?() }
    public func add(_ b: Bookmark) {
        lock.lock()
        if let i = bookmarks.firstIndex(where: { $0.name == b.name }) { bookmarks[i] = b } else { bookmarks.append(b) }
        lock.unlock(); onChange?()
    }
    public func remove(named name: String) { lock.lock(); bookmarks.removeAll { $0.name == name }; lock.unlock(); onChange?() }
    public func update(_ b: Bookmark, originalName: String) {
        lock.lock()
        if let i = bookmarks.firstIndex(where: { $0.name == originalName }) { bookmarks[i] = b } else { bookmarks.append(b) }
        lock.unlock(); onChange?()
    }
    public func move(from: Int, to: Int) {
        lock.lock()
        guard from >= 0, from < bookmarks.count, to >= 0, to < bookmarks.count else { lock.unlock(); return }
        let b = bookmarks.remove(at: from); bookmarks.insert(b, at: to)
        lock.unlock(); onChange?()
    }
}
