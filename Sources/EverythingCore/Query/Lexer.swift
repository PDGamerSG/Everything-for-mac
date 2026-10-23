import Foundation

/// Tokenizer for Everything search text.
///
/// Produces operators (`|`, `!`, `<`, `>`), whitespace separators and word tokens. Word tokens keep
/// a per-character "literal" flag so quoted text and character entities never act as operators.
struct Lexer {
    struct Char: Equatable {
        var scalar: Unicode.Scalar
        var literal: Bool          // from quotes or entity: never an operator / wildcard-in-quotes
        var position: Int          // index in original (unicode scalar offset)
    }

    enum Token: Equatable {
        case word([Char], start: Int, end: Int, quoted: Bool)
        case or(Int)
        case not(Int)
        case open(Int)
        case close(Int)
        case space
    }

    static let entities: [String: Unicode.Scalar] = [
        "sp": " ", "vert": "|", "excl": "!", "lt": "<", "gt": ">", "quot": "\"", "amp": "&", "colon": ":", "bsol": "\\",
        "ast": "*", "quest": "?", "lpar": "(", "rpar": ")", "lsqb": "[", "rsqb": "]", "num": "#", "dollar": "$", "circ": "^",
        "lcub": "{", "rcub": "}", "semi": ";", "nbsp": "\u{A0}",
    ]

    static func tokenize(_ input: String) -> [Token] {
        let s = Array(input.unicodeScalars)
        var tokens: [Token] = []
        var i = 0
        var word: [Char] = []
        var wordStart = 0
        var inQuotes = false
        var quotedWord = false

        func flushWord(end: Int) {
            if !word.isEmpty || quotedWord { tokens.append(.word(word, start: wordStart, end: end, quoted: quotedWord)); word = []; quotedWord = false }
        }

        while i < s.count {
            let c = s[i]
            if inQuotes {
                if c == "\"" {
                    // doubled quote inside quotes = literal quote
                    if i + 1 < s.count && s[i + 1] == "\"" { word.append(Char(scalar: "\"", literal: true, position: i)); i += 2; continue }
                    inQuotes = false; i += 1; continue
                }
                word.append(Char(scalar: c, literal: true, position: i)); i += 1; continue
            }
            switch c {
            case "\"":
                if word.isEmpty && !quotedWord { wordStart = i }
                inQuotes = true
                quotedWord = true
                i += 1
            case " ", "\t", "\n", "\r":
                flushWord(end: i)
                if tokens.last != .space { tokens.append(.space) }
                i += 1
            case "|":
                flushWord(end: i); tokens.append(.or(i)); i += 1
            case "!":
                if word.isEmpty { tokens.append(.not(i)) } else { word.append(Char(scalar: c, literal: false, position: i)) }
                i += 1
            case "<", ">":
                // Comparison operators directly after `:`, `=`, `!`, `<`, `>` are part of the word (size:>1gb, dm:<=2022);
                // otherwise angle brackets group terms.
                if let last = word.last, !last.literal, [":", "=", "!", "<", ">"].contains(last.scalar),
                   !(c == "<" && last.scalar == ":" && Lexer.lastSegmentIsModifier(word)) {
                    word.append(Char(scalar: c, literal: false, position: i))
                } else {
                    flushWord(end: i)
                    tokens.append(c == "<" ? .open(i) : .close(i))
                }
                i += 1
            case "&":
                // character entity &name: or &#n: or &#xn:
                var j = i + 1
                var name = ""
                while j < s.count, s[j] != ":", j - i < 12 { name.unicodeScalars.append(s[j]); j += 1 }
                if j < s.count, s[j] == ":", let decoded = Lexer.decodeEntity(name) {
                    if word.isEmpty { wordStart = i }
                    word.append(Char(scalar: decoded, literal: true, position: i))
                    i = j + 1
                } else {
                    if word.isEmpty { wordStart = i }
                    word.append(Char(scalar: c, literal: false, position: i)); i += 1
                }
            default:
                if word.isEmpty { wordStart = i }
                word.append(Char(scalar: c, literal: false, position: i)); i += 1
            }
        }
        flushWord(end: s.count)
        return tokens
    }

    /// True when the text before the trailing ':' of `word` is a modifier chain (e.g. `case:` or `nocase:ww:`).
    static func lastSegmentIsModifier(_ word: [Char]) -> Bool {
        var segs: [String] = []
        var cur = ""
        for c in word.dropLast() { if c.scalar == ":" && !c.literal { segs.append(cur); cur = "" } else { cur.unicodeScalars.append(c.scalar) } }
        segs.append(cur)
        guard let last = segs.last, !last.isEmpty else { return false }
        var n = QueryParser.canonical(last)
        if n.hasPrefix("?") { n.removeFirst() }
        if n.hasPrefix("::") { n.removeFirst(2) }
        if ModifierSet.modifierNames.contains(n) { return true }
        if n.hasPrefix("no"), ModifierSet.modifierNames.contains(String(n.dropFirst(2))) { return true }
        return false
    }

    /// `regex:` consumes `|`: `regex:^a(b|c)$` is one term, so re-join word/or/word runs that follow a regex prefix.
    static func mergeRegexAlternation(_ tokens: [Token]) -> [Token] {
        var out: [Token] = []
        var i = 0
        while i < tokens.count {
            guard case .word(var chars, let start, var end, let quoted) = tokens[i], wordHasRegexPrefix(chars) else { out.append(tokens[i]); i += 1; continue }
            var j = i + 1
            while j + 1 < tokens.count, case .or(let p) = tokens[j], case .word(let more, _, let e2, _) = tokens[j + 1] {
                chars.append(Char(scalar: "|", literal: true, position: p))
                chars.append(contentsOf: more)
                end = e2
                j += 2
            }
            // a trailing `|` right after the word (e.g. `regex:a|`) is also literal
            if j < tokens.count, case .or(let p) = tokens[j] { chars.append(Char(scalar: "|", literal: true, position: p)); end = p + 1; j += 1 }
            out.append(.word(chars, start: start, end: end, quoted: quoted))
            i = j
        }
        return out
    }

    static func wordHasRegexPrefix(_ chars: [Char]) -> Bool {
        var cur = ""
        for c in chars {
            if c.scalar == ":" && !c.literal {
                var n = QueryParser.canonical(cur)
                if n.hasPrefix("?") { n.removeFirst() }
                if n.hasSuffix("*") { n.removeLast() }
                if n == "regex" || n == "noregex" { return n == "regex" }
                cur = ""
            } else if c.literal { return false } else { cur.unicodeScalars.append(c.scalar) }
        }
        return false
    }

    static func decodeEntity(_ name: String) -> Unicode.Scalar? {
        if name.hasPrefix("#x") || name.hasPrefix("#X") { return UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init) }
        if name.hasPrefix("#") { return UInt32(name.dropFirst(1)).flatMap(Unicode.Scalar.init) }
        return entities[name.lowercased()]
    }
}
