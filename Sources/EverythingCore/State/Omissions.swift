import Foundation

/// Result omissions: hide items without removing them from the index.
public struct Omission: Equatable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case path, filter, extensionName = "extension" }
    public var kind: Kind
    public var value: String
    public var omitFolders: Bool      // for filters: also hide matching folders (and their contents)

    public init(kind: Kind, value: String, omitFolders: Bool = true) { self.kind = kind; self.value = value; self.omitFolders = omitFolders }
}

/// Permanent (Omit Results.csv) or temporary omission list. Implements the engine hook.
public final class OmissionStore: OmissionProviding, @unchecked Sendable {
    public private(set) var omissions: [Omission] = []
    private var pathSet: Set<String> = []                // lowercased full paths
    private var extensions: Set<String> = []             // lowercased
    private var filters: [(WildcardPattern, Bool)] = []  // pattern, omitFolders
    private var generationCache: (UInt64, [ItemID: Bool])? = nil
    private let lock = NSLock()
    public var onChange: (() -> Void)?
    public let isTemporary: Bool

    public init(omissions: [Omission] = [], temporary: Bool = false) {
        self.isTemporary = temporary
        set(omissions)
    }

    public var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return omissions.isEmpty }

    public static let headers = ["Type", "Value", "Omit Folders"]

    public static func load(from url: URL = AppPaths.omitResultsFile) -> OmissionStore {
        guard let t = CSVTable.load(url) else { return OmissionStore() }
        var out: [Omission] = []
        for r in t.rows {
            if let path = t.value(r, "Path"), !path.isEmpty { out.append(Omission(kind: .path, value: path)); continue }
            if let f = t.value(r, "Filter"), !f.isEmpty { out.append(Omission(kind: .filter, value: f, omitFolders: INIFile.parseBool(t.value(r, "Omit Folders") ?? "1") ?? true)); continue }
            guard let type = t.value(r, "Type"), let kind = Omission.Kind(rawValue: type), let v = t.value(r, "Value"), !v.isEmpty else { continue }
            out.append(Omission(kind: kind, value: v, omitFolders: INIFile.parseBool(t.value(r, "Omit Folders") ?? "1") ?? true))
        }
        return OmissionStore(omissions: out)
    }

    public func save(to url: URL = AppPaths.omitResultsFile) throws {
        lock.lock()
        var t = CSVTable(headers: OmissionStore.headers)
        for o in omissions { t.rows.append([o.kind.rawValue, o.value, o.omitFolders ? "1" : "0"]) }
        lock.unlock()
        try t.write(to: url)
    }

    public func set(_ list: [Omission]) {
        lock.lock()
        omissions = list
        pathSet = Set(list.filter { $0.kind == .path }.map { Paths.normalize($0.value).lowercased() })
        extensions = Set(list.filter { $0.kind == .extensionName }.map { $0.value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        filters = list.filter { $0.kind == .filter }.map { (WildcardPattern(Paths.normalize($0.value).lowercased(), extended: false, starAll: true), $0.omitFolders) }
        generationCache = nil
        lock.unlock()
        onChange?()
    }

    public func add(_ o: Omission) { lock.lock(); var l = omissions; lock.unlock(); if !l.contains(o) { l.append(o) }; set(l) }
    public func remove(_ o: Omission) { lock.lock(); var l = omissions; lock.unlock(); l.removeAll { $0 == o }; set(l) }
    public func removeAll() { set([]) }

    public func omitPath(_ path: String) { add(Omission(kind: .path, value: Paths.normalize(path))) }
    public func omitExtension(_ ext: String) { add(Omission(kind: .extensionName, value: ext)) }

    // MARK: OmissionProviding

    public func omits(_ id: ItemID, ctx: EvalContext) -> Bool {
        lock.lock()
        let paths = pathSet, exts = extensions, fs = filters
        lock.unlock()
        if paths.isEmpty && exts.isEmpty && fs.isEmpty { return false }
        let s = ctx.store
        if !exts.isEmpty, exts.contains(s.extensions.lowerName(s.extensionID(id))) { return true }
        if paths.isEmpty && fs.isEmpty { return false }
        // walk up: an omitted folder hides everything below it
        var cur = id
        var first = true
        var scratch: [UInt8] = []
        while cur != invalidItem {
            ctx.paths.fullPathBytes(cur, store: s, folded: true, into: &scratch)
            let p = String(decoding: scratch, as: UTF8.self)
            if paths.contains(p) { return true }
            for (w, omitFolders) in fs where (first || omitFolders) && w.matches(p) {
                if first || s.isFolder(cur) { return true }
            }
            first = false
            cur = s.parent(cur)
        }
        return false
    }
}
