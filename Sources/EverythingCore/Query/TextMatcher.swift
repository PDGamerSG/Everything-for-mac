import Foundation

public enum WildcardLevel: Equatable, Sendable { case off, basic, extended }

/// Resolved matching options for one term (window defaults + modifiers).
public struct MatchMode: Equatable, Sendable {
    public var matchCase = false
    public var matchDiacritics = false
    public var wholeWords = false
    public var prefix = false
    public var suffix = false
    public var ignorePunctuation = false
    public var ignoreWhitespace = false
    public var regex = false
    public var wildcards: WildcardLevel = .basic
    public var wholeFilenameForWildcards = true
    public var whole = false
    public var startWith = false
    public var endWith = false
    public var starAll = false
    public var soundex = false
    public var pinyin: PinyinMode = .off
    public var dotAll = false
    public var multiLine = false
    public var ungreedy = false

    public init() {}

    public init(defaults: MatchDefaults, modifiers m: ModifierSet, wholeFilenameForWildcards: Bool = true, pinyinDefault: Bool = false) {
        matchCase = m.matchCase ?? defaults.matchCase
        matchDiacritics = m.diacritics ?? defaults.matchDiacritics
        wholeWords = m.wholeWords ?? defaults.matchWholeWords
        prefix = m.prefix ?? defaults.matchPrefix
        suffix = m.suffix ?? defaults.matchSuffix
        ignorePunctuation = m.ignorePunctuation ?? defaults.ignorePunctuation
        ignoreWhitespace = m.ignoreWhitespace ?? defaults.ignoreWhitespace
        regex = m.regex ?? defaults.regex
        if let w = m.wildcards { wildcards = w ? .extended : .off }
        self.wholeFilenameForWildcards = wholeFilenameForWildcards
        whole = m.whole
        startWith = m.startWith
        endWith = m.endWith
        starAll = m.starAll
        soundex = m.soundex
        pinyin = m.pinyin ?? (pinyinDefault ? .both : .off)
        dotAll = m.dotAll
        multiLine = m.multiLine
        ungreedy = m.ungreedy
    }
}

/// Matches a search pattern against names/paths/property strings honoring all Everything match modes.
public final class TextMatcher: @unchecked Sendable {
    public enum Strategy { case empty, plainFolded, plainCase, plainCaseOnly, complex, wildcard, regex, soundex, pinyin }

    public let pattern: String
    public let mode: MatchMode
    public let strategy: Strategy
    private let foldedPattern: [UInt8]       // for plainFolded (unicode fold)
    private let rawPattern: [UInt8]          // for plainCase
    private let caseFoldedPatternString: String
    private let wildcard: WildcardPattern?
    private let regexObj: NSRegularExpression?
    private let normalizedPattern: String    // for complex path
    public var compileError: String? = nil

    public init(pattern: String, mode: MatchMode) {
        self.pattern = pattern
        self.mode = mode
        rawPattern = Array(pattern.utf8)
        foldedPattern = Array(ItemStore.fold(pattern).utf8)
        caseFoldedPatternString = ItemStore.foldCaseOnly(pattern)
        normalizedPattern = TextMatcher.normalize(pattern, mode: mode)
        var wc: WildcardPattern? = nil
        var re: NSRegularExpression? = nil
        var strat: Strategy
        if pattern.isEmpty {
            strat = .empty
        } else if mode.regex {
            var opts: NSRegularExpression.Options = []
            if !mode.matchCase { opts.insert(.caseInsensitive) }
            if mode.dotAll { opts.insert(.dotMatchesLineSeparators) }
            if mode.multiLine { opts.insert(.anchorsMatchLines) }
            var src = pattern
            if mode.ungreedy { src = TextMatcher.makeUngreedy(src) }
            if mode.wholeWords { src = "\\b(?:" + src + ")\\b" }
            if mode.whole { src = "^(?:" + src + ")$" }
            do { re = try NSRegularExpression(pattern: src, options: opts); strat = .regex }
            catch { compileError = "Invalid regular expression"; strat = .empty }
        } else if mode.soundex {
            strat = .soundex
        } else if mode.pinyin != .off && !Pinyin.containsChinese(pattern) {
            strat = .pinyin
        } else if mode.wildcards != .off && (pattern.contains("*") || pattern.contains("?") || (mode.wildcards == .extended && (pattern.contains("[") || pattern.contains("#")))) {
            let wpat = mode.matchDiacritics ? pattern : TextMatcher.foldDiacritics(pattern)
            wc = WildcardPattern(wpat, extended: mode.wildcards == .extended, caseInsensitive: !mode.matchCase, starAll: mode.starAll)
            strat = .wildcard
        } else if mode.wholeWords || mode.prefix || mode.suffix || mode.ignorePunctuation || mode.ignoreWhitespace || mode.whole || mode.startWith || mode.endWith {
            strat = .complex
        } else if mode.matchCase && mode.matchDiacritics {
            strat = .plainCase
        } else if !mode.matchCase && !mode.matchDiacritics {
            strat = .plainFolded
        } else {
            strat = .complex
        }
        wildcard = wc
        regexObj = re
        strategy = strat
    }

    /// True when the fast byte path (`matchesFolded`) is applicable.
    public var usesFoldedBytes: Bool { strategy == .plainFolded }
    public var usesRawBytes: Bool { strategy == .plainCase }

    // MARK: byte fast paths

    @inline(__always)
    public func matchesFolded(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        TextMatcher.contains(bytes, foldedPattern)
    }

    @inline(__always)
    public func matchesRaw(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        TextMatcher.contains(bytes, rawPattern)
    }

    @inline(__always)
    static func contains(_ hay: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        if needle.isEmpty { return true }
        if hay.count < needle.count { return false }
        return needle.withUnsafeBufferPointer { n in
            memmem(hay.baseAddress, hay.count, n.baseAddress, n.count) != nil
        }
    }

    // MARK: general path

    public func matches(_ s: String) -> Bool {
        switch strategy {
        case .empty: return compileError == nil
        case .plainFolded:
            let f = Array(ItemStore.fold(s).utf8)
            return f.withUnsafeBufferPointer { matchesFolded($0) }
        case .plainCase:
            let r = Array(s.utf8)
            return r.withUnsafeBufferPointer { matchesRaw($0) }
        case .plainCaseOnly, .complex:
            return complexMatch(s) != nil
        case .wildcard:
            guard let w = wildcard else { return false }
            let subject = mode.matchDiacritics ? s : TextMatcher.foldDiacritics(s)
            if mode.whole || mode.wholeFilenameForWildcards { return w.matches(subject) }
            return w.matchesSubstring(subject)
        case .regex:
            guard let re = regexObj else { return false }
            let subject = mode.matchDiacritics ? s : s.folding(options: [.diacriticInsensitive], locale: nil)
            return re.firstMatch(in: subject, options: [], range: NSRange(subject.startIndex..., in: subject)) != nil
        case .soundex:
            return Soundex.matches(pattern: pattern, text: s)
        case .pinyin:
            let p = pattern.lowercased()
            switch mode.pinyin {
            case .quan: return Pinyin.quan(s).contains(p)
            case .jian: return Pinyin.jian(s).contains(p)
            case .both, .off: return Pinyin.quan(s).contains(p) || Pinyin.jian(s).contains(p)
            }
        }
    }

    /// Match ranges for highlighting (in the original string). Empty when no match.
    public func ranges(in s: String) -> [Range<String.Index>] {
        switch strategy {
        case .empty, .soundex, .pinyin: return []
        case .regex:
            guard let re = regexObj else { return [] }
            let ms = mode.matchDiacritics ? s : s.folding(options: [.diacriticInsensitive], locale: nil)
            guard ms.utf16.count == s.utf16.count else { return [] }
            let all = re.matches(in: ms, options: [], range: NSRange(ms.startIndex..., in: ms))
            return (mode.ungreedy || true ? all : Array(all.prefix(1))).compactMap { Range($0.range, in: s) }
        case .wildcard:
            return matches(s) ? [s.startIndex..<s.endIndex] : []
        case .plainFolded, .plainCase, .plainCaseOnly, .complex:
            var out: [Range<String.Index>] = []
            var searchRange = s.startIndex..<s.endIndex
            var opts: String.CompareOptions = []
            if !mode.matchCase { opts.insert(.caseInsensitive) }
            if !mode.matchDiacritics { opts.insert(.diacriticInsensitive) }
            let p = normalizedPattern.isEmpty ? pattern : (strategy == .complex && (mode.ignorePunctuation || mode.ignoreWhitespace) ? pattern : pattern)
            guard !p.isEmpty else { return [] }
            if mode.ignorePunctuation || mode.ignoreWhitespace {
                // approximate: highlight first occurrence of the first alphanumeric run
                let first = String(p.prefix { $0.isLetter || $0.isNumber })
                if first.isEmpty { return [] }
                if let r = s.range(of: first, options: opts) { return [r] }
                return []
            }
            while let r = s.range(of: p, options: opts, range: searchRange) {
                if accept(range: r, in: s) { out.append(r) }
                if r.upperBound >= s.endIndex { break }
                searchRange = r.upperBound..<s.endIndex
                if out.count > 64 { break }
            }
            return out
        }
    }

    // MARK: complex

    private func complexMatch(_ s: String) -> Range<String.Index>? {
        var subject = s
        var p = pattern
        if mode.ignorePunctuation || mode.ignoreWhitespace {
            subject = TextMatcher.normalize(s, mode: mode)
            p = normalizedPattern
        }
        var opts: String.CompareOptions = []
        if !mode.matchCase { opts.insert(.caseInsensitive) }
        if !mode.matchDiacritics { opts.insert(.diacriticInsensitive) }
        if p.isEmpty { return subject.startIndex..<subject.startIndex }
        if mode.whole {
            return subject.compare(p, options: opts) == .orderedSame ? subject.startIndex..<subject.endIndex : nil
        }
        if mode.startWith && mode.endWith {
            return subject.compare(p, options: opts) == .orderedSame ? subject.startIndex..<subject.endIndex : nil
        }
        if mode.startWith {
            guard let r = subject.range(of: p, options: opts.union(.anchored)) else { return nil }
            return accept(range: r, in: subject) ? r : nil
        }
        if mode.endWith {
            guard let r = subject.range(of: p, options: opts.union([.anchored, .backwards])) else { return nil }
            return accept(range: r, in: subject) ? r : nil
        }
        var searchRange = subject.startIndex..<subject.endIndex
        while let r = subject.range(of: p, options: opts, range: searchRange) {
            if accept(range: r, in: subject) { return r }
            guard r.lowerBound < subject.endIndex else { break }
            searchRange = subject.index(after: r.lowerBound)..<subject.endIndex
        }
        return nil
    }

    /// Word-boundary checks for whole-word / prefix / suffix.
    private func accept(range r: Range<String.Index>, in s: String) -> Bool {
        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        let startOK: Bool = {
            guard mode.wholeWords || mode.prefix else { return true }
            if r.lowerBound == s.startIndex { return true }
            let before = s[s.index(before: r.lowerBound)]
            let first = s[r.lowerBound]
            return !(isWordChar(before) && isWordChar(first))
        }()
        let endOK: Bool = {
            guard mode.wholeWords || mode.suffix else { return true }
            if r.upperBound == s.endIndex { return true }
            if r.isEmpty { return true }
            let after = s[r.upperBound]
            let last = s[s.index(before: r.upperBound)]
            return !(isWordChar(after) && isWordChar(last))
        }()
        return startOK && endOK
    }

    static func foldDiacritics(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil) }

    static func normalize(_ s: String, mode: MatchMode) -> String {
        guard mode.ignorePunctuation || mode.ignoreWhitespace else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            if mode.ignoreWhitespace && c.isWhitespace { continue }
            if mode.ignorePunctuation && (c.isPunctuation || c.isSymbol) { continue }
            out.append(c)
        }
        return out
    }

    /// Converts greedy quantifiers to lazy ones (`ungreedy:`).
    static func makeUngreedy(_ src: String) -> String {
        var out = ""
        var escaped = false
        var inClass = false
        let chars = Array(src)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            out.append(c)
            if escaped { escaped = false; i += 1; continue }
            if c == "\\" { escaped = true; i += 1; continue }
            if inClass { if c == "]" { inClass = false }; i += 1; continue }
            if c == "[" { inClass = true; i += 1; continue }
            if c == "*" || c == "+" || c == "?" || c == "}" {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if next == "?" { out.append("?"); i += 2; continue }  // already lazy
                if next == "+" { i += 2; out.append("+"); continue }  // possessive
                out.append("?")
            }
            i += 1
        }
        return out
    }
}
