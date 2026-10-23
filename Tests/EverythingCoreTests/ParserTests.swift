import Testing
import Foundation
@testable import EverythingCore

@Suite struct ParserTests {
    let parser = QueryParser()

    func terms(_ q: String, options: ParseOptions = ParseOptions()) -> [Term] { QueryParser(options: options).parse(q).root.terms }
    func root(_ q: String, options: ParseOptions = ParseOptions()) -> QueryNode { QueryParser(options: options).parse(q).root }

    func t(_ value: String, _ function: String? = nil, _ mods: ModifierSet = ModifierSet()) -> QueryNode {
        .term(Term(modifiers: mods, function: function, value: value))
    }
    /// Structure only: values and operators.
    func shape(_ n: QueryNode) -> QueryNode {
        n.map { .term(Term(value: $0.value, quoted: false)) }
    }
    /// Compare ignoring ranges/quoted flags.
    func strip(_ n: QueryNode) -> QueryNode {
        n.map { term in var t = term; t.range = 0..<0; t.quoted = false; t.literalRest = false; return .term(t) }
    }

    @Test func andOrNot() {
        #expect(strip(root("abc 123")) == .and([t("abc"), t("123")]))
        #expect(strip(root("abc|123")) == .or([t("abc"), t("123")]))
        #expect(strip(root("abc | 123")) == .or([t("abc"), t("123")]))
        #expect(strip(root("!abc")) == .not(t("abc")))
        #expect(strip(root("a !b")) == .and([t("a"), .not(t("b"))]))
        #expect(strip(root("")) == .empty)
        #expect(strip(root("   ")) == .empty)
    }

    @Test func precedence() {
        // Default: OR before AND → apple AND (banana OR orange)
        #expect(strip(root("apple banana|orange")) == .and([t("apple"), .or([t("banana"), t("orange")])]))
        var o = ParseOptions(); o.orPrecedence = false
        #expect(strip(root("apple banana|orange", options: o)) == .or([.and([t("apple"), t("banana")]), t("orange")]))
        // grouping
        #expect(strip(root("<apple banana>|orange")) == .or([.and([t("apple"), t("banana")]), t("orange")]))
        #expect(strip(root("a <b|c> d")) == .and([t("a"), .or([t("b"), t("c")]), t("d")]))
        #expect(strip(root("!<a b>")) == .not(.and([t("a"), t("b")])))
        // and-precedence modifier
        #expect(shape(root("and-precedence: a b|c")) == .or([.and([t("a"), t("b")]), t("c")]))
    }

    @Test func quotesAndEntities() {
        let q = terms("\"a b\" c")
        #expect(q.count == 2)
        #expect(q[0].value == "a b" && q[0].quoted)
        #expect(q[1].value == "c")
        #expect(terms("\"a|b\"")[0].value == "a|b")
        #expect(terms("&quot:x&quot:")[0].value == "\"x\"")
        #expect(terms("a&sp:b")[0].value == "a b")
        #expect(terms("&vert:")[0].value == "|")
        #expect(terms("&#65:bc")[0].value == "Abc")
        #expect(terms("&#x41:bc")[0].value == "Abc")
        #expect(terms("\"\"")[0].value == "")  // empty quoted term still a term
        #expect(terms("\"\"\"q\"\"\"")[0].value == "\"q\"")
        #expect(terms("a\"b c\"d")[0].value == "ab cd")
    }

    @Test func modifiers() {
        #expect(terms("case:README")[0].modifiers.matchCase == true)
        #expect(terms("nocase:README")[0].modifiers.matchCase == false)
        #expect(terms("no-case:README")[0].modifiers.matchCase == false)
        #expect(terms("ww:cat")[0].modifiers.wholeWords == true)
        #expect(terms("whole-words:cat")[0].modifiers.wholeWords == true)
        #expect(terms("wfn:*.txt")[0].modifiers.whole)
        #expect(terms("regex:^foo.*\\.txt$")[0].modifiers.regex == true)
        #expect(terms("regex:^foo.*\\.txt$")[0].value == "^foo.*\\.txt$")
        #expect(terms("path:abc")[0].modifiers.path == true)
        #expect(terms("path:abc")[0].value == "abc")
        #expect(terms("nopath:abc")[0].modifiers.path == false)
        #expect(terms("\\abc")[0].modifiers.path == true)
        #expect(terms("\\abc")[0].value == "/abc")
        #expect(terms("case:ext:JPG")[0].function == "ext")
        #expect(terms("case:ext:JPG")[0].modifiers.matchCase == true)
        #expect(terms("case:ext:JPG")[0].value == "JPG")
        #expect(terms("^:foo")[0].modifiers.startWith)
        #expect(terms("$:foo")[0].modifiers.endWith)
        #expect(terms("startwith:foo")[0].modifiers.startWith)
        #expect(terms("file:")[0].modifiers.fileOnly)
        #expect(terms("folder:")[0].modifiers.folderOnly)
        #expect(terms("py:zw")[0].modifiers.pinyin == .both)
        #expect(terms("pyj:zw")[0].modifiers.pinyin == .jian)
        #expect(terms("diacritics:cafe")[0].modifiers.diacritics == true)
        #expect(terms("nows:spider man")[0].modifiers.ignoreWhitespace == true)
        #expect(terms("nopunc:spiderman")[0].modifiers.ignorePunctuation == true)
        #expect(terms("len:>5")[0].modifiers.len)
        #expect(terms("#:5")[0].modifiers.toNumber)
        #expect(terms("fromdisk:size:>1mb")[0].modifiers.fromDisk)
    }

    @Test func modifierGroupsAndGlobal() {
        let n = strip(root("case:<Foo Bar> baz"))
        let ts = n.terms
        #expect(ts.count == 3)
        #expect(ts[0].modifiers.matchCase == true && ts[1].modifiers.matchCase == true && ts[2].modifiers.matchCase == nil)
        let g = parser.parse("?case: a b")
        #expect(g.globalModifiers.matchCase == true)
        #expect(g.root.terms.allSatisfy { $0.modifiers.matchCase == true })
        #expect(g.root.terms.count == 2)
    }

    @Test func literalSuffix() {
        let q = parser.parse("regex*:a|b c")
        #expect(q.root.terms.count == 1)
        #expect(q.root.terms[0].value == "a|b c")
        #expect(q.root.terms[0].modifiers.regex == true)
        let c = parser.parse("foo content*:hello world !x")
        #expect(c.root.terms.count == 2)
        #expect(c.root.terms[1].function == "content")
        #expect(c.root.terms[1].value == "hello world !x")
    }

    @Test func functionsAndDashInsensitivity() {
        #expect(terms("ext:cpp;h")[0].function == "ext")
        #expect(terms("ext:cpp;h")[0].value == "cpp;h")
        #expect(terms("size:>1gb")[0].function == "size")
        #expect(terms("size:>1gb")[0].value == ">1gb")
        #expect(terms("size:10mb..50mb")[0].value == "10mb..50mb")
        #expect(terms("dm:today")[0].function == "datemodified")
        #expect(terms("date-modified:2026-09-04")[0].function == "datemodified")
        #expect(terms("datemodified:2026-09-04")[0].function == "datemodified")
        #expect(terms("DATE_MODIFIED:x")[0].function == "datemodified")
        #expect(terms("dmyear:>2022")[0].function == "datemodifiedyear")
        #expect(terms("dm:2026-09-04T12:30")[0].value == "2026-09-04T12:30")
        #expect(terms("parent:\"c:\\program files\"")[0].function == "parent")
        #expect(terms("parent:\"c:\\program files\"")[0].value == "c:/program files")
        #expect(terms("child:mp3")[0].function == "child")
        #expect(terms("!child:mp3").isEmpty == false)
        #expect(strip(root("!child:mp3")) == .not(t("mp3", "child")))
        #expect(terms("empty:")[0].function == "empty")
        #expect(terms("regmatch1:foo")[0].function == "regularexpressionmatch1")
        #expect(terms("length:10mins..30mins")[0].function == "length")
        #expect(terms("attrib:H")[0].function == "attributes")
    }

    @Test func unknownPrefixIsLiteral() {
        let ts = terms("foo:bar")
        #expect(ts.count == 1)
        #expect(ts[0].function == nil)
        #expect(ts[0].value == "foo:bar")
        #expect(terms("http://x")[0].value == "http://x")
        #expect(terms("12:30")[0].value == "12:30")
    }

    @Test func directives() {
        let q = parser.parse("foo sort:size-descending count:10 dupe:name;size columns:name;size")
        #expect(q.root.terms.map { $0.value } == ["foo"])
        #expect(q.directives.contains(.sort(["size-descending"])))
        #expect(q.directives.contains(.count(10)))
        #expect(q.directives.contains(.dupe(["name", "size"])))
        #expect(q.directives.contains(.columns(["name", "size"])))
        #expect(parser.parse("preview:").directives == [.preview(true)])
        #expect(parser.parse("no-preview:").directives == [.preview(false)])
        #expect(parser.parse("thumbnails:128").directives == [.thumbnails(128)])
        #expect(parser.parse("column-a:$size:").directives == [.addColumn(index: 10, spec: "$size:")])
        #expect(parser.parse("filelist3:a;b").directives == [.fileListSlot(3, ["a", "b"])])
        #expect(parser.parse("sort:size").root == .empty)
    }

    @Test func macros() {
        var o = ParseOptions(); o.macroNames = ["audio", "video"]
        let q = QueryParser(options: o).parse("audio:|video: beethoven")
        let ts = q.root.terms
        #expect(ts.count == 3)
        #expect(ts[0].function == "macro:audio")
        #expect(ts[1].function == "macro:video")
        #expect(ts[2].value == "beethoven")
    }

    @Test func literalOperators() {
        var o = ParseOptions(); o.literalOperators = true
        #expect(strip(root("a AND b", options: o)) == .and([t("a"), t("b")]))
        #expect(strip(root("a OR b", options: o)) == .or([t("a"), t("b")]))
        #expect(strip(root("NOT a", options: o)) == .not(t("a")))
        #expect(strip(root("\"AND\"", options: o)).terms[0].value == "AND")
        #expect(strip(root("a OR b")).terms.count == 3)  // off by default
    }

    @Test func pathsBackslashNormalization() {
        #expect(terms("c:\\windows\\media\\")[0].value == "/windows/media/")
        #expect(terms("c:\\windows\\media\\")[0].modifiers.path == true)
        #expect(terms("\"c:\\program files\\\"")[0].value == "/program files/")
        #expect(terms("regex:a\\.b")[0].value == "a\\.b")
    }

    @Test func termRanges() {
        let q = parser.parse("abc def")
        #expect(q.root.terms[0].range == 0..<3)
        #expect(q.root.terms[1].range == 4..<7)
    }

    @Test func nestedGroupsAndStrayClose() {
        #expect(strip(root("<<a b> c>")) == .and([t("a"), t("b"), t("c")]))
        #expect(strip(root("a > b")) == .and([t("a"), t("b")]))
        #expect(strip(root("<a")) == t("a"))
        #expect(strip(root("size:>5")) == t(">5", "size"))
    }
}
