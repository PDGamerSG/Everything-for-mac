import Foundation
import EverythingCore
import EverythingIPC

public enum ESOutput {
    public static func render(items: [IPCItem], totalResults: Int, format: ExportFormat,
                              columns: [String], includeHeader: Bool) -> String {
        let columns = columns.map(QueryParser.canonical)
        func title(_ column: String) -> String { Exporter.columnTitle(column) }
        func value(_ column: String, _ item: IPCItem) -> String {
            switch column {
            case "name": return item.name
            case "path", "location": return item.path
            case "fullpath": return item.fullPath
            case "size": return item.size.map(String.init) ?? ""
            case "extension", "ext": return item.extensionName ?? ""
            case "attributes", "attr", "attrib": return item.attributes ?? ""
            case "runcount": return item.runCount.map(String.init) ?? "0"
            case "daterun": return item.dateRun.map(String.init) ?? "0"
            case "datemodified", "dm": return item.dateModified.map(String.init) ?? ""
            case "datecreated", "dc": return item.dateCreated.map(String.init) ?? ""
            case "dateaccessed", "da": return item.dateAccessed.map(String.init) ?? ""
            default: return item.properties?[column] ?? ""
            }
        }
        func csv(_ v: String) -> String {
            if v.contains(",") || v.contains("\"") || v.contains("\r") || v.contains("\n") {
                return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return v
        }
        switch format {
        case .csv, .tsv:
            let separator = format == .csv ? "," : "\t"
            func cell(_ v: String) -> String { format == .csv ? csv(v) : v.replacingOccurrences(of: "\t", with: " ") }
            var lines: [String] = []
            if includeHeader { lines.append(columns.map(title).map(cell).joined(separator: separator)) }
            lines.append(contentsOf: items.map { item in columns.map { c in cell(value(c, item)) }.joined(separator: separator) })
            return lines.joined(separator: "\r\n") + (lines.isEmpty ? "" : "\r\n")
        case .txt:
            return items.map { item in columns.map { c in value(c, item) }.joined(separator: "\t") }.joined(separator: "\r\n") + (items.isEmpty ? "" : "\r\n")
        case .efu:
            var lines = includeHeader ? [FileList.efuHeader.joined(separator: ",")] : []
            lines.append(contentsOf: items.map { item in
                let size = item.size.map { String($0) } ?? ""
                let modified = item.dateModified.map { String($0) } ?? ""
                let created = item.dateCreated.map { String($0) } ?? ""
                let attributes = item.attributesValue.map { String($0) } ?? ""
                let vals = [item.fullPath, size, modified, created, attributes]
                return vals.map(csv).joined(separator: ",")
            })
            return lines.joined(separator: "\r\n") + (lines.isEmpty ? "" : "\r\n")
        case .json:
            let results: [[String: Any]] = items.map { item in
                var row: [String: Any] = ["type": item.type]
                for c in columns { row[Exporter.jsonKey(c)] = value(c, item) }
                return row
            }
            let object: [String: Any] = ["totalResults": totalResults, "results": results]
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return "{\"totalResults\":0,\"results\":[]}\n" }
            return String(decoding: data, as: UTF8.self) + "\n"
        case .m3u, .m3u8:
            var out = "#EXTM3U\r\n"
            for item in items { out += "#EXTINF:-1,\(item.name)\r\n\(item.fullPath)\r\n" }
            return out
        }
    }
}
