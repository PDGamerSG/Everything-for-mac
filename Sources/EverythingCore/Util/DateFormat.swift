import Foundation

/// Date display formats (Everything `-date-format` 0–6).
public enum DateFormat {
    public enum Style: Int, CaseIterable, Sendable {
        case system = 0          // locale short date + time
        case iso8601 = 1         // 2026-10-23T18:30:00
        case iso8601Date = 2     // 2026-10-23
        case iso8601Space = 3    // 2026-10-23 18:30:00
        case localeDate = 4
        case localeDateTime = 5
        case filetime = 6
    }

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return f
    }()
    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let isoSpaceFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()
    private static let systemFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f
    }()
    private static let localeDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()
    private static let localeDateTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .medium; return f
    }()
    private static let lock = NSLock()

    public static func format(_ ns: Int64, style: Style = .system) -> String {
        guard ns != 0 else { return "" }
        if style == .filetime { return String(Timestamps.toFiletime(ns)) }
        let d = Timestamps.toDate(ns)
        lock.lock(); defer { lock.unlock() }
        switch style {
        case .system: return systemFormatter.string(from: d)
        case .iso8601: return isoFormatter.string(from: d)
        case .iso8601Date: return isoDateFormatter.string(from: d)
        case .iso8601Space: return isoSpaceFormatter.string(from: d)
        case .localeDate: return localeDateFormatter.string(from: d)
        case .localeDateTime: return localeDateTimeFormatter.string(from: d)
        case .filetime: return ""
        }
    }

    public static func iso(_ ns: Int64) -> String { format(ns, style: .iso8601) }

    /// Parses ISO 8601 (with optional time) or FILETIME text.
    public static func parse(_ s: String) -> Int64? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        if let ft = UInt64(t), ft > 100_000_000_000_000_000 { return Timestamps.fromFiletime(ft) }
        lock.lock(); defer { lock.unlock() }
        for f in [isoFormatter, isoSpaceFormatter, isoDateFormatter] { if let d = f.date(from: t) { return Timestamps.fromDate(d) } }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: t) { return Timestamps.fromDate(d) }
        return nil
    }
}

/// Size display (Everything size formats and standards).
public enum SizeFormat {
    public static func format(_ bytes: UInt64, standard: SizeStandard = .jedec, mode: SizeFormatMode = .auto, digitGrouping: Bool = true) -> String {
        let k: Double = standard == .metric ? 1000 : 1024
        let units = standard == .iec ? ["B", "KiB", "MiB", "GiB", "TiB", "PiB"] : ["B", "KB", "MB", "GB", "TB", "PB"]
        func group(_ v: UInt64) -> String {
            guard digitGrouping else { return String(v) }
            let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = ","; f.usesGroupingSeparator = true
            return f.string(from: NSNumber(value: v)) ?? String(v)
        }
        switch mode {
        case .bytes: return group(bytes)
        case .kb: return group(UInt64((Double(bytes) / k).rounded(.up))) + " " + units[1]
        case .mb: return group(UInt64((Double(bytes) / k / k).rounded(.up))) + " " + units[2]
        case .auto:
            if bytes < UInt64(k) { return group(bytes) + " " + units[0] }
            var v = Double(bytes)
            var u = 0
            while v >= k && u < units.count - 1 { v /= k; u += 1 }
            let s = v < 10 ? String(format: "%.2f", v) : (v < 100 ? String(format: "%.1f", v) : String(format: "%.0f", v))
            return s + " " + units[u]
        }
    }
}
