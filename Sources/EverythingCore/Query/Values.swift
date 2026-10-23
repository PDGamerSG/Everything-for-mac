import Foundation

/// Numeric comparison / range produced from function values like `>1gb`, `10mb..50mb`, `!=5`, `unknown`.
public struct NumRange: Equatable, Hashable, Sendable {
    public var lower: Int64?         // inclusive
    public var upper: Int64?         // inclusive
    public var negate = false        // `!=` / `!value`
    public var unknown = false       // matches items whose value is unknown (0 / missing)
    public var matchesAny = false    // empty value: any non-zero

    public init(lower: Int64? = nil, upper: Int64? = nil, negate: Bool = false, unknown: Bool = false, matchesAny: Bool = false) {
        self.lower = lower; self.upper = upper; self.negate = negate; self.unknown = unknown; self.matchesAny = matchesAny
    }

    public static func exact(_ v: Int64) -> NumRange { NumRange(lower: v, upper: v) }

    public func contains(_ v: Int64, known: Bool = true) -> Bool {
        if unknown { return !known }
        if matchesAny { return known && v != 0 }
        var r = true
        if let l = lower, v < l { r = false }
        if let u = upper, v > u { r = false }
        return negate ? !r : r
    }
}

/// Date range [start, end) in ns since 1970.
public struct DateRange: Equatable, Hashable, Sendable {
    public var start: Int64?
    public var end: Int64?
    public var negate = false
    public var unknown = false

    public init(start: Int64? = nil, end: Int64? = nil, negate: Bool = false, unknown: Bool = false) {
        self.start = start; self.end = end; self.negate = negate; self.unknown = unknown
    }

    public func contains(_ ns: Int64) -> Bool {
        if unknown { return ns == 0 }
        if ns == 0 { return negate ? false : false }
        var r = true
        if let s = start, ns < s { r = false }
        if let e = end, ns >= e { r = false }
        return negate ? !r : r
    }
}

public enum ValueParser {
    // MARK: numbers

    public struct Comparison {
        public var op: String   // "", "<", "<=", ">", ">=", "=", "!=", "!"
        public var rest: String
    }

    public static func splitComparison(_ s: String) -> Comparison {
        let t = s.trimmingCharacters(in: .whitespaces)
        for op in ["<=", ">=", "!=", "==", "<", ">", "=", "!"] where t.hasPrefix(op) {
            return Comparison(op: op == "==" ? "=" : op, rest: String(t.dropFirst(op.count)).trimmingCharacters(in: .whitespaces))
        }
        return Comparison(op: "", rest: t)
    }

    /// Splits `a..b` or `a-b` ranges. `allowDash` is false for values that legitimately contain dashes (dates).
    public static func splitRange(_ s: String, allowDash: Bool) -> (String, String)? {
        if let r = s.range(of: "..") { return (String(s[..<r.lowerBound]), String(s[r.upperBound...])) }
        if allowDash, let i = s.firstIndex(of: "-"), i != s.startIndex, s.index(after: i) != s.endIndex {
            return (String(s[..<i]), String(s[s.index(after: i)...]))
        }
        return nil
    }

    public static func parseInteger(_ s: String) -> Int64? {
        let t = s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("0x") { return Int64(t.dropFirst(2), radix: 16) }
        if let i = Int64(t) { return i }
        if let d = Double(t) { return Int64(d) }
        return nil
    }

    /// Generic numeric range with optional unit conversion.
    public static func parseNumber(_ raw: String, unit: (String) -> Int64? = { _ in nil }, scale: Int64 = 1) -> NumRange? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return NumRange(matchesAny: true) }
        if s.lowercased() == "unknown" { return NumRange(unknown: true) }
        let cmp = splitComparison(s)
        if cmp.op.isEmpty, let (a, b) = splitRange(cmp.rest, allowDash: true), let lo = parseUnitNumber(a, unit: unit, scale: scale), let hi = parseUnitNumber(b, unit: unit, scale: scale) {
            return NumRange(lower: min(lo, hi), upper: max(lo, hi))
        }
        guard let v = parseUnitNumber(cmp.rest, unit: unit, scale: scale) else { return nil }
        switch cmp.op {
        case "<": return NumRange(upper: v - 1)
        case "<=": return NumRange(upper: v)
        case ">": return NumRange(lower: v + 1)
        case ">=": return NumRange(lower: v)
        case "!=", "!": return NumRange(lower: v, upper: v, negate: true)
        default: return NumRange(lower: v, upper: v)
        }
    }

    static func parseUnitNumber(_ s: String, unit: (String) -> Int64?, scale: Int64) -> Int64? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: "")
        if t.isEmpty { return nil }
        // split number and unit suffix
        var numEnd = t.startIndex
        while numEnd < t.endIndex, t[numEnd].isNumber || t[numEnd] == "." || (numEnd == t.startIndex && t[numEnd] == "-") { numEnd = t.index(after: numEnd) }
        let numPart = String(t[..<numEnd]), unitPart = String(t[numEnd...]).trimmingCharacters(in: .whitespaces)
        if numPart.isEmpty {
            // pure keyword (e.g. size constants handled by caller)
            return unit(unitPart)
        }
        guard let d = Double(numPart) else { return nil }
        if unitPart.isEmpty { return Int64(d * Double(scale)) }
        guard let mult = unit(unitPart) else { return nil }
        return Int64(d * Double(mult))
    }

    // MARK: sizes

    public static func sizeUnit(_ u: String, standard: SizeStandard) -> Int64? {
        let k: Int64 = standard == .metric ? 1000 : 1024
        switch u {
        case "", "b", "bytes", "byte": return 1
        case "kb", "k", "kib", "kilobytes", "kilobyte": return k
        case "mb", "m", "mib", "megabytes", "megabyte": return k * k
        case "gb", "g", "gib", "gigabytes", "gigabyte": return k * k * k
        case "tb", "t", "tib", "terabytes", "terabyte": return k * k * k * k
        case "pb", "p", "pib": return k * k * k * k * k
        default: return nil
        }
    }

    /// Everything size constants.
    public static func sizeConstant(_ s: String) -> NumRange? {
        let kb: Int64 = 1024, mb = kb * 1024
        switch s.lowercased() {
        case "empty": return NumRange(lower: 0, upper: 0)
        case "tiny": return NumRange(lower: 0, upper: 10 * kb)
        case "small": return NumRange(lower: 10 * kb + 1, upper: 100 * kb)
        case "medium": return NumRange(lower: 100 * kb + 1, upper: mb)
        case "large": return NumRange(lower: mb + 1, upper: 16 * mb)
        case "huge": return NumRange(lower: 16 * mb + 1, upper: 128 * mb)
        case "gigantic": return NumRange(lower: 128 * mb + 1, upper: nil)
        case "unknown": return NumRange(unknown: true)
        default: return nil
        }
    }

    public static func parseSize(_ raw: String, standard: SizeStandard = .jedec) -> NumRange? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let c = sizeConstant(s) { return c }
        return parseNumber(s, unit: { sizeUnit($0, standard: standard) })
    }

    // MARK: durations (seconds)

    public static func durationUnit(_ u: String) -> Int64? {
        switch u {
        case "", "s", "sec", "secs", "second", "seconds": return 1
        case "m", "min", "mins", "minute", "minutes": return 60
        case "h", "hr", "hrs", "hour", "hours": return 3600
        case "d", "day", "days": return 86400
        case "ms": return 0
        default: return nil
        }
    }

    /// Durations in seconds. Accepts `10mins`, `1h30m`, `1:30:00`, `90` (seconds), ranges, comparisons.
    public static func parseDuration(_ raw: String) -> NumRange? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { return NumRange(matchesAny: true) }
        if s == "unknown" { return NumRange(unknown: true) }
        let cmp = splitComparison(s)
        func one(_ t: String) -> Int64? {
            if t.contains(":") {
                let parts = t.split(separator: ":").map { Double($0) ?? -1 }
                if parts.contains(where: { $0 < 0 }) { return nil }
                var secs = 0.0
                for p in parts { secs = secs * 60 + p }
                return Int64(secs)
            }
            // compound like 1h30m
            var total: Int64 = 0
            var num = ""
            var any = false
            var i = t.startIndex
            while i < t.endIndex {
                let c = t[i]
                if c.isNumber || c == "." { num.append(c); i = t.index(after: i); continue }
                var unit = ""
                while i < t.endIndex, t[i].isLetter { unit.append(t[i]); i = t.index(after: i) }
                guard let n = Double(num), let m = durationUnit(unit) else { return nil }
                total += Int64(n * Double(m)); num = ""; any = true
            }
            if !num.isEmpty, let n = Double(num) { total += Int64(n); any = true }
            return any ? total : nil
        }
        if cmp.op.isEmpty, let (a, b) = splitRange(cmp.rest, allowDash: true), let lo = one(a), let hi = one(b) { return NumRange(lower: min(lo, hi), upper: max(lo, hi)) }
        guard let v = one(cmp.rest) else { return nil }
        switch cmp.op {
        case "<": return NumRange(upper: v - 1)
        case "<=": return NumRange(upper: v)
        case ">": return NumRange(lower: v + 1)
        case ">=": return NumRange(lower: v)
        case "!=", "!": return NumRange(lower: v, upper: v, negate: true)
        default: return NumRange(lower: v, upper: v)
        }
    }

    // MARK: dates

    static let monthNames = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    static let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// Resolves a date keyword or literal into a [start, end) interval (ns).
    public static func dateInterval(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> (Int64, Int64)? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { return nil }
        let cal = calendar
        let ns = Timestamps.fromDate
        func dayStart(_ d: Date) -> Date { cal.startOfDay(for: d) }
        func add(_ comp: Calendar.Component, _ n: Int, _ d: Date) -> Date { cal.date(byAdding: comp, value: n, to: d) ?? d }
        let today = dayStart(now)
        switch s {
        case "today": return (ns(today), ns(add(.day, 1, today)))
        case "yesterday": return (ns(add(.day, -1, today)), ns(today))
        case "tomorrow": return (ns(add(.day, 1, today)), ns(add(.day, 2, today)))
        case "now": return (ns(now), ns(now) + 1)
        case "thisweek", "week":
            let start = cal.dateInterval(of: .weekOfYear, for: now)!.start
            return (ns(start), ns(add(.weekOfYear, 1, start)))
        case "lastweek", "prevweek", "previousweek":
            let start = cal.dateInterval(of: .weekOfYear, for: now)!.start
            return (ns(add(.weekOfYear, -1, start)), ns(start))
        case "pastweek", "past7days", "last7days": return (ns(add(.day, -7, today)), ns(add(.day, 1, today)))
        case "thismonth", "month":
            let start = cal.dateInterval(of: .month, for: now)!.start
            return (ns(start), ns(add(.month, 1, start)))
        case "lastmonth", "prevmonth", "previousmonth":
            let start = cal.dateInterval(of: .month, for: now)!.start
            return (ns(add(.month, -1, start)), ns(start))
        case "pastmonth", "past30days", "last30days": return (ns(add(.day, -30, today)), ns(add(.day, 1, today)))
        case "thisyear", "year":
            let start = cal.dateInterval(of: .year, for: now)!.start
            return (ns(start), ns(add(.year, 1, start)))
        case "lastyear", "prevyear", "previousyear":
            let start = cal.dateInterval(of: .year, for: now)!.start
            return (ns(add(.year, -1, start)), ns(start))
        case "pastyear", "past365days": return (ns(add(.year, -1, today)), ns(add(.day, 1, today)))
        case "mtd": return (ns(cal.dateInterval(of: .month, for: now)!.start), ns(now) + 1)
        case "ytd": return (ns(cal.dateInterval(of: .year, for: now)!.start), ns(now) + 1)
        case "qtd": return (ns(cal.dateInterval(of: .quarter, for: now)!.start), ns(now) + 1)
        case "thisquarter":
            let start = cal.dateInterval(of: .quarter, for: now)!.start
            return (ns(start), ns(add(.quarter, 1, start)))
        case "lastquarter":
            let start = cal.dateInterval(of: .quarter, for: now)!.start
            return (ns(add(.quarter, -1, start)), ns(start))
        default: break
        }
        // month names: most recent occurrence of that month (incl. current)
        if let mi = monthNames.firstIndex(where: { $0 == s || $0.hasPrefix(s) && s.count >= 3 }) {
            var comps = cal.dateComponents([.year, .month], from: now)
            let curMonth = comps.month!
            if mi + 1 > curMonth { comps.year! -= 1 }
            comps.month = mi + 1; comps.day = 1
            let start = cal.date(from: comps)!
            return (ns(start), ns(add(.month, 1, start)))
        }
        if let wi = weekdayNames.firstIndex(where: { $0 == s || $0.hasPrefix(s) && s.count >= 3 }) {
            let cur = cal.component(.weekday, from: now) - 1
            var back = cur - wi
            if back < 0 { back += 7 }
            let start = add(.day, -back, today)
            return (ns(start), ns(add(.day, 1, start)))
        }
        // relative: 7days, 2weeks, 3months, 1year, 12hours, 30minutes, 90seconds; last3days / past3days / prev3days
        var rel = s
        for pre in ["last", "past", "prev", "previous"] where rel.hasPrefix(pre) { rel = String(rel.dropFirst(pre.count)); break }
        let digits = rel.prefix { $0.isNumber }
        if !digits.isEmpty, let n = Int(digits) {
            let unit = String(rel.dropFirst(digits.count))
            var comp: Calendar.Component? = nil
            switch unit {
            case "year", "years", "y": comp = .year
            case "month", "months", "mo": comp = .month
            case "week", "weeks", "w": comp = .weekOfYear
            case "day", "days", "d": comp = .day
            case "hour", "hours", "h": comp = .hour
            case "minute", "minutes", "min", "mins", "m": comp = .minute
            case "second", "seconds", "sec", "secs", "s": comp = .second
            default: break
            }
            if let c = comp {
                let coarse = c == .year || c == .month || c == .weekOfYear || c == .day
                let endDate = coarse ? add(.day, 1, today) : now
                let base = coarse ? today : now
                return (ns(add(c, -n, base)), ns(endDate) + (coarse ? 0 : 1))
            }
        }
        // FILETIME (18+ digits) or Excel serial date (decimal)
        if let v = UInt64(s), v > 100_000_000_000_000_000 {
            let t = Timestamps.fromFiletime(v)
            return (t, t + 1)
        }
        if let d = Double(s), s.contains("."), d > 1, d < 100000 {
            let t = ns(Date(timeIntervalSince1970: (d - 25569) * 86400))
            return (t, t + 1)
        }
        return isoInterval(s, calendar: cal)
    }

    /// ISO 8601-ish: 2026, 2026-09, 2026-09-04, 2026-09-04T12, 2026-09-04 12:30, 2026-09-04T12:30:15. Also d/m/y and m/d/y locale forms.
    static func isoInterval(_ s: String, calendar cal: Calendar) -> (Int64, Int64)? {
        let t = s.replacingOccurrences(of: "t", with: " ").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let parts = t.split(separator: " ", maxSplits: 1).map(String.init)
        let dateParts = parts[0].split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        var comps = DateComponents()
        var precision: Calendar.Component
        func int(_ x: String) -> Int? { x == "*" ? nil : Int(x) }
        if dateParts.count == 1 {
            guard let y = int(dateParts[0]), dateParts[0].count == 4 else { return nil }
            comps.year = y; precision = .year
        } else if dateParts[0].count == 4 {
            // y-m[-d]
            guard let y = int(dateParts[0]) else { return nil }
            comps.year = y
            guard dateParts.count >= 2, let m = int(dateParts[1]), (1...12).contains(m) else { return nil }
            comps.month = m; precision = .month
            if dateParts.count >= 3 {
                guard let d = int(dateParts[2]), (1...31).contains(d) else { return nil }
                comps.day = d; precision = .day
            }
        } else if dateParts.count == 3, let a = int(dateParts[0]), let b = int(dateParts[1]), let y = int(dateParts[2]) {
            // locale: assume d-m-y unless first > 12 handled; use system preference
            let dmy = ValueParser.localeDayFirst
            let (d, m) = dmy ? (a, b) : (b, a)
            guard (1...12).contains(m), (1...31).contains(d) else { return nil }
            comps.year = y < 100 ? 2000 + y : y; comps.month = m; comps.day = d; precision = .day
        } else if dateParts.count == 2, let a = int(dateParts[0]), let b = int(dateParts[1]) {
            // m-d or d-m of current year
            let dmy = ValueParser.localeDayFirst
            let (d, m) = dmy ? (a, b) : (b, a)
            guard (1...12).contains(m), (1...31).contains(d) else { return nil }
            comps.year = cal.component(.year, from: Date()); comps.month = m; comps.day = d; precision = .day
        } else { return nil }
        if parts.count == 2 {
            let tp = parts[1].split(separator: ":").map { Int($0) }
            guard let h = tp.first ?? nil else { return nil }
            comps.hour = h; precision = .hour
            if tp.count >= 2, let m = tp[1] { comps.minute = m; precision = .minute }
            if tp.count >= 3, let sec = tp[2] { comps.second = sec; precision = .second }
        }
        comps.calendar = cal
        guard let start = cal.date(from: comps) else { return nil }
        let end = cal.date(byAdding: precision, value: 1, to: start) ?? start
        return (Timestamps.fromDate(start), Timestamps.fromDate(end))
    }

    public static var localeDayFirst: Bool = {
        let f = DateFormatter.dateFormat(fromTemplate: "dMy", options: 0, locale: .current) ?? "M/d/y"
        return (f.firstIndex(of: "d") ?? f.endIndex) < (f.firstIndex(of: "M") ?? f.endIndex)
    }()

    /// Full date value: comparisons, ranges, keywords, `unknown`.
    public static func parseDate(_ raw: String, now: Date = Date()) -> DateRange? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return DateRange(start: 1, end: nil) } // any known date
        if s.lowercased() == "unknown" { return DateRange(unknown: true) }
        let cmp = splitComparison(s)
        if cmp.op.isEmpty, let (a, b) = splitRange(cmp.rest, allowDash: false) {
            guard let lo = dateInterval(a, now: now), let hi = dateInterval(b, now: now) else { return nil }
            return DateRange(start: min(lo.0, hi.0), end: max(lo.1, hi.1))
        }
        guard let iv = dateInterval(cmp.rest, now: now) else { return nil }
        switch cmp.op {
        case "<": return DateRange(start: nil, end: iv.0)
        case "<=": return DateRange(start: nil, end: iv.1)
        case ">": return DateRange(start: iv.1, end: nil)
        case ">=": return DateRange(start: iv.0, end: nil)
        case "!=", "!": return DateRange(start: iv.0, end: iv.1, negate: true)
        default: return DateRange(start: iv.0, end: iv.1)
        }
    }

    // MARK: lists

    public static func list(_ v: String) -> [String] {
        v.split(separator: ";").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: date parts

    public static func parseMonth(_ s: String) -> NumRange? {
        let t = s.lowercased().trimmingCharacters(in: .whitespaces)
        if let i = monthNames.firstIndex(where: { $0 == t || ($0.hasPrefix(t) && t.count >= 3) }) { return .exact(Int64(i + 1)) }
        return parseNumber(t)
    }

    public static func parseWeekday(_ s: String) -> NumRange? {
        let t = s.lowercased().trimmingCharacters(in: .whitespaces)
        if let i = weekdayNames.firstIndex(where: { $0 == t || ($0.hasPrefix(t) && t.count >= 3) }) { return .exact(Int64(i)) }
        return parseNumber(t)
    }

    /// Time of day in seconds since midnight: `12:30`, `>09:00`, `12:00..13:00`.
    public static func parseTimeOfDay(_ s: String) -> NumRange? {
        func one(_ t: String) -> Int64? {
            let p = t.split(separator: ":").map { Int64($0) }
            guard let h = p.first ?? nil else { return nil }
            var secs = h * 3600
            if p.count > 1, let m = p[1] { secs += m * 60 }
            if p.count > 2, let sec = p[2] { secs += sec }
            return secs
        }
        let cmp = splitComparison(s)
        if cmp.op.isEmpty, let (a, b) = splitRange(cmp.rest, allowDash: false), let lo = one(a), let hi = one(b) { return NumRange(lower: lo, upper: hi) }
        guard let v = one(cmp.rest) else { return nil }
        switch cmp.op {
        case "<": return NumRange(upper: v - 1)
        case "<=": return NumRange(upper: v)
        case ">": return NumRange(lower: v + 1)
        case ">=": return NumRange(lower: v)
        case "!=", "!": return NumRange(lower: v, upper: v, negate: true)
        default: return NumRange(lower: v, upper: v)
        }
    }
}
