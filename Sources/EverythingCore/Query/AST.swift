import Foundation

/// Pinyin matching modes for Chinese text.
public enum PinyinMode: Equatable, Hashable, Sendable { case off, quan, jian, both }

/// Per-term match modifiers. `nil` means "use the window/default setting".
public struct ModifierSet: Equatable, Hashable, Sendable {
    public var matchCase: Bool? = nil
    public var diacritics: Bool? = nil
    public var wholeWords: Bool? = nil
    public var path: Bool? = nil
    public var prefix: Bool? = nil
    public var suffix: Bool? = nil
    public var ignorePunctuation: Bool? = nil
    public var ignoreWhitespace: Bool? = nil
    public var regex: Bool? = nil
    public var wildcards: Bool? = nil        // nil default (filename wildcards on), true = extended, false = off
    public var whole = false                 // whole:/wfn:/entire:
    public var startWith = false             // ^:
    public var endWith = false               // $:
    public var fileOnly = false
    public var folderOnly = false
    public var len = false
    public var toNumber = false
    public var toInteger = false
    public var toString = false
    public var hexToNumber = false
    public var soundex = false
    public var pinyin: PinyinMode? = nil
    public var allStrings = false
    public var multiString: Bool? = nil
    public var binary = false
    public var hex = false
    public var eachLine = false
    public var dotAll = false
    public var multiLine = false
    public var ungreedy = false
    public var global = false
    public var noHighlight = false
    public var fromDisk = false
    public var notIndexed = false
    public var noReorder = false
    public var searchCurrentResults: Bool? = nil
    public var resultOmissions: Bool? = nil
    public var tempResultOmissions: Bool? = nil
    public var starAll = false
    public var metric: Bool? = nil
    public var andFilter: Bool? = nil
    public var menuBreak = false
    public var menuSeparator = false
    public var noSubstitute = false
    public var noFastRegex = false
    public var noNot = false
    public var builtin = false               // ::
    public var contentEncoding: String? = nil // ansi, utf8, utf16, utf16be, ascii
    public var andPrecedence: Bool? = nil

    public init() {}

    /// Overlays `other` on top of self (explicit values in other win).
    public func merged(with other: ModifierSet) -> ModifierSet {
        var m = self
        if let v = other.matchCase { m.matchCase = v }
        if let v = other.diacritics { m.diacritics = v }
        if let v = other.wholeWords { m.wholeWords = v }
        if let v = other.path { m.path = v }
        if let v = other.prefix { m.prefix = v }
        if let v = other.suffix { m.suffix = v }
        if let v = other.ignorePunctuation { m.ignorePunctuation = v }
        if let v = other.ignoreWhitespace { m.ignoreWhitespace = v }
        if let v = other.regex { m.regex = v }
        if let v = other.wildcards { m.wildcards = v }
        m.whole = m.whole || other.whole
        m.startWith = m.startWith || other.startWith
        m.endWith = m.endWith || other.endWith
        m.fileOnly = m.fileOnly || other.fileOnly
        m.folderOnly = m.folderOnly || other.folderOnly
        m.len = m.len || other.len
        m.toNumber = m.toNumber || other.toNumber
        m.toInteger = m.toInteger || other.toInteger
        m.toString = m.toString || other.toString
        m.hexToNumber = m.hexToNumber || other.hexToNumber
        m.soundex = m.soundex || other.soundex
        if let v = other.pinyin { m.pinyin = v }
        m.allStrings = m.allStrings || other.allStrings
        if let v = other.multiString { m.multiString = v }
        m.binary = m.binary || other.binary
        m.hex = m.hex || other.hex
        m.eachLine = m.eachLine || other.eachLine
        m.dotAll = m.dotAll || other.dotAll
        m.multiLine = m.multiLine || other.multiLine
        m.ungreedy = m.ungreedy || other.ungreedy
        m.global = m.global || other.global
        m.noHighlight = m.noHighlight || other.noHighlight
        m.fromDisk = m.fromDisk || other.fromDisk
        m.notIndexed = m.notIndexed || other.notIndexed
        m.noReorder = m.noReorder || other.noReorder
        if let v = other.searchCurrentResults { m.searchCurrentResults = v }
        if let v = other.resultOmissions { m.resultOmissions = v }
        if let v = other.tempResultOmissions { m.tempResultOmissions = v }
        m.starAll = m.starAll || other.starAll
        if let v = other.metric { m.metric = v }
        if let v = other.andFilter { m.andFilter = v }
        m.menuBreak = m.menuBreak || other.menuBreak
        m.menuSeparator = m.menuSeparator || other.menuSeparator
        m.noSubstitute = m.noSubstitute || other.noSubstitute
        m.noFastRegex = m.noFastRegex || other.noFastRegex
        m.noNot = m.noNot || other.noNot
        m.builtin = m.builtin || other.builtin
        if let v = other.contentEncoding { m.contentEncoding = v }
        if let v = other.andPrecedence { m.andPrecedence = v }
        return m
    }

    /// Applies a canonical modifier name (lowercase, dashes removed, `no` prefix handled by caller via `enabled`).
    /// Returns false if the name is not a modifier.
    @discardableResult
    public mutating func apply(_ canonical: String, enabled: Bool) -> Bool {
        switch canonical {
        case "case": matchCase = enabled
        case "diacritics", "diac": diacritics = enabled
        case "wholewords", "wholeword", "ww": wholeWords = enabled
        case "path", "\\": path = enabled
        case "prefix": prefix = enabled
        case "suffix": suffix = enabled
        case "ignorepunctuation", "ignorepunc", "nopunc": ignorePunctuation = canonical == "nopunc" ? true : enabled
        case "ignorewhitespace", "ignorews", "nows": ignoreWhitespace = canonical == "nows" ? true : enabled
        case "regex": regex = enabled
        case "wildcards", "wildcard": wildcards = enabled
        case "whole", "wholefilename", "wfn", "entire": whole = enabled
        case "startwith", "startswith", "^": startWith = enabled
        case "endwith", "endswith", "$": endWith = enabled
        case "file", "files": fileOnly = enabled
        case "folder", "folders": folderOnly = enabled
        case "len", "length-of": len = enabled
        case "tonumber", "#": toNumber = enabled
        case "tointeger": toInteger = enabled
        case "tostring": toString = enabled
        case "hextonumber": hexToNumber = enabled
        case "soundex": soundex = enabled
        case "pinyin", "py": pinyin = enabled ? .both : .off
        case "pinyinjian", "pyj": pinyin = enabled ? .jian : .off
        case "pinyinquan", "pyq": pinyin = enabled ? .quan : .off
        case "allstrings": allStrings = enabled
        case "multistring": multiString = enabled
        case "binary": binary = enabled
        case "hex": hex = enabled
        case "eachline": eachLine = enabled
        case "dotall": dotAll = enabled
        case "multiline": multiLine = enabled
        case "ungreedy": ungreedy = enabled
        case "global": global = enabled
        case "highlight": noHighlight = !enabled
        case "fromdisk": fromDisk = enabled
        case "notindexed": notIndexed = enabled
        case "reorder": noReorder = !enabled
        case "searchcurrentresults": searchCurrentResults = enabled
        case "enableresultomissions": resultOmissions = true
        case "disableresultomissions": resultOmissions = false
        case "enabletempresultomissions", "enabletemporaryresultomissions": tempResultOmissions = true
        case "disabletempresultomissions", "disabletemporaryresultomissions": tempResultOmissions = false
        case "starall": starAll = enabled
        case "metric": metric = enabled
        case "andfilter": andFilter = enabled
        case "orfilter": andFilter = !enabled
        case "menubreak": menuBreak = enabled
        case "menuseparator": menuSeparator = enabled
        case "substitute": noSubstitute = !enabled
        case "fastregex": noFastRegex = !enabled
        case "!": noNot = !enabled
        case "andprecedence": andPrecedence = enabled
        case "orprecedence": andPrecedence = !enabled
        case "ansi", "ascii", "utf8", "utf16", "utf16le", "utf16be": contentEncoding = canonical
        default: return false
        }
        return true
    }

    public static let modifierNames: Set<String> = [
        "case", "diacritics", "diac", "wholewords", "wholeword", "ww", "path", "\\", "prefix", "suffix", "ignorepunctuation", "ignorepunc", "nopunc",
        "ignorewhitespace", "ignorews", "nows", "regex", "wildcards", "wildcard", "whole", "wholefilename", "wfn", "entire", "startwith", "startswith", "^",
        "endwith", "endswith", "$", "file", "files", "folder", "folders", "len", "tonumber", "#", "tointeger", "tostring", "hextonumber", "soundex",
        "pinyin", "py", "pinyinjian", "pyj", "pinyinquan", "pyq", "allstrings", "multistring", "binary", "hex", "eachline", "dotall", "multiline",
        "ungreedy", "global", "highlight", "fromdisk", "notindexed", "reorder", "searchcurrentresults", "enableresultomissions", "disableresultomissions",
        "enabletempresultomissions", "enabletemporaryresultomissions", "disabletempresultomissions", "disabletemporaryresultomissions", "starall", "metric",
        "andfilter", "orfilter", "menubreak", "menuseparator", "substitute", "fastregex", "!", "andprecedence", "orprecedence",
        "ansi", "ascii", "utf8", "utf16", "utf16le", "utf16be",
    ]
}

/// A single search term: `[modifiers:]...[function:]value`.
public struct Term: Equatable, Hashable, Sendable {
    public var modifiers: ModifierSet
    /// Canonical function name (lowercase, no dashes), or nil for plain text.
    public var function: String?
    /// Raw value with quotes removed and entities decoded.
    public var value: String
    public var quoted: Bool
    /// The value was the literal remainder of the search (`name*:`).
    public var literalRest: Bool
    /// Character positions in the original search string (for highlighting / editing).
    public var range: Range<Int>

    public init(modifiers: ModifierSet = ModifierSet(), function: String? = nil, value: String, quoted: Bool = false, literalRest: Bool = false, range: Range<Int> = 0..<0) {
        self.modifiers = modifiers; self.function = function; self.value = value; self.quoted = quoted; self.literalRest = literalRest; self.range = range
    }
}

public indirect enum QueryNode: Equatable, Hashable, Sendable {
    case and([QueryNode])
    case or([QueryNode])
    case not(QueryNode)
    case term(Term)
    case empty

    public var isEmpty: Bool {
        switch self {
        case .empty: return true
        case .and(let a), .or(let a): return a.allSatisfy { $0.isEmpty }
        case .not(let n): return n.isEmpty
        case .term: return false
        }
    }

    /// All terms in evaluation order.
    public var terms: [Term] {
        switch self {
        case .empty: return []
        case .term(let t): return [t]
        case .not(let n): return n.terms
        case .and(let a), .or(let a): return a.flatMap { $0.terms }
        }
    }

    public func map(_ f: (Term) -> QueryNode) -> QueryNode {
        switch self {
        case .empty: return .empty
        case .term(let t): return f(t)
        case .not(let n): return .not(n.map(f))
        case .and(let a): return .and(a.map { $0.map(f) })
        case .or(let a): return .or(a.map { $0.map(f) })
        }
    }

    /// Flattens nested and/or and drops empties.
    public func simplified() -> QueryNode {
        switch self {
        case .empty, .term: return self
        case .not(let n):
            let s = n.simplified()
            return s.isEmpty ? .empty : .not(s)
        case .and(let a):
            var out: [QueryNode] = []
            for n in a {
                let s = n.simplified()
                if s.isEmpty { continue }
                if case .and(let inner) = s { out.append(contentsOf: inner) } else { out.append(s) }
            }
            return out.isEmpty ? .empty : (out.count == 1 ? out[0] : .and(out))
        case .or(let a):
            var out: [QueryNode] = []
            for n in a {
                let s = n.simplified()
                if s.isEmpty { continue }
                if case .or(let inner) = s { out.append(contentsOf: inner) } else { out.append(s) }
            }
            return out.isEmpty ? .empty : (out.count == 1 ? out[0] : .or(out))
        }
    }
}

/// Search-level directives extracted from the query (they do not filter items).
public enum UIDirective: Equatable, Hashable, Sendable {
    case sort([String])                     // sort:name-descending;size
    case sortAscending, sortDescending
    case sortMix(Bool)
    case foldersFirst(Bool?)                 // nil = ascending/descending variants handled by sort
    case count(Int)
    case maxThreads(Int)
    case columns([String]), addColumns([String]), removeColumns([String])
    case layout([String]), addLayout([String]), removeLayout([String])
    case preview(Bool), thumbnails(Int?), details
    case foldersSidebar(Bool), filtersSidebar(Bool), bookmarksSidebar(Bool)
    case alternateRowColor(Bool), onTop(Bool)
    case dupe([String]), unique([String]), distinct([String]), distinctSort([String]), dupeCount(Int), dupeMin(Int), dupeMax(Int), dupeFrom(String)
    case newSearch, andSearch, newResultsOnly, noNewResults
    case nop, nothing, everything
    case bookmark(String), filter(String)
    case addColumn(index: Int, spec: String)
    case includeFileList(String)
    case fileListSlot(Int, [String])
}

public struct ParsedQuery: Equatable, Sendable {
    public var root: QueryNode
    public var directives: [UIDirective]
    public var globalModifiers: ModifierSet
    public var original: String
    /// Plain text terms (for the autocompleter and highlighter).
    public var hasRegexTerms: Bool { root.terms.contains { $0.modifiers.regex == true } }

    public init(root: QueryNode, directives: [UIDirective] = [], globalModifiers: ModifierSet = ModifierSet(), original: String = "") {
        self.root = root; self.directives = directives; self.globalModifiers = globalModifiers; self.original = original
    }
}

public struct ParseOptions: Equatable, Sendable {
    public var orPrecedence = true            // OR evaluated before AND (Everything default)
    public var literalOperators = false       // AND / OR / NOT words
    public var replaceBackslashes = true      // Windows paths → POSIX
    public var replaceForwardSlashes = false
    public var defaults = MatchDefaults()
    /// Names that resolve to macros (filters); checked before functions.
    public var macroNames: Set<String> = []
    public init() {}
}
