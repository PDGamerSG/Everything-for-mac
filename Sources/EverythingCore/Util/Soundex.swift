import Foundation

/// SQL-style American Soundex (letter + 3 digits). Non A–Z characters are ignored.
public enum Soundex {
    static let codes: [Character: Character] = {
        var m: [Character: Character] = [:]
        for c in "bfpv" { m[c] = "1" }
        for c in "cgjkqsxz" { m[c] = "2" }
        for c in "dt" { m[c] = "3" }
        m["l"] = "4"
        for c in "mn" { m[c] = "5" }
        m["r"] = "6"
        return m
    }()

    public static func encode(_ word: String) -> String {
        let letters = word.lowercased().filter { $0 >= "a" && $0 <= "z" }
        guard let first = letters.first else { return "" }
        var out = String(first).uppercased()
        var last = codes[first]
        for c in letters.dropFirst() {
            let code = codes[c]
            if let code = code, code != last { out.append(code) }
            if c != "h" && c != "w" { last = code }
            if out.count == 4 { break }
        }
        while out.count < 4 { out.append("0") }
        return out
    }

    /// True when any word in `text` has a soundex starting with the soundex of `pattern`.
    public static func matches(pattern: String, text: String) -> Bool {
        let p = encode(pattern)
        guard !p.isEmpty else { return false }
        let words = text.split { !$0.isLetter }
        return words.contains { encode(String($0)).hasPrefix(p) }
    }
}
