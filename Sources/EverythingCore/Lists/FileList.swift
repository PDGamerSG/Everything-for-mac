import Foundation

/// One row of an Everything file list (EFU).
public struct FileListEntry: Equatable, Sendable {
    public var path: String          // full path (POSIX; Windows paths converted on read)
    public var isFolder: Bool
    public var size: UInt64
    public var dateModified: Int64
    public var dateCreated: Int64
    public var attributes: UInt32    // Windows attribute bits

    public init(path: String, isFolder: Bool, size: UInt64 = 0, dateModified: Int64 = 0, dateCreated: Int64 = 0, attributes: UInt32 = 0) {
        self.path = path; self.isFolder = isFolder; self.size = size; self.dateModified = dateModified; self.dateCreated = dateCreated
        self.attributes = attributes == 0 ? (isFolder ? 0x10 : 0x80) : attributes
    }

    public var name: String { Paths.lastComponent(path) }
    public var flags: ItemFlags { var f = ItemFlags.fromWindowsAttributes(attributes); if isFolder { f.insert(.folder) }; return f }
}

/// EFU file list: CSV with a required `Filename` column; `Size`, `Date Modified`, `Date Created`, `Attributes` optional.
/// Also reads plain text lists (one path per line) and generic CSV with a Filename/Path column.
public struct FileList: Equatable, Sendable {
    public var entries: [FileListEntry]
    public var sourceURL: URL?

    public init(entries: [FileListEntry] = [], sourceURL: URL? = nil) { self.entries = entries; self.sourceURL = sourceURL }

    public static let efuHeader = ["Filename", "Size", "Date Modified", "Date Created", "Attributes"]

    // MARK: reading

    public static func read(_ url: URL) throws -> FileList {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let ext = url.pathExtension.lowercased()
        var list: FileList
        if ext == "efu" || ext == "csv" || text.lowercased().hasPrefix("filename") || text.lowercased().hasPrefix("\u{FEFF}filename") {
            list = parseEFU(text, baseDirectory: url.deletingLastPathComponent().path)
        } else {
            list = parseText(text, baseDirectory: url.deletingLastPathComponent().path)
        }
        list.sourceURL = url
        return list
    }

    public static func parseEFU(_ text: String, baseDirectory: String = "") -> FileList {
        let table = CSVTable.parse(text)
        guard table.column("Filename") != nil || table.column("Path") != nil || table.column("Full Path") != nil else { return parseText(text, baseDirectory: baseDirectory) }
        var byPath: [String: Int] = [:]
        var entries: [FileListEntry] = []
        for row in table.rows {
            guard var raw = table.value(row, "Filename") ?? table.value(row, "Full Path") ?? table.value(row, "Path"), !raw.isEmpty else { continue }
            var isFolder = raw.hasSuffix("/") || raw.hasSuffix("\\")
            if raw.hasPrefix("file://"), let u = URL(string: raw) { raw = u.path }
            var path = Paths.fromWindows(raw)
            if path.hasSuffix("/") && path.count > 1 { path.removeLast() }
            if !path.hasPrefix("/") {
                if path.hasPrefix("\\") { path = String(path.dropFirst()) }
                path = Paths.normalize(Paths.join(baseDirectory, path))
                path = (path as NSString).standardizingPath
            }
            let size = UInt64(table.value(row, "Size") ?? "") ?? 0
            let dm = parseDate(table.value(row, "Date Modified") ?? "")
            let dc = parseDate(table.value(row, "Date Created") ?? "")
            let attrs = parseAttributes(table.value(row, "Attributes") ?? "")
            if attrs & 0x10 != 0 { isFolder = true }
            let e = FileListEntry(path: path, isFolder: isFolder, size: size, dateModified: dm, dateCreated: dc, attributes: attrs == 0 ? (isFolder ? 0x10 : 0x80) : attrs)
            if let i = byPath[path.lowercased()] { entries[i] = e } else { byPath[path.lowercased()] = entries.count; entries.append(e) }
        }
        return FileList(entries: entries)
    }

    public static func parseText(_ text: String, baseDirectory: String = "") -> FileList {
        var entries: [FileListEntry] = []
        var seen = Set<String>()
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            var raw = String(line).trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\u{FEFF}") { raw.removeFirst() }
            if raw.isEmpty { continue }
            if raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 { raw = String(raw.dropFirst().dropLast()) }
            let isFolder = raw.hasSuffix("/") || raw.hasSuffix("\\")
            var path = Paths.fromWindows(raw)
            if path.hasSuffix("/") && path.count > 1 { path.removeLast() }
            if !path.hasPrefix("/") { path = (Paths.join(baseDirectory, path) as NSString).standardizingPath }
            let key = path.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            var folder = isFolder
            if !folder, let e = DirectoryLister.entry(atPath: path) { folder = e.kind == .directory }
            entries.append(FileListEntry(path: path, isFolder: folder))
        }
        return FileList(entries: entries)
    }

    static func parseDate(_ s: String) -> Int64 {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return 0 }
        if let ft = UInt64(t) { return ft > 10_000_000_000 ? Timestamps.fromFiletime(ft) : Int64(ft) * 1_000_000_000 }
        return DateFormat.parse(t) ?? 0
    }

    static func parseAttributes(_ s: String) -> UInt32 {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("0x") { return UInt32(t.dropFirst(2), radix: 16) ?? 0 }
        return UInt32(t) ?? 0
    }

    // MARK: writing

    public func renderEFU(windowsPaths: Bool = false) -> String {
        var t = CSVTable(headers: FileList.efuHeader)
        for e in entries {
            let p = windowsPaths ? Paths.toWindows(e.path) : e.path
            t.rows.append([p, e.isFolder ? "" : String(e.size), e.dateModified == 0 ? "" : String(Timestamps.toFiletime(e.dateModified)),
                           e.dateCreated == 0 ? "" : String(Timestamps.toFiletime(e.dateCreated)), String(e.attributes)])
        }
        return t.render(lineEnding: "\r\n")
    }

    public func write(to url: URL, windowsPaths: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try renderEFU(windowsPaths: windowsPaths).data(using: .utf8)!.write(to: url, options: .atomic)
    }

    // MARK: building

    /// Creates a file list by scanning folders on disk (`-create-file-list`).
    public static func create(from paths: [String], includeSubfolders: Bool = true, includeFolders: Bool = true, includeFiles: Bool = true, rules: ExcludeRules = .none) -> FileList {
        var out: [FileListEntry] = []
        for p in paths {
            let norm = Paths.normalize(p)
            guard let e = DirectoryLister.entry(atPath: norm) else { continue }
            if e.kind == .directory {
                if includeFolders { out.append(FileListEntry(path: norm, isFolder: true, dateModified: e.dateModified, dateCreated: e.dateCreated, attributes: e.itemFlags().windowsAttributes)) }
                var stack = [norm]
                while let dir = stack.popLast() {
                    guard let entries = try? DirectoryLister.list(dir) else { continue }
                    for c in entries {
                        let cp = Paths.join(dir, c.name)
                        if c.kind == .directory {
                            guard rules.allowsFolder(path: cp, name: c.name, isHidden: c.isHidden, isSystem: c.isSystemProtected) else { continue }
                            if includeFolders { out.append(FileListEntry(path: cp, isFolder: true, dateModified: c.dateModified, dateCreated: c.dateCreated, attributes: c.itemFlags().windowsAttributes)) }
                            if includeSubfolders { stack.append(cp) }
                        } else {
                            guard includeFiles, rules.allowsFile(path: cp, name: c.name, isHidden: c.isHidden, isSystem: c.isSystemProtected) else { continue }
                            out.append(FileListEntry(path: cp, isFolder: false, size: c.size, dateModified: c.dateModified, dateCreated: c.dateCreated, attributes: c.itemFlags().windowsAttributes))
                        }
                    }
                }
            } else if includeFiles {
                out.append(FileListEntry(path: norm, isFolder: false, size: e.size, dateModified: e.dateModified, dateCreated: e.dateCreated, attributes: e.itemFlags().windowsAttributes))
            }
        }
        return FileList(entries: out)
    }

    /// Re-reads metadata from disk for entries that still exist; removes those that do not (File List Editor → Update).
    public mutating func update(rescanFolders: Bool = true) {
        var out: [FileListEntry] = []
        var seen = Set<String>()
        for e in entries {
            guard let d = DirectoryLister.entry(atPath: e.path) else { continue }
            let fresh = FileListEntry(path: e.path, isFolder: d.kind == .directory, size: d.size, dateModified: d.dateModified, dateCreated: d.dateCreated, attributes: d.itemFlags().windowsAttributes)
            if seen.insert(e.path.lowercased()).inserted { out.append(fresh) }
            if rescanFolders && d.kind == .directory {
                for c in FileList.create(from: [e.path], includeSubfolders: true).entries where seen.insert(c.path.lowercased()).inserted { out.append(c) }
            }
        }
        entries = out
    }

    public mutating func removeDuplicates() {
        var seen = Set<String>()
        entries = entries.filter { seen.insert($0.path.lowercased()).inserted }
    }

    public mutating func merge(_ other: FileList) {
        var seen = Set(entries.map { $0.path.lowercased() })
        for e in other.entries where seen.insert(e.path.lowercased()).inserted { entries.append(e) }
    }

    // MARK: index integration

    /// Loads the list into the index as a file-list root. Parent folders that are not in the list are created implicitly.
    @discardableResult
    public func load(into index: Index, label: String) -> Root {
        index.write {
            // The root item is named "" so that items keep their absolute full paths ("" + "/" + components).
            let root = index.addRoot(kind: .fileList, path: sourceURL?.path ?? label, label: label, monitor: true, itemName: "")
            let s = index.store
            for c in s.children(of: root.item) { s.remove(c) }
            // group by top-level: each entry path becomes a chain of folders under the root item
            for e in entries {
                let parentPath = Paths.parent(e.path)
                let parent = ensureChain(parentPath, under: root.item, index: index)
                let name = e.name
                if let existing = s.child(of: parent, named: name) {
                    s.update(existing, size: e.size, dateModified: e.dateModified, dateCreated: e.dateCreated, flags: e.flags.union(.fileList))
                } else {
                    s.add(ItemRecord(name: name, parent: parent, flags: e.flags.union(.fileList), size: e.size, dateModified: e.dateModified, dateCreated: e.dateCreated))
                }
            }
            return root
        }
    }

    private func ensureChain(_ path: String, under root: ItemID, index: Index) -> ItemID {
        let s = index.store
        var cur = root
        let comps = path.split(separator: "/").map(String.init)
        for c in comps {
            if let child = s.child(of: cur, named: c) { cur = child }
            else { cur = s.add(ItemRecord(name: c, parent: cur, flags: [.folder, .fileList])) }
        }
        return cur
    }
}
