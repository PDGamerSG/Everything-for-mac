import Foundation

public enum Paths {
    /// Normalizes a user-supplied path: backslashes → slashes, trailing slash trimmed (except root),
    /// `~` expanded, duplicate separators collapsed.
    public static func normalize(_ p: String) -> String {
        var s = p.replacingOccurrences(of: "\\", with: "/")
        if s.hasPrefix("~") { s = (s as NSString).expandingTildeInPath }
        while s.contains("//") { s = s.replacingOccurrences(of: "//", with: "/") }
        if s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    public static func join(_ dir: String, _ name: String) -> String {
        if dir.isEmpty { return name }
        if dir.hasSuffix("/") { return dir + name }
        return dir + "/" + name
    }

    public static func parent(_ p: String) -> String {
        guard let i = p.lastIndex(of: "/") else { return "" }
        if i == p.startIndex { return "/" }
        return String(p[..<i])
    }

    public static func lastComponent(_ p: String) -> String {
        guard let i = p.lastIndex(of: "/") else { return p }
        return String(p[p.index(after: i)...])
    }

    /// Converts a Windows style path (`C:\foo`) to a best-effort POSIX path. Drive letters map to `/`.
    public static func fromWindows(_ p: String) -> String {
        var s = p.replacingOccurrences(of: "\\", with: "/")
        if s.count >= 2, s[s.index(s.startIndex, offsetBy: 1)] == ":" {
            s = String(s.dropFirst(2))
            if !s.hasPrefix("/") { s = "/" + s }
        }
        return s
    }

    /// Display path with Windows separators when `windowsStyle` is set (for EFU export compatibility).
    public static func toWindows(_ p: String) -> String {
        "C:" + p.replacingOccurrences(of: "/", with: "\\")
    }

    public static func isHiddenName(_ name: String) -> Bool { name.hasPrefix(".") }
}

/// Monotonic nanosecond timestamps used for index dates.
public enum Timestamps {
    public static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1e9) }

    public static func fromTimespec(_ ts: timespec) -> Int64 {
        Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
    }

    public static func toDate(_ ns: Int64) -> Date { Date(timeIntervalSince1970: Double(ns) / 1e9) }
    public static func fromDate(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1e9) }

    /// Windows FILETIME: 100 ns intervals since 1601-01-01.
    public static let filetimeEpochOffsetSeconds: Int64 = 11_644_473_600
    public static func toFiletime(_ ns: Int64) -> UInt64 {
        guard ns != 0 else { return 0 }
        let hundredNs = ns / 100
        return UInt64(hundredNs + filetimeEpochOffsetSeconds * 10_000_000)
    }
    public static func fromFiletime(_ ft: UInt64) -> Int64 {
        guard ft != 0 else { return 0 }
        return (Int64(ft) - filetimeEpochOffsetSeconds * 10_000_000) * 100
    }
}
