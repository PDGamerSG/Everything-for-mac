import Foundation

public enum ExportFormat: String, CaseIterable, Sendable {
    case csv, tsv, txt, efu, json, m3u, m3u8

    public var fileExtension: String { rawValue }
    public var displayName: String {
        switch self {
        case .csv: return "CSV (Comma Delimited)"
        case .tsv: return "TSV (Tab Delimited)"
        case .txt: return "Text File"
        case .efu: return "EFU File List"
        case .json: return "JSON"
        case .m3u: return "M3U Playlist"
        case .m3u8: return "M3U8 Playlist"
        }
    }
}

/// Renders search results in the export / `es` output formats.
public struct Exporter {
    public var format: ExportFormat
    public var columns: [String]                 // canonical property ids
    public var includeHeader = true
    public var folderAppendSeparator = true      // trailing "/" on folder paths in txt/m3u
    public var doubleQuote = false
    public var sizeFormat: SizeFormatMode = .bytes
    public var sizeStandard: SizeStandard = .jedec
    public var dateFormat: DateFormat.Style = .iso8601
    public var digitGrouping = false
    public var utf8BOM = false

    public init(format: ExportFormat, columns: [String] = ["full-path"]) {
        self.format = format
        self.columns = columns.map(QueryParser.canonical)
    }

    public static func columnTitle(_ canonical: String) -> String {
        PropertyCatalog.byCanonical[canonical]?.title ?? canonical.capitalized
    }

    public func cell(_ canonical: String, id: ItemID, ctx: EvalContext) -> String {
        let s = ctx.store
        switch canonical {
        case "name": return s.name(id)
        case "path": return ctx.parentPath(id)
        case "fullpath":
            let p = ctx.fullPath(id)
            return folderAppendSeparator && s.isFolder(id) && format != .csv && format != .tsv && format != .efu && format != .json && p != "/" ? p + "/" : p
        case "size":
            if s.isFolder(id) && !s.trackFolderSize { return "" }
            return format == .efu || format == .json ? String(s.size(id)) : SizeFormat.format(s.size(id), standard: sizeStandard, mode: sizeFormat, digitGrouping: digitGrouping)
        case "datemodified", "datecreated", "dateaccessed", "datechanged", "daterun", "daterecentlychanged":
            let ns = PropertyAccess.value(canonical, id: id, ctx: ctx)?.asDate ?? 0
            if format == .efu { return ns == 0 ? "" : String(Timestamps.toFiletime(ns)) }
            return DateFormat.format(ns, style: dateFormat)
        case "attributes": return format == .efu ? String(s.flags(id).windowsAttributes) : s.flags(id).letters
        case "extension": return s.extensionName(id)
        default: return PropertyAccess.text(canonical, id: id, ctx: ctx)
        }
    }

    /// Renders the whole document.
    public func render(_ ids: [ItemID], ctx: EvalContext) -> String {
        var out = ""
        if utf8BOM { out.append("\u{FEFF}") }
        let s = ctx.store
        switch format {
        case .csv, .tsv:
            let sep = format == .csv ? "," : "\t"
            func esc(_ v: String) -> String { format == .csv ? CSVTable.escape(v) : v.replacingOccurrences(of: "\t", with: " ") }
            if includeHeader { out += columns.map { esc(Exporter.columnTitle($0)) }.joined(separator: sep) + "\r\n" }
            for id in ids { out += columns.map { esc(cell($0, id: id, ctx: ctx)) }.joined(separator: sep) + "\r\n" }
        case .txt:
            for id in ids {
                let line = columns.map { cell($0, id: id, ctx: ctx) }.joined(separator: "\t")
                out += (doubleQuote ? "\"" + line + "\"" : line) + "\r\n"
            }
        case .efu:
            let efuColumns = ["fullpath", "size", "datemodified", "datecreated", "attributes"]
            if includeHeader { out += FileList.efuHeader.joined(separator: ",") + "\r\n" }
            for id in ids { out += efuColumns.map { CSVTable.escape(cell($0, id: id, ctx: ctx)) }.joined(separator: ",") + "\r\n" }
        case .json:
            var items: [[String: Any]] = []
            for id in ids {
                var o: [String: Any] = ["type": s.isFolder(id) ? "folder" : "file"]
                for c in columns {
                    let key = Exporter.jsonKey(c)
                    switch c {
                    case "size": o[key] = s.isFolder(id) && !s.trackFolderSize ? NSNull() : NSNumber(value: s.size(id))
                    case "datemodified", "datecreated", "dateaccessed", "datechanged", "daterun", "daterecentlychanged":
                        let ns = PropertyAccess.value(c, id: id, ctx: ctx)?.asDate ?? 0
                        o[key] = ns == 0 ? NSNull() : DateFormat.iso(ns)
                        o[key + "_filetime"] = String(Timestamps.toFiletime(ns))
                    default: o[key] = cell(c, id: id, ctx: ctx)
                    }
                }
                items.append(o)
            }
            let root: [String: Any] = ["totalResults": ids.count, "results": items]
            if let d = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]), let t = String(data: d, encoding: .utf8) { out += t + "\n" }
        case .m3u, .m3u8:
            out += "#EXTM3U\r\n"
            for id in ids {
                out += "#EXTINF:-1," + s.name(id) + "\r\n"
                out += ctx.fullPath(id) + "\r\n"
            }
        }
        return out
    }

    public static func jsonKey(_ canonical: String) -> String {
        switch canonical {
        case "fullpath": return "full_path"
        case "datemodified": return "date_modified"
        case "datecreated": return "date_created"
        case "dateaccessed": return "date_accessed"
        case "daterun": return "date_run"
        case "runcount": return "run_count"
        case "daterecentlychanged": return "date_recently_changed"
        default: return canonical
        }
    }

    public func write(_ ids: [ItemID], ctx: EvalContext, to url: URL) throws {
        let text = render(ids, ctx: ctx)
        let data = (format == .m3u ? text.data(using: .isoLatin1, allowLossyConversion: true) : text.data(using: .utf8)) ?? Data(text.utf8)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
