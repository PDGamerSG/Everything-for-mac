import Foundation

/// Options → Exclude: folder/file exclusion rules. Patterns are wildcard paths or names; a `regex:` prefix
/// switches a pattern to a regular expression.
public struct ExcludeRules: Sendable {
    public enum Pattern: Sendable {
        case exactPath(String)
        case wildcardPath(WildcardPattern)   // contains "/"
        case wildcardName(WildcardPattern)   // no "/": matched against the name
        case regex(NSRegularExpression)

        public init(_ raw: String) {
            let p = raw.trimmingCharacters(in: .whitespaces)
            if p.lowercased().hasPrefix("regex:"), let re = try? NSRegularExpression(pattern: String(p.dropFirst(6)), options: [.caseInsensitive]) {
                self = .regex(re)
            } else if p.contains("/") || p.contains("\\") {
                let norm = Paths.normalize(p)
                if norm.contains("*") || norm.contains("?") { self = .wildcardPath(WildcardPattern(norm, extended: false, starAll: true)) }
                else { self = .exactPath(norm) }
            } else {
                self = .wildcardName(WildcardPattern(p, extended: false))
            }
        }

        func matches(path: String, name: String) -> Bool {
            switch self {
            case .exactPath(let p): return path.caseInsensitiveCompare(p) == .orderedSame
            case .wildcardPath(let w): return w.matches(path)
            case .wildcardName(let w): return w.matches(name)
            case .regex(let re):
                let r = NSRange(path.startIndex..., in: path)
                return re.firstMatch(in: path, options: [], range: r) != nil
            }
        }
    }

    public var excludeHidden: Bool
    public var excludeSystem: Bool
    public var excludeFolders: [Pattern]
    public var excludeFiles: [Pattern]
    public var includeOnlyFiles: [Pattern]
    /// Prefix folders that restrict indexing (Options → Volumes → Include only). Empty = all.
    public var includeOnlyFolders: [String]

    public init(excludeHidden: Bool = false, excludeSystem: Bool = false, excludeFolders: [String] = [], excludeFiles: [String] = [],
                includeOnlyFiles: [String] = [], includeOnlyFolders: [String] = []) {
        self.excludeHidden = excludeHidden
        self.excludeSystem = excludeSystem
        self.excludeFolders = excludeFolders.filter { !$0.isEmpty }.map(Pattern.init)
        self.excludeFiles = excludeFiles.filter { !$0.isEmpty }.map(Pattern.init)
        self.includeOnlyFiles = includeOnlyFiles.filter { !$0.isEmpty }.map(Pattern.init)
        self.includeOnlyFolders = includeOnlyFolders.map(Paths.normalize)
    }

    public init(settings: Settings, includeOnlyFolders: [String] = []) {
        self.init(excludeHidden: settings.bool("exclude_hidden"), excludeSystem: settings.bool("exclude_system"),
                  excludeFolders: settings.list("exclude_folders"), excludeFiles: settings.list("exclude_files"),
                  includeOnlyFiles: settings.list("include_only_files"), includeOnlyFolders: includeOnlyFolders)
    }

    public static let none = ExcludeRules()

    /// Whether a folder may be indexed (and descended into).
    public func allowsFolder(path: String, name: String, isHidden: Bool, isSystem: Bool) -> Bool {
        if excludeHidden && isHidden { return false }
        if excludeSystem && isSystem { return false }
        if hasExcludedFolderAncestor(path) { return false }
        for p in excludeFolders where p.matches(path: path, name: name) { return false }
        if !includeOnlyFolders.isEmpty {
            // allowed if path is inside an include-only folder, or is an ancestor of one (so we can reach it)
            let ok = includeOnlyFolders.contains { inc in
                path == inc || path.hasPrefix(inc + "/") || inc.hasPrefix(path == "/" ? "/" : path + "/")
            }
            if !ok { return false }
        }
        return true
    }

    public func allowsFile(path: String, name: String, isHidden: Bool, isSystem: Bool) -> Bool {
        if excludeHidden && isHidden { return false }
        if excludeSystem && isSystem { return false }
        if hasExcludedFolderAncestor(path) { return false }
        if !includeOnlyFolders.isEmpty && !includeOnlyFolders.contains(where: { path.hasPrefix($0 + "/") }) { return false }
        for p in excludeFiles where p.matches(path: path, name: name) { return false }
        if !includeOnlyFiles.isEmpty && !includeOnlyFiles.contains(where: { $0.matches(path: path, name: name) }) { return false }
        return true
    }

    private func hasExcludedFolderAncestor(_ path: String) -> Bool {
        var ancestor = Paths.parent(Paths.normalize(path))
        while !ancestor.isEmpty {
            let ancestorName = Paths.lastComponent(ancestor)
            if excludeFolders.contains(where: { $0.matches(path: ancestor, name: ancestorName) }) { return true }
            if ancestor == "/" { break }
            ancestor = Paths.parent(ancestor)
        }
        return false
    }
}
