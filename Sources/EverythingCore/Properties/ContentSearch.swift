import Foundation

/// Slow, from-disk content matching for `content:`, `utf8-content:`, `binary:`, `hex:`, `first-bytes:`, `last-bytes:`.
public enum ContentSearch {
    public enum Encoding: Equatable, Sendable { case auto, ansi, utf8, utf16le, utf16be, ascii, binary }

    /// Reads up to `limit` bytes of the file.
    public static func read(path: String, limit: Int) -> Data? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        return try? fh.read(upToCount: limit > 0 ? limit : Int.max)
    }

    /// Decodes file bytes to text honoring BOM / requested encoding.
    public static func decode(_ data: Data, encoding: Encoding) -> String {
        var d = data
        switch encoding {
        case .utf16le: return String(data: d, encoding: .utf16LittleEndian) ?? ""
        case .utf16be: return String(data: d, encoding: .utf16BigEndian) ?? ""
        case .ansi: return String(data: d, encoding: .windowsCP1252) ?? String(decoding: d, as: UTF8.self)
        case .ascii: return String(data: d, encoding: .ascii) ?? String(decoding: d, as: UTF8.self)
        case .utf8: return String(decoding: d, as: UTF8.self)
        case .binary: return String(decoding: d, as: UTF8.self)
        case .auto:
            if d.count >= 3, d[d.startIndex] == 0xEF, d[d.startIndex + 1] == 0xBB, d[d.startIndex + 2] == 0xBF { d = d.dropFirst(3); return String(decoding: d, as: UTF8.self) }
            if d.count >= 2, d[d.startIndex] == 0xFF, d[d.startIndex + 1] == 0xFE { return String(data: d.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
            if d.count >= 2, d[d.startIndex] == 0xFE, d[d.startIndex + 1] == 0xFF { return String(data: d.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
            if let s = String(data: d, encoding: .utf8) { return s }
            // heuristic UTF-16LE without BOM: many zero bytes at odd positions
            if d.count >= 4 { var zeros = 0; var i = d.startIndex + 1; while i < d.endIndex && i < d.startIndex + 200 { if d[i] == 0 { zeros += 1 }; i += 2 }
                if zeros > 40, let s = String(data: d, encoding: .utf16LittleEndian) { return s } }
            return String(data: d, encoding: .windowsCP1252) ?? String(decoding: d, as: UTF8.self)
        }
    }

    public static func detectEncoding(_ data: Data) -> String {
        if data.count >= 3, data[data.startIndex] == 0xEF, data[data.startIndex + 1] == 0xBB, data[data.startIndex + 2] == 0xBF { return "UTF-8" }
        if data.count >= 2, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xFE { return "UTF-16 (LE)" }
        if data.count >= 2, data[data.startIndex] == 0xFE, data[data.startIndex + 1] == 0xFF { return "UTF-16 (BE)" }
        if data.contains(0) { return "Binary" }
        if data.allSatisfy({ $0 < 0x80 }) { return "ASCII" }
        if String(data: data, encoding: .utf8) != nil { return "UTF-8" }
        return "ANSI"
    }

    /// Text content match. `eachLine` restricts matches to single lines.
    public static func matches(path: String, matcher: TextMatcher, encoding: Encoding, limit: Int, eachLine: Bool) -> Bool {
        guard let data = read(path: path, limit: limit) else { return false }
        if encoding == .binary {
            // raw byte substring (pattern bytes as UTF-8, with \xNN escapes decoded)
            let needle = decodeByteEscapes(matcher.pattern)
            return data.withUnsafeBytes { hay in
                needle.withUnsafeBufferPointer { n in
                    n.count == 0 || (hay.count >= n.count && memmem(hay.baseAddress, hay.count, n.baseAddress, n.count) != nil)
                }
            }
        }
        let text = decode(data, encoding: encoding)
        if eachLine {
            for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) where matcher.matches(String(line)) { return true }
            return false
        }
        return matcher.matches(text)
    }

    /// Hex content match: pattern is hex digits (spaces allowed).
    public static func matchesHex(path: String, hexPattern: String, limit: Int) -> Bool {
        let clean = hexPattern.filter { $0.isHexDigit }
        guard clean.count % 2 == 0, !clean.isEmpty else { return false }
        var bytes: [UInt8] = []
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let b = UInt8(clean[idx..<next], radix: 16) else { return false }
            bytes.append(b); idx = next
        }
        guard let data = read(path: path, limit: limit) else { return false }
        return data.withUnsafeBytes { hay in bytes.withUnsafeBufferPointer { n in hay.count >= n.count && memmem(hay.baseAddress, hay.count, n.baseAddress, n.count) != nil } }
    }

    public static func firstBytes(path: String, count: Int) -> Data? { read(path: path, limit: max(1, count)) }

    public static func lastBytes(path: String, count: Int) -> Data? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd() else { return nil }
        let start = size > UInt64(count) ? size - UInt64(count) : 0
        try? fh.seek(toOffset: start)
        return try? fh.readToEnd()
    }

    /// Decodes `\xNN` escapes into bytes; other characters are UTF-8 encoded.
    public static func decodeByteEscapes(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 3 < chars.count, chars[i + 1] == "x", let b = UInt8(String(chars[(i + 2)...(i + 3)]), radix: 16) {
                out.append(b); i += 4; continue
            }
            out.append(contentsOf: Array(String(chars[i]).utf8)); i += 1
        }
        return out
    }

    /// Line / word counts for `line-count:` / `word-count:`.
    public static func counts(path: String, limit: Int) -> (lines: Int, words: Int)? {
        guard let data = read(path: path, limit: limit) else { return nil }
        let text = decode(data, encoding: .auto)
        var lines = 0, words = 0
        var inWord = false
        for c in text {
            if c == "\n" || c == "\r\n" { lines += 1 }
            if c.isWhitespace { if inWord { words += 1; inWord = false } } else { inWord = true }
        }
        if inWord { words += 1 }
        if !text.isEmpty && !(text.last == "\n" || text.last == "\r\n") { lines += 1 }
        return (lines, words)
    }
}
