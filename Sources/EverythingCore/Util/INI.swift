import Foundation

/// Minimal INI reader/writer compatible with Everything.ini layout:
/// `[Everything]` section header, `key=value` lines, `;` comments. Unknown keys are preserved.
public struct INIFile: Equatable {
    public struct Entry: Equatable {
        public var key: String
        public var value: String
    }

    /// Ordered entries (first section only is semantically used; others preserved as raw lines).
    public private(set) var entries: [Entry] = []
    public var sectionName: String = "Everything"
    private var lookup: [String: Int] = [:]

    public init() {}

    public init(parsing text: String) {
        self.init()
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(";") || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                sectionName = String(trimmed.dropFirst().dropLast())
                continue
            }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...])
            set(key, value)
        }
    }

    public subscript(key: String) -> String? {
        get { lookup[key].map { entries[$0].value } }
        set {
            if let v = newValue { set(key, v) } else { remove(key) }
        }
    }

    public mutating func set(_ key: String, _ value: String) {
        if let i = lookup[key] {
            entries[i].value = value
        } else {
            lookup[key] = entries.count
            entries.append(Entry(key: key, value: value))
        }
    }

    public mutating func remove(_ key: String) {
        guard let i = lookup[key] else { return }
        entries.remove(at: i)
        lookup = [:]
        for (n, e) in entries.enumerated() { lookup[e.key] = n }
    }

    public func has(_ key: String) -> Bool { lookup[key] != nil }

    public func bool(_ key: String, default def: Bool) -> Bool {
        guard let v = self[key] else { return def }
        return INIFile.parseBool(v) ?? def
    }

    public func int(_ key: String, default def: Int) -> Int {
        guard let v = self[key], let i = Int(v.trimmingCharacters(in: .whitespaces)) else { return def }
        return i
    }

    public func double(_ key: String, default def: Double) -> Double {
        guard let v = self[key], let d = Double(v.trimmingCharacters(in: .whitespaces)) else { return def }
        return d
    }

    public func string(_ key: String, default def: String) -> String {
        self[key] ?? def
    }

    public mutating func set(_ key: String, bool: Bool) { set(key, bool ? "1" : "0") }
    public mutating func set(_ key: String, int: Int) { set(key, String(int)) }

    public static func parseBool(_ v: String) -> Bool? {
        switch v.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    public func render() -> String {
        var out = "[\(sectionName)]\n"
        for e in entries { out += "\(e.key)=\(e.value)\n" }
        return out
    }

    public static func load(_ url: URL) -> INIFile? {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        return INIFile(parsing: text)
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try render().data(using: .utf8)!.write(to: url, options: .atomic)
    }

    /// Merge: keys in `other` override.
    public mutating func merge(_ other: INIFile) {
        for e in other.entries { set(e.key, e.value) }
    }
}
