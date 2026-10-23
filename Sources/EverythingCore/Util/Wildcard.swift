import Foundation

/// Everything-style wildcard matching.
///
/// Basic: `*` (zero or more chars, not `/`), `**` (zero or more chars incl. `/`), `?` (one char, not `/`).
/// Extended (`wildcards:` modifier): `#` one digit, `[abc]`/`[a-z]` sets, `[!abc]` negated sets, `\` escapes.
/// `starAll` makes `*` cross path separators.
public struct WildcardPattern: Sendable, Equatable {
    public enum Token: Equatable, Sendable {
        case literal(Unicode.Scalar)
        case anyNoSep       // *
        case anyAll         // **
        case oneNoSep       // ?
        case digit          // #
        case set([ClosedRange<UInt32>], negated: Bool)
    }

    public let tokens: [Token]
    public let caseInsensitive: Bool
    public let source: String

    public init(_ pattern: String, extended: Bool = false, caseInsensitive: Bool = true, starAll: Bool = false) {
        source = pattern
        self.caseInsensitive = caseInsensitive
        var toks: [Token] = []
        let scalars = Array(pattern.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            switch c {
            case "*":
                if i + 1 < scalars.count && scalars[i + 1] == "*" { toks.append(.anyAll); i += 2; continue }
                toks.append(starAll ? .anyAll : .anyNoSep)
            case "?":
                toks.append(.oneNoSep)
            case "#" where extended:
                toks.append(.digit)
            case "\\" where extended && i + 1 < scalars.count:
                i += 1
                toks.append(.literal(WildcardPattern.fold(scalars[i], caseInsensitive)))
            case "[" where extended:
                var j = i + 1
                var negated = false
                if j < scalars.count && (scalars[j] == "!" || scalars[j] == "^") { negated = true; j += 1 }
                var ranges: [ClosedRange<UInt32>] = []
                var closed = false
                while j < scalars.count {
                    if scalars[j] == "]" && !ranges.isEmpty { closed = true; break }
                    var lo = scalars[j]
                    if lo == "\\" && j + 1 < scalars.count { j += 1; lo = scalars[j] }
                    var hi = lo
                    if j + 2 < scalars.count && scalars[j + 1] == "-" && scalars[j + 2] != "]" { hi = scalars[j + 2]; j += 2 }
                    let l = WildcardPattern.fold(lo, caseInsensitive).value, h = WildcardPattern.fold(hi, caseInsensitive).value
                    ranges.append(min(l, h)...max(l, h))
                    if caseInsensitive {
                        // add the other case for ASCII letters
                        let lo2 = WildcardPattern.otherCase(lo).value, hi2 = WildcardPattern.otherCase(hi).value
                        ranges.append(min(lo2, hi2)...max(lo2, hi2))
                    }
                    j += 1
                }
                if closed { toks.append(.set(ranges, negated: negated)); i = j }
                else { toks.append(.literal(WildcardPattern.fold(c, caseInsensitive))) }
            default:
                toks.append(.literal(WildcardPattern.fold(c, caseInsensitive)))
            }
            i += 1
        }
        tokens = toks
    }

    private static func fold(_ s: Unicode.Scalar, _ ci: Bool) -> Unicode.Scalar {
        guard ci else { return s }
        return String(s).lowercased().unicodeScalars.first ?? s
    }

    private static func otherCase(_ s: Unicode.Scalar) -> Unicode.Scalar {
        let up = String(s).uppercased().unicodeScalars.first ?? s
        let lo = String(s).lowercased().unicodeScalars.first ?? s
        return up == s ? lo : up
    }

    public var hasWildcards: Bool {
        tokens.contains { if case .literal = $0 { return false } else { return true } }
    }

    public func matches(_ s: String) -> Bool {
        let scalars = Array(s.unicodeScalars)
        return matchFrom(0, 0, scalars)
    }

    /// Returns true if the pattern matches anywhere as a substring (used when whole-filename matching is off).
    public func matchesSubstring(_ s: String) -> Bool {
        let scalars = Array(s.unicodeScalars)
        if tokens.isEmpty { return true }
        for start in 0...scalars.count where matchPrefix(0, start, scalars) { return true }
        return false
    }

    private func matchPrefix(_ ti: Int, _ si: Int, _ s: [Unicode.Scalar]) -> Bool {
        // like matchFrom but succeeds when tokens are exhausted regardless of remaining input
        if ti == tokens.count { return true }
        switch tokens[ti] {
        case .anyAll:
            var k = si
            while true { if matchPrefix(ti + 1, k, s) { return true }; if k >= s.count { return false }; k += 1 }
        case .anyNoSep:
            var k = si
            while true {
                if matchPrefix(ti + 1, k, s) { return true }
                if k >= s.count || s[k] == "/" { return false }
                k += 1
            }
        default:
            guard si < s.count, single(tokens[ti], s[si]) else { return false }
            return matchPrefix(ti + 1, si + 1, s)
        }
    }

    private func matchFrom(_ ti: Int, _ si: Int, _ s: [Unicode.Scalar]) -> Bool {
        var ti = ti, si = si
        // iterative with backtracking for single star; recursion for nested
        var starTok = -1, starPos = -1
        while si < s.count {
            if ti < tokens.count {
                switch tokens[ti] {
                case .anyAll:
                    starTok = ti; starPos = si; ti += 1; continue
                case .anyNoSep:
                    starTok = ti; starPos = si; ti += 1; continue
                default:
                    if single(tokens[ti], s[si]) { ti += 1; si += 1; continue }
                }
            }
            // mismatch: backtrack to last star
            if starTok >= 0 {
                if case .anyNoSep = tokens[starTok], s[starPos] == "/" { return false }
                starPos += 1
                si = starPos
                ti = starTok + 1
                continue
            }
            return false
        }
        while ti < tokens.count {
            switch tokens[ti] {
            case .anyAll, .anyNoSep: ti += 1
            default: return false
            }
        }
        return true
    }

    private func single(_ t: Token, _ c: Unicode.Scalar) -> Bool {
        let fc = WildcardPattern.fold(c, caseInsensitive)
        switch t {
        case .literal(let l): return l == fc
        case .oneNoSep: return c != "/"
        case .digit: return c.value >= 48 && c.value <= 57
        case .set(let ranges, let negated):
            let hit = ranges.contains { $0.contains(fc.value) || $0.contains(c.value) }
            return hit != negated
        case .anyAll, .anyNoSep: return true
        }
    }

    /// Converts the pattern to an equivalent regular expression source (anchored).
    public func regexSource() -> String {
        var out = "^"
        for t in tokens {
            switch t {
            case .literal(let c): out += NSRegularExpression.escapedPattern(for: String(c))
            case .anyNoSep: out += "[^/]*"
            case .anyAll: out += ".*"
            case .oneNoSep: out += "[^/]"
            case .digit: out += "[0-9]"
            case .set(let ranges, let negated):
                out += negated ? "[^" : "["
                for r in ranges {
                    let lo = Unicode.Scalar(r.lowerBound).map { NSRegularExpression.escapedPattern(for: String($0)) } ?? ""
                    let hi = Unicode.Scalar(r.upperBound).map { NSRegularExpression.escapedPattern(for: String($0)) } ?? ""
                    out += r.lowerBound == r.upperBound ? lo : "\(lo)-\(hi)"
                }
                out += "]"
            }
        }
        return out + "$"
    }
}
