import Foundation

/// Undo system for file operations performed from Everything (rename, move, copy, trash).
public struct UndoEntry: Equatable, Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case rename, move, copy, trash, create }
    public var id: UUID
    public var kind: Kind
    public var date: Int64
    public var from: [String]        // original full paths
    public var to: [String]          // resulting full paths (trash locations for .trash)
    public var undone: Bool

    public init(kind: Kind, from: [String], to: [String], date: Int64 = Timestamps.now()) {
        id = UUID(); self.kind = kind; self.date = date; self.from = from; self.to = to; undone = false
    }

    public var title: String {
        let n = from.count
        let what = n == 1 ? Paths.lastComponent(from[0]) : "\(n) items"
        switch kind {
        case .rename: return "Rename \(what)"
        case .move: return "Move \(what)"
        case .copy: return "Copy \(what)"
        case .trash: return "Move \(what) to Trash"
        case .create: return "Create \(what)"
        }
    }
}

public final class UndoLog: @unchecked Sendable {
    public private(set) var entries: [UndoEntry] = []
    private let lock = NSLock()
    public var maxEntries = 500
    public var onChange: (() -> Void)?

    public init() {}

    public static func load(from url: URL = AppPaths.undoLogFile) -> UndoLog {
        let l = UndoLog()
        if let d = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([UndoEntry].self, from: d) { l.entries = e }
        return l
    }

    public func save(to url: URL = AppPaths.undoLogFile) throws {
        lock.lock(); let e = entries; lock.unlock()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(e).write(to: url, options: .atomic)
    }

    public func record(_ e: UndoEntry) {
        lock.lock()
        entries.append(e)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        lock.unlock()
        onChange?()
    }

    public var undoable: [UndoEntry] { lock.lock(); defer { lock.unlock() }; return entries.filter { !$0.undone } }
    public var last: UndoEntry? { undoable.last }
    public func clear() { lock.lock(); entries.removeAll(); lock.unlock(); onChange?() }

    // MARK: file operations (recorded)

    @discardableResult
    public func rename(_ path: String, to newName: String) throws -> String {
        let dest = Paths.join(Paths.parent(path), newName)
        try FileManager.default.moveItem(atPath: path, toPath: dest)
        record(UndoEntry(kind: .rename, from: [path], to: [dest]))
        return dest
    }

    @discardableResult
    public func move(_ paths: [String], to folder: String) throws -> [String] {
        var dests: [String] = []
        for p in paths {
            let d = Paths.join(folder, Paths.lastComponent(p))
            try FileManager.default.moveItem(atPath: p, toPath: d)
            dests.append(d)
        }
        record(UndoEntry(kind: .move, from: paths, to: dests))
        return dests
    }

    @discardableResult
    public func copy(_ paths: [String], to folder: String) throws -> [String] {
        var dests: [String] = []
        for p in paths {
            var d = Paths.join(folder, Paths.lastComponent(p))
            if FileManager.default.fileExists(atPath: d) { d = UndoLog.uniqueCopyName(d) }
            try FileManager.default.copyItem(atPath: p, toPath: d)
            dests.append(d)
        }
        record(UndoEntry(kind: .copy, from: paths, to: dests))
        return dests
    }

    @discardableResult
    public func trash(_ paths: [String]) throws -> [String] {
        var dests: [String] = []
        for p in paths {
            var result: NSURL? = nil
            try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: &result)
            dests.append(result?.path ?? "")
        }
        record(UndoEntry(kind: .trash, from: paths, to: dests))
        return dests
    }

    public func deletePermanently(_ paths: [String]) throws {
        for p in paths { try FileManager.default.removeItem(atPath: p) }
    }

    /// Reverses an operation. Copies are deleted; trashed items are restored.
    public func undo(_ entry: UndoEntry) throws {
        let fm = FileManager.default
        switch entry.kind {
        case .rename, .move:
            for (from, to) in zip(entry.from, entry.to).reversed() where fm.fileExists(atPath: to) { try fm.moveItem(atPath: to, toPath: from) }
        case .copy, .create:
            for to in entry.to where fm.fileExists(atPath: to) { try fm.removeItem(atPath: to) }
        case .trash:
            for (from, to) in zip(entry.from, entry.to) where !to.isEmpty && fm.fileExists(atPath: to) {
                try fm.createDirectory(atPath: Paths.parent(from), withIntermediateDirectories: true)
                try fm.moveItem(atPath: to, toPath: from)
            }
        }
        lock.lock()
        if let i = entries.firstIndex(where: { $0.id == entry.id }) { entries[i].undone = true }
        lock.unlock()
        onChange?()
    }

    public func undoLast() throws { if let e = last { try undo(e) } }

    static func uniqueCopyName(_ path: String) -> String {
        let dir = Paths.parent(path), name = Paths.lastComponent(path)
        let ext = ItemStore.extensionOf(name)
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var n = 2
        var candidate = Paths.join(dir, "\(stem) copy" + (ext.isEmpty ? "" : ".\(ext)"))
        while FileManager.default.fileExists(atPath: candidate) { candidate = Paths.join(dir, "\(stem) copy \(n)" + (ext.isEmpty ? "" : ".\(ext)")); n += 1 }
        return candidate
    }
}

/// Advanced Rename: computes new names for a batch of items.
public enum AdvancedRename {
    public struct Options: Equatable, Sendable {
        public enum Mode: Equatable, Sendable { case findReplace, changeExtension, regex, editAll, numbering }
        public var mode: Mode = .findReplace
        public var find = ""
        public var replace = ""
        public var matchCase = false
        public var newExtension = ""
        public var pattern = ""              // regex
        public var template = ""             // replacement template ($1) or editAll text (one name per line) or numbering template with #
        public var numberStart = 1
        public var numberStep = 1
        public var applyToExtension = false
        public init() {}
    }

    /// Returns (oldName → newName) for each input name; unchanged names map to themselves.
    public static func apply(_ names: [String], options o: Options) -> [String] {
        switch o.mode {
        case .findReplace:
            return names.map { name in
                let (stem, ext) = split(name)
                let target = o.applyToExtension ? name : stem
                let replaced = target.replacingOccurrences(of: o.find, with: o.replace, options: o.matchCase ? [] : [.caseInsensitive])
                return o.applyToExtension || ext.isEmpty ? replaced : replaced + "." + ext
            }
        case .changeExtension:
            return names.map { name in
                let (stem, _) = split(name)
                let e = o.newExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                return e.isEmpty ? stem : stem + "." + e
            }
        case .regex:
            guard let re = try? NSRegularExpression(pattern: o.pattern, options: o.matchCase ? [] : [.caseInsensitive]) else { return names }
            return names.map { name in
                let (stem, ext) = split(name)
                let target = o.applyToExtension ? name : stem
                let out = re.stringByReplacingMatches(in: target, options: [], range: NSRange(target.startIndex..., in: target), withTemplate: o.template)
                return o.applyToExtension || ext.isEmpty ? out : out + "." + ext
            }
        case .editAll:
            let lines = o.template.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map(String.init)
            return names.enumerated().map { i, n in i < lines.count && !lines[i].isEmpty ? lines[i] : n }
        case .numbering:
            var n = o.numberStart
            return names.map { name in
                let (stem, ext) = split(name)
                let digits = o.template.filter { $0 == "#" }.count
                let num = digits > 0 ? String(format: "%0\(digits)d", n) : String(n)
                var out = o.template.isEmpty ? stem + " " + num : o.template
                if out.contains("#") { out = out.replacingOccurrences(of: String(repeating: "#", count: max(1, digits)), with: num) }
                out = out.replacingOccurrences(of: "$name", with: stem)
                n += o.numberStep
                return ext.isEmpty ? out : out + "." + ext
            }
        }
    }

    static func split(_ name: String) -> (String, String) {
        let ext = ItemStore.extensionOf(name)
        return ext.isEmpty ? (name, "") : (String(name.dropLast(ext.count + 1)), ext)
    }
}
