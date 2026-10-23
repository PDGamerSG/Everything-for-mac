import Testing
import Foundation
@testable import EverythingCore

@Suite struct MatcherTests {
    func mode(_ edit: (inout MatchMode) -> Void = { _ in }) -> MatchMode { var m = MatchMode(); edit(&m); return m }
    func m(_ p: String, _ s: String, _ edit: (inout MatchMode) -> Void = { _ in }) -> Bool { TextMatcher(pattern: p, mode: mode(edit)).matches(s) }

    @Test func plainCaseDiacritics() {
        #expect(m("resume", "My Résumé.PDF"))
        #expect(m("RÉSUMÉ", "my resume.pdf"))
        #expect(!m("resume", "My Résumé.PDF") { $0.matchDiacritics = true })
        #expect(m("Résumé", "My Résumé.PDF") { $0.matchDiacritics = true })
        #expect(!m("resume", "My Resume.PDF") { $0.matchCase = true })
        #expect(m("Resume", "My Resume.PDF") { $0.matchCase = true })
        #expect(m("resume", "My Résumé.PDF") { $0.matchCase = false; $0.matchDiacritics = false })
        #expect(m("", "anything"))
        #expect(TextMatcher(pattern: "abc", mode: mode()).strategy == .plainFolded)
        #expect(TextMatcher(pattern: "abc", mode: mode { $0.matchCase = true; $0.matchDiacritics = true }).strategy == .plainCase)
    }

    @Test func foldedBytePath() {
        let store = ItemStore()
        let a = store.add(ItemRecord(name: "Résumé.PDF", parent: invalidItem))
        let b = store.add(ItemRecord(name: "README.md", parent: invalidItem))
        let t = TextMatcher(pattern: "resume", mode: mode())
        #expect(store.withUnicodeFoldedBytes(a) { t.matchesFolded($0) })
        #expect(!store.withUnicodeFoldedBytes(b) { t.matchesFolded($0) })
        let r = TextMatcher(pattern: "readme", mode: mode())
        #expect(store.withUnicodeFoldedBytes(b) { r.matchesFolded($0) })
        let c = TextMatcher(pattern: "README", mode: mode { $0.matchCase = true; $0.matchDiacritics = true })
        #expect(store.withNameBytes(b) { c.matchesRaw($0) })
        #expect(!store.withNameBytes(a) { c.matchesRaw($0) })
    }

    @Test func wholeWordPrefixSuffix() {
        #expect(m("cat", "my cat.txt") { $0.wholeWords = true })
        #expect(!m("cat", "cats.txt") { $0.wholeWords = true })
        #expect(!m("cat", "concat.txt") { $0.wholeWords = true })
        #expect(m("cat", "con-cat.txt") { $0.wholeWords = true })
        #expect(m("ab", "abc def") { $0.prefix = true })
        #expect(!m("ab", "xab def") { $0.prefix = true })
        #expect(m("ef", "abc def") { $0.suffix = true })
        #expect(!m("de", "abc def") { $0.suffix = true })
        #expect(m("file", "file.txt") { $0.wholeWords = true })
        #expect(m("txt", "file.txt") { $0.wholeWords = true })
    }

    @Test func ignorePunctuationWhitespace() {
        #expect(m("spiderman", "Spider-Man.mkv") { $0.ignorePunctuation = true })
        #expect(!m("spiderman", "Spider-Man.mkv"))
        #expect(m("spiderman", "Spider Man.mkv") { $0.ignoreWhitespace = true })
        #expect(m("spider man", "spiderman.mkv") { $0.ignoreWhitespace = true })
        #expect(m("spider-man", "Spider Man.mkv") { $0.ignoreWhitespace = true; $0.ignorePunctuation = true })
    }

    @Test func wholeStartEnd() {
        #expect(m("file.txt", "FILE.TXT") { $0.whole = true })
        #expect(!m("file", "file.txt") { $0.whole = true })
        #expect(m("fil", "file.txt") { $0.startWith = true })
        #expect(!m("ile", "file.txt") { $0.startWith = true })
        #expect(m(".txt", "file.txt") { $0.endWith = true })
        #expect(!m("fil", "file.txt") { $0.endWith = true })
    }

    @Test func wildcards() {
        #expect(m("*.txt", "notes.txt"))
        #expect(!m("*.txt", "notes.txt.bak"))
        #expect(m("*.txt", "notes.txt.bak") { $0.wholeFilenameForWildcards = false })
        #expect(m("n?tes.*", "Notes.TXT"))
        #expect(!m("*.txt", "dir/notes.txt"))
        #expect(m("**.txt", "dir/notes.txt"))
        #expect(m("*.txt", "dir/notes.txt") { $0.starAll = true })
        #expect(m("file#.txt", "file1.txt") { $0.wildcards = .extended })
        #expect(!m("file#.txt", "filex.txt") { $0.wildcards = .extended })
        #expect(m("file[a-c].txt", "fileB.txt") { $0.wildcards = .extended })
        #expect(!m("file[!a-c].txt", "fileB.txt") { $0.wildcards = .extended })
        #expect(m("file\\*.txt", "file*.txt") { $0.wildcards = .extended })
        #expect(!m("file\\*.txt", "filex.txt") { $0.wildcards = .extended })
        #expect(m("*.txt", "x*.txt") { $0.wildcards = .off })      // literal star when wildcards disabled
        #expect(!m("*.txt", "notes.txt") { $0.wildcards = .off })
        #expect(m("*ésumé*", "Résumé.pdf"))
        #expect(m("*esume*", "Résumé.pdf"))
    }

    @Test func regex() {
        #expect(m("^foo.*\\.txt$", "foobar.txt") { $0.regex = true })
        #expect(!m("^foo.*\\.txt$", "xfoobar.txt") { $0.regex = true })
        #expect(m("FOO", "foobar.txt") { $0.regex = true })
        #expect(!m("FOO", "foobar.txt") { $0.regex = true; $0.matchCase = true })
        #expect(m("a.b", "a\nb") { $0.regex = true; $0.dotAll = true })
        #expect(!m("a.b", "a\nb") { $0.regex = true })
        #expect(m("^b$", "a\nb") { $0.regex = true; $0.multiLine = true })
        #expect(m("\\d{3}", "img123.jpg") { $0.regex = true })
        let bad = TextMatcher(pattern: "(", mode: mode { $0.regex = true })
        #expect(bad.compileError != nil)
        #expect(!bad.matches("("))
        #expect(TextMatcher.makeUngreedy("a.*b+c?") == "a.*?b+?c??")
        #expect(TextMatcher.makeUngreedy("a.*?b") == "a.*?b")
        #expect(TextMatcher.makeUngreedy("[*+]x") == "[*+]x")
        #expect(m("cat", "concat.txt") { $0.regex = true })
        #expect(!m("cat", "concat.txt") { $0.regex = true; $0.wholeWords = true })
    }

    @Test func soundexAndPinyin() {
        #expect(Soundex.encode("Robert") == "R163")
        #expect(Soundex.encode("Rupert") == "R163")
        #expect(Soundex.encode("Tymczak") == "T522")
        #expect(Soundex.encode("Pfister") == "P236")
        #expect(m("robert", "Rupert Smith.doc") { $0.soundex = true })
        #expect(!m("robert", "Alice.doc") { $0.soundex = true })
        #expect(Pinyin.quan("中文") == "zhongwen")
        #expect(Pinyin.jian("中文") == "zw")
        #expect(m("zhongwen", "中文文件.txt") { $0.pinyin = .both })
        #expect(m("zw", "中文文件.txt") { $0.pinyin = .both })
        #expect(m("zw", "中文文件.txt") { $0.pinyin = .jian })
        #expect(!m("zw", "中文文件.txt") { $0.pinyin = .quan })
        #expect(m("中文", "中文文件.txt") { $0.pinyin = .both }) // Chinese pattern uses plain matching
    }

    @Test func highlightRanges() {
        let t = TextMatcher(pattern: "ab", mode: mode())
        let s = "xAByab"
        let rs = t.ranges(in: s)
        #expect(rs.count == 2)
        #expect(rs.map { String(s[$0]) } == ["AB", "ab"])
        let w = TextMatcher(pattern: "cat", mode: mode { $0.wholeWords = true })
        #expect(w.ranges(in: "cats cat").count == 1)
        let r = TextMatcher(pattern: "a+", mode: mode { $0.regex = true })
        #expect(r.ranges(in: "baab aa").count == 2)
        let d = TextMatcher(pattern: "resume", mode: mode())
        #expect(d.ranges(in: "Résumé.pdf").map { String("Résumé.pdf"[$0]) } == ["Résumé"])
    }

    @Test func matchModeFromDefaultsAndModifiers() {
        var d = MatchDefaults(); d.matchCase = true; d.regex = true
        var mods = ModifierSet(); mods.matchCase = false; mods.wholeWords = true
        let mm = MatchMode(defaults: d, modifiers: mods)
        #expect(mm.matchCase == false)
        #expect(mm.regex == true)
        #expect(mm.wholeWords == true)
        var w = ModifierSet(); w.wildcards = false
        #expect(MatchMode(defaults: MatchDefaults(), modifiers: w).wildcards == .off)
        w.wildcards = true
        #expect(MatchMode(defaults: MatchDefaults(), modifiers: w).wildcards == .extended)
    }
}
