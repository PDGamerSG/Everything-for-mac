import Testing
import Foundation
@testable import EverythingCore

@Suite struct ValuesTests {
    @Test func sizes() {
        #expect(ValueParser.parseSize(">1gb") == NumRange(lower: 1_073_741_825))
        #expect(ValueParser.parseSize(">=1gb") == NumRange(lower: 1_073_741_824))
        #expect(ValueParser.parseSize("<1kb") == NumRange(upper: 1023))
        #expect(ValueParser.parseSize("10mb..50mb") == NumRange(lower: 10 * 1_048_576, upper: 50 * 1_048_576))
        #expect(ValueParser.parseSize("10mb-50mb") == NumRange(lower: 10 * 1_048_576, upper: 50 * 1_048_576))
        #expect(ValueParser.parseSize("1kb", standard: .metric) == NumRange.exact(1000))
        #expect(ValueParser.parseSize("1,024") == NumRange.exact(1024))
        #expect(ValueParser.parseSize("1.5kb") == NumRange.exact(1536))
        #expect(ValueParser.parseSize("!=0") == NumRange(lower: 0, upper: 0, negate: true))
        #expect(ValueParser.parseSize("empty") == NumRange(lower: 0, upper: 0))
        #expect(ValueParser.parseSize("gigantic") == NumRange(lower: Int64(134_217_729), upper: nil))
        #expect(ValueParser.parseSize("unknown")?.unknown == true)
        #expect(ValueParser.parseSize("")?.matchesAny == true)
        #expect(ValueParser.parseSize("abc") == nil)
        #expect(NumRange(lower: 5, upper: 10).contains(7))
        #expect(!NumRange(lower: 5, upper: 10).contains(11))
        #expect(NumRange(lower: 5, upper: 5, negate: true).contains(6))
    }

    @Test func durations() {
        #expect(ValueParser.parseDuration("10mins..30mins") == NumRange(lower: 600, upper: 1800))
        #expect(ValueParser.parseDuration(">1h") == NumRange(lower: 3601))
        #expect(ValueParser.parseDuration("1h30m") == NumRange.exact(5400))
        #expect(ValueParser.parseDuration("1:30:00") == NumRange.exact(5400))
        #expect(ValueParser.parseDuration("2:30") == NumRange.exact(150))
        #expect(ValueParser.parseDuration("90") == NumRange.exact(90))
        #expect(ValueParser.parseDuration("<3secs") == NumRange(upper: 2))
    }

    @Test func numbers() {
        #expect(ValueParser.parseNumber("5") == NumRange.exact(5))
        #expect(ValueParser.parseNumber("<=5") == NumRange(upper: 5))
        #expect(ValueParser.parseNumber("1..3") == NumRange(lower: 1, upper: 3))
        #expect(ValueParser.parseNumber("0x10") == nil) // hex handled by hex-to-number modifier
        #expect(ValueParser.parseInteger("0x10") == 16)
        #expect(ValueParser.parseNumber("!5") == NumRange(lower: 5, upper: 5, negate: true))
    }

    @Test func dates() throws {
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 15, minute: 0))!
        func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 0) -> Int64 { Timestamps.fromDate(cal.date(from: DateComponents(year: y, month: m, day: day, hour: h))!) }
        #expect(ValueParser.parseDate("today", now: now) == DateRange(start: d(2026, 10, 23), end: d(2026, 10, 24)))
        #expect(ValueParser.parseDate("yesterday", now: now) == DateRange(start: d(2026, 10, 22), end: d(2026, 10, 23)))
        #expect(ValueParser.parseDate("7days", now: now) == DateRange(start: d(2026, 10, 16), end: d(2026, 10, 24)))
        #expect(ValueParser.parseDate("last7days", now: now) == DateRange(start: d(2026, 10, 16), end: d(2026, 10, 24)))
        #expect(ValueParser.parseDate("2026-09-04", now: now) == DateRange(start: d(2026, 9, 4), end: d(2026, 9, 5)))
        #expect(ValueParser.parseDate("2026-09", now: now) == DateRange(start: d(2026, 9, 1), end: d(2026, 10, 1)))
        #expect(ValueParser.parseDate("2026", now: now) == DateRange(start: d(2026, 1, 1), end: d(2027, 1, 1)))
        #expect(ValueParser.parseDate(">2022", now: now) == DateRange(start: d(2023, 1, 1), end: nil))
        #expect(ValueParser.parseDate("<2022", now: now) == DateRange(start: nil, end: d(2022, 1, 1)))
        #expect(ValueParser.parseDate("2025-07-01..2026-06-30", now: now) == DateRange(start: d(2025, 7, 1), end: d(2026, 7, 1)))
        #expect(ValueParser.parseDate("2026-09-04T12", now: now) == DateRange(start: d(2026, 9, 4, 12), end: d(2026, 9, 4, 13)))
        #expect(ValueParser.parseDate("september", now: now) == DateRange(start: d(2026, 9, 1), end: d(2026, 10, 1)))
        #expect(ValueParser.parseDate("nov", now: now) == DateRange(start: d(2025, 11, 1), end: d(2025, 12, 1)))
        #expect(ValueParser.parseDate("thismonth", now: now) == DateRange(start: d(2026, 10, 1), end: d(2026, 11, 1)))
        #expect(ValueParser.parseDate("lastmonth", now: now) == DateRange(start: d(2026, 9, 1), end: d(2026, 10, 1)))
        #expect(ValueParser.parseDate("thisyear", now: now) == DateRange(start: d(2026, 1, 1), end: d(2027, 1, 1)))
        #expect(ValueParser.parseDate("mtd", now: now)?.start == d(2026, 10, 1))
        #expect(ValueParser.parseDate("unknown", now: now)?.unknown == true)
        #expect(ValueParser.parseDate("garbage", now: now) == nil)
        // weekday: 2026-10-23 is a Friday → "wed" is Oct 21
        #expect(ValueParser.parseDate("wed", now: now) == DateRange(start: d(2026, 10, 21), end: d(2026, 10, 22)))
        // FILETIME
        let ft = Timestamps.toFiletime(d(2026, 9, 4))
        #expect(ValueParser.parseDate(String(ft), now: now)?.start == d(2026, 9, 4))
        // relative hours are exact
        let r = ValueParser.parseDate("2hours", now: now)!
        #expect(r.start == Timestamps.fromDate(now) - 7200 * 1_000_000_000)
        #expect(DateRange(start: d(2026, 1, 1), end: d(2027, 1, 1)).contains(d(2026, 6, 1)))
        #expect(!DateRange(start: d(2026, 1, 1), end: d(2027, 1, 1)).contains(d(2027, 1, 1)))
    }

    @Test func dateParts() {
        #expect(ValueParser.parseMonth("sep") == NumRange.exact(9))
        #expect(ValueParser.parseMonth("12") == NumRange.exact(12))
        #expect(ValueParser.parseWeekday("monday") == NumRange.exact(1))
        #expect(ValueParser.parseTimeOfDay("12:30") == NumRange.exact(45000))
        #expect(ValueParser.parseTimeOfDay(">09:00") == NumRange(lower: 32401))
        #expect(ValueParser.parseTimeOfDay("12:00..13:00") == NumRange(lower: 43200, upper: 46800))
    }
}
