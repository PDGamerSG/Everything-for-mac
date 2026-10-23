import Foundation

/// RFC 4180-style CSV used by Everything for Filters.csv, Bookmarks.csv, EFU file lists, exports.
public struct CSVTable: Equatable {
    public var headers: [String]
    public var rows: [[String]]

    public init(headers: [String] = [], rows: [[String]] = []) {
        self.headers = headers
        self.rows = rows
    }

    public func column(_ name: String) -> Int? {
        // Everything semantics: if a column appears more than once, the last one wins.
        var found: Int? = nil
        for (i, h) in headers.enumerated() where h.caseInsensitiveCompare(name) == .orderedSame { found = i }
        return found
    }

    public func value(_ row: [String], _ name: String) -> String? {
        guard let i = column(name), i < row.count else { return nil }
        return row[i]
    }

    /// Parse CSV text. Handles quoted fields, doubled quotes, CRLF, embedded newlines, optional BOM.
    public static func parse(_ text: String, hasHeader: Bool = true) -> CSVTable {
        var records: [[String]] = []
        var field = ""
        var record: [String] = []
        var inQuotes = false
        var it = text.unicodeScalars.makeIterator()
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(text.unicodeScalars.count)
        while let s = it.next() { scalars.append(s) }
        var i = 0
        if scalars.first == "\u{FEFF}" { i = 1 }
        var pendingRecord = false
        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < scalars.count && scalars[i + 1] == "\"" {
                        field.unicodeScalars.append("\"")
                        i += 2
                        continue
                    }
                    inQuotes = false
                    i += 1
                    continue
                }
                field.unicodeScalars.append(c)
                i += 1
                continue
            }
            switch c {
            case "\"":
                inQuotes = true
                pendingRecord = true
            case ",":
                record.append(field)
                field = ""
                pendingRecord = true
            case "\r":
                break
            case "\n":
                record.append(field)
                field = ""
                records.append(record)
                record = []
                pendingRecord = false
            default:
                field.unicodeScalars.append(c)
                pendingRecord = true
            }
            i += 1
        }
        if pendingRecord || !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        if hasHeader {
            let headers = records.first ?? []
            return CSVTable(headers: headers, rows: Array(records.dropFirst()))
        }
        return CSVTable(headers: [], rows: records)
    }

    public static func escape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    public func render(includeHeader: Bool = true, lineEnding: String = "\n") -> String {
        var out = ""
        if includeHeader && !headers.isEmpty {
            out += headers.map(CSVTable.escape).joined(separator: ",") + lineEnding
        }
        for r in rows { out += r.map(CSVTable.escape).joined(separator: ",") + lineEnding }
        return out
    }

    public static func load(_ url: URL) -> CSVTable? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return parse(text)
    }

    public func write(to url: URL, bom: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        if bom { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        data.append(render().data(using: .utf8)!)
        try data.write(to: url, options: .atomic)
    }
}
