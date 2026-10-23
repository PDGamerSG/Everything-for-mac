import Testing
import Foundation
@testable import EverythingCore

/// In-memory world for predicate tests.
struct World {
    let index: Index
    let root: ItemID
    var ids: [String: ItemID] = [:]
    let now: Date
    let cal = Calendar.current

    init() {
        index = Index()
        root = index.addRoot(kind: .volume, path: "/", label: "Macintosh HD").item
        now = cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 15))!
        func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 12) -> Int64 { Timestamps.fromDate(cal.date(from: DateComponents(year: y, month: m, day: day, hour: h))!) }
        let s = index.store
        let users = s.add(ItemRecord(name: "Users", parent: root, flags: [.folder], dateModified: d(2026, 1, 1)))
        let admin = s.add(ItemRecord(name: "admin", parent: users, flags: [.folder], dateModified: d(2026, 1, 1)))
        let docs = s.add(ItemRecord(name: "Documents", parent: admin, flags: [.folder], dateModified: d(2026, 1, 1)))
        let empty = s.add(ItemRecord(name: "Empty", parent: admin, flags: [.folder]))
        let app = s.add(ItemRecord(name: "Safari.app", parent: root, flags: [.folder, .package]))
        ids = ["users": users, "admin": admin, "docs": docs, "empty": empty, "app": app]
        ids["report"] = s.add(ItemRecord(name: "Report.pdf", parent: docs, size: 5 * 1024 * 1024, dateModified: d(2026, 10, 23, 9), dateCreated: d(2025, 3, 4), inode: 101))
        ids["notes"] = s.add(ItemRecord(name: "notes.txt", parent: docs, flags: [.hidden], size: 100, dateModified: d(2026, 10, 22), dateCreated: d(2026, 10, 22), inode: 102))
        ids["song"] = s.add(ItemRecord(name: "Song.MP3", parent: admin, size: 3 * 1024 * 1024, dateModified: d(2024, 6, 15), inode: 103))
        ids["photo"] = s.add(ItemRecord(name: "Résumé photo.jpg", parent: admin, flags: [.locked], size: 2048, dateModified: d(2026, 10, 1), inode: 104))
        ids["cpp"] = s.add(ItemRecord(name: "main.cpp", parent: docs, size: 10, dateModified: d(2026, 9, 4, 12), inode: 105))
        ids["h"] = s.add(ItemRecord(name: "main.h", parent: docs, size: 0, dateModified: d(2026, 9, 4, 18), inode: 106))
        ids["noext"] = s.add(ItemRecord(name: "README", parent: root, size: 7, dateModified: d(2026, 10, 23, 14)))
    }

    func run(_ query: String, defaults: MatchDefaults = MatchDefaults(), macros: [String: String] = [:]) -> Set<String> {
        var env = CompileEnv()
        env.defaults = defaults
        env.index = index
        env.now = now
        env.macros = macros
        let cq = QueryCompiler.compile(query, env: env)
        let ctx = EvalContext(index: index, paths: PathTable(store: index.store, roots: index.rootItems), properties: PropertyReader(), now: now)
        var out = Set<String>()
        for i in 0..<index.store.slotCount where index.store.isAlive(ItemID(i)) {
            if cq.predicate.eval(ItemID(i), ctx) { out.insert(index.store.name(ItemID(i))) }
        }
        return out
    }

    func names(_ query: String) -> Set<String> { run(query) }
}

@Suite struct FunctionsTests {
    let w = World()
    let all: Set<String> = ["/", "Users", "admin", "Documents", "Empty", "Safari.app", "Report.pdf", "notes.txt", "Song.MP3", "Résumé photo.jpg", "main.cpp", "main.h", "README"]

    @Test func plainAndOperators() {
        #expect(w.names("main") == ["main.cpp", "main.h"])
        #expect(w.names("main cpp") == ["main.cpp"])
        #expect(w.names("main.cpp|song") == ["main.cpp", "Song.MP3"])
        #expect(w.names("main !cpp") == ["main.h"])
        #expect(w.names("resume") == ["Résumé photo.jpg"])
        #expect(w.names("") == all)
        #expect(w.names("!.") == ["/", "Users", "admin", "Documents", "Empty", "README"])
        #expect(w.names("\"main.c\"") == ["main.cpp"])
    }

    @Test func pathMatching() {
        #expect(w.names("\\documents") == ["Documents", "Report.pdf", "notes.txt", "main.cpp", "main.h"])
        #expect(w.names("path:users/admin/documents/") == ["Report.pdf", "notes.txt", "main.cpp", "main.h"])
        #expect(w.names("/Users/admin/Documents/") == ["Report.pdf", "notes.txt", "main.cpp", "main.h"])
        #expect(w.names("loc:/Users/admin") == ["Documents", "Empty", "Song.MP3", "Résumé photo.jpg", "Report.pdf", "notes.txt", "main.cpp", "main.h"])
        var d = MatchDefaults(); d.matchPath = true
        #expect(w.run("admin main", defaults: d) == ["main.cpp", "main.h"])
        #expect(w.names("nopath:admin") == ["admin"])
        #expect(w.names("parent:/Users/admin/Documents") == ["Report.pdf", "notes.txt", "main.cpp", "main.h"])
        #expect(w.names("parent:\"C:\\Users\\admin\\Documents\"") == ["Report.pdf", "notes.txt", "main.cpp", "main.h"])
        #expect(w.names("ancestor:/Users") == ["admin", "Documents", "Empty", "Song.MP3", "Résumé photo.jpg", "Report.pdf", "notes.txt", "main.cpp", "main.h"])
        #expect(w.names("parent:/nope") == [])
        #expect(w.names("parentname:documents") == ["Report.pdf", "notes.txt", "main.cpp", "main.h"])
        #expect(w.names("ancestorname:admin cpp") == ["main.cpp"])
    }

    @Test func fileFolderExt() {
        #expect(w.names("folder:") == ["/", "Users", "admin", "Documents", "Empty", "Safari.app"])
        #expect(w.names("file: main") == ["main.cpp", "main.h"])
        #expect(w.names("ext:cpp;h") == ["main.cpp", "main.h"])
        #expect(w.names("ext:MP3") == ["Song.MP3"])
        #expect(w.names("ext:app") == ["Safari.app"])
        #expect(w.names("ext:*p*") == ["main.cpp", "Safari.app", "Report.pdf", "Résumé photo.jpg", "Song.MP3"])
        #expect(w.names("extension:pd") == ["Report.pdf"])
        #expect(w.names("stem:main") == ["main.cpp", "main.h"])
        #expect(w.names("name:song") == ["Song.MP3"])
        #expect(w.names("*.txt") == ["notes.txt"])
        #expect(w.names("wfn:report.pdf") == ["Report.pdf"])
        #expect(w.names("empty:") == ["Empty", "Safari.app"])
        #expect(w.names("folder: !empty:") == ["/", "Users", "admin", "Documents"])
        #expect(w.names("root:") == ["/"])
        #expect(w.names("namelen:>8") == ["Documents", "Safari.app", "Report.pdf", "notes.txt", "Résumé photo.jpg"])
        #expect(w.names("depth:1") == ["Users", "Safari.app", "README"])
        #expect(w.names("child:report") == ["Documents"])
        #expect(w.names("!child:*.txt folder:") == ["/", "Users", "admin", "Empty", "Safari.app"])
        #expect(w.names("descendant:song") == ["/", "Users", "admin"])
        #expect(w.names("childcount:>=3") == ["/", "admin", "Documents"])
        #expect(w.names("sibling:main.h") == ["Report.pdf", "notes.txt", "main.cpp"])
        #expect(w.names("descendantcount:4") == ["Documents"])
        #expect(w.names("descendantcount:9") == ["Users"])
        #expect(w.names("childfilecount:4") == ["Documents"])
    }

    @Test func sizesAndDates() {
        #expect(w.names("size:>1mb") == ["Report.pdf", "Song.MP3"])
        #expect(w.names("size:1mb..4mb") == ["Song.MP3"])
        #expect(w.names("size:empty file:") == ["main.h"])
        #expect(w.names("size:0") == ["main.h"])
        #expect(w.names("size:tiny file:") == ["notes.txt", "Résumé photo.jpg", "main.cpp", "main.h", "README"])
        #expect(w.names("dm:today") == ["Report.pdf", "README"])
        #expect(w.names("dm:yesterday") == ["notes.txt"])
        #expect(w.names("date-modified:2026-09-04") == ["main.cpp", "main.h"])
        #expect(w.names("dm:2026-09-04T12") == ["main.cpp"])
        #expect(w.names("dm:>2025 file:") == ["Report.pdf", "notes.txt", "Résumé photo.jpg", "main.cpp", "main.h", "README"])
        #expect(w.names("dm:2024") == ["Song.MP3"])
        #expect(w.names("dmyear:2024") == ["Song.MP3"])
        #expect(w.names("dmmonth:sep") == ["main.cpp", "main.h"])
        #expect(w.names("dmhour:>=14 dm:today") == ["README"])
        #expect(w.names("dmtime:>13:00 dm:2026-09-04") == ["main.h"])
        #expect(w.names("dmdow:fri dm:today") == ["Report.pdf", "README"])   // 2026-10-23 is a Friday
        #expect(w.names("dc:2025") == ["Report.pdf"])
        #expect(w.names("dc:unknown file:") == ["Song.MP3", "Résumé photo.jpg", "main.cpp", "main.h", "README"])
        #expect(w.names("dm:7days file:") == ["Report.pdf", "notes.txt", "README"])
        #expect(w.names("dm:2025-07-01..2026-06-30") == ["Users", "admin", "Documents"])
    }

    @Test func attributesAndIDs() {
        #expect(w.names("attrib:H") == ["notes.txt"])
        #expect(w.names("attrib:R") == ["Résumé photo.jpg"])
        #expect(w.names("attrib:D Empty") == ["Empty"])
        #expect(w.names("size:0 folder:") == [])
        #expect(w.names("attrib:0x2") == ["notes.txt"])
        #expect(w.names("fileid:103") == ["Song.MP3"])
        #expect(w.names("frn:>=105") == ["main.cpp", "main.h"])
        #expect(w.names("volume:macintosh") == all)
        #expect(w.names("kind:folder") == ["/", "Users", "admin", "Documents", "Empty"])
        #expect(w.names("kind:music") == ["Song.MP3"])
        #expect(w.names("kind:picture") == ["Résumé photo.jpg"])
        #expect(w.names("kind:program") == ["Safari.app"])
        #expect(w.names("type:folder") == ["/", "Users", "admin", "Documents", "Empty"])
    }

    @Test func macrosAndModifiers() {
        let macros = ["audio": "ext:mp3;wav;flac", "doc": "ext:pdf;txt;doc"]
        #expect(w.run("audio:", macros: macros) == ["Song.MP3"])
        #expect(w.run("audio:|doc:", macros: macros) == ["Song.MP3", "Report.pdf", "notes.txt"])
        #expect(w.run("doc:report", macros: macros) == ["Report.pdf"])
        #expect(w.names("case:README") == ["README"])
        #expect(w.names("case:readme") == [])
        #expect(w.names("regex:^main\\.(cpp|h)$") == ["main.cpp", "main.h"])
        #expect(w.names("regex:^Main") == ["main.cpp", "main.h"])
        #expect(w.names("case:regex:^Main") == [])
        #expect(w.names("ww:main") == ["main.cpp", "main.h"])
        #expect(w.names("ww:mai") == [])
        #expect(w.names("startwith:re") == ["Report.pdf", "Résumé photo.jpg", "README"])
        #expect(w.names("endwith:.h") == ["main.h"])
        #expect(w.names("len:>10") == ["Résumé photo.jpg"])
        #expect(w.names("nows:resumephoto") == ["Résumé photo.jpg"])
        #expect(w.names("diacritics:resume") == [])
        #expect(w.names("<main cpp>|<song>") == ["main.cpp", "Song.MP3"])
        #expect(w.names("regex:^(\\w+)\\.cpp$ regmatch1:main") == ["main.cpp"])
        #expect(w.names("eval:$size:>1000000") == ["Report.pdf", "Song.MP3"])
        #expect(w.names("exists:/Users/admin/Documents") == all)
        #expect(w.names("exists:/nope") == [])
        #expect(w.names("folder: exists:$fullpath:/Report.pdf") == ["Documents"])
        #expect(w.names("filelist:main.cpp;README") == ["main.cpp", "README"])
        #expect(w.names("filelist:/Users/admin/Song.MP3") == ["Song.MP3"])
        #expect(w.names("filelist:*.h") == ["main.h"])
        #expect(w.names("nothing:") == all)  // directive, no filtering
        #expect(w.names("count:1 main").count == 2)   // count handled by engine, not predicate
    }

    @Test func errorsAndUnknown() {
        var env = CompileEnv(); env.index = w.index
        let bad = QueryCompiler.compile("regex:(", env: env)
        #expect(!bad.errors.isEmpty)
        #expect(w.names("size:abc") == [])
        #expect(w.names("dm:garbage") == [])
        #expect(w.names("foo:bar") == [])   // literal text "foo:bar"
        let hl = QueryCompiler.compile("main !cpp ext:h size:>1", env: env)
        #expect(hl.highlighters.count == 1)
        #expect(hl.highlighters[0].matcher.pattern == "main")
        let nh = QueryCompiler.compile("nohighlight:main", env: env)
        #expect(nh.highlighters.isEmpty)
    }

    @Test func expressionEvaluator() throws {
        #expect(try Expression.evaluate("1 + 2 * 3") == .number(7))
        #expect(try Expression.evaluate("(1 + 2) * 3") == .number(9))
        #expect(try Expression.evaluate("10 > 5 && 2 < 1") == .number(0))
        #expect(try Expression.evaluate("10 > 5 || 2 < 1") == .number(1))
        #expect(try Expression.evaluate("1mb") == .number(1_048_576))
        #expect(try Expression.evaluate("\"abc\" == \"ABC\"") == .number(1))
        #expect(Expression.isTrue("5000000 > 1mb"))
        #expect(!Expression.isTrue("garbage ("))
        #expect(try Expression.evaluate("-3 + 5") == .number(2))
        #expect(try Expression.evaluate("7 % 4") == .number(3))
    }
}

@Suite struct PropertyReaderTests {
    @Test func statAndDerived() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("evt-prop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let txt = dir.appendingPathComponent("hello.txt")
        try "hello world\nsecond line\n".write(to: txt, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: txt)
        let r = PropertyReader()
        #expect(r.number("size", path: txt.path, isFolder: false) == 24)
        #expect(r.number("line-count", path: txt.path, isFolder: false) == 2)
        #expect(r.number("word-count", path: txt.path, isFolder: false) == 4)
        #expect(r.text("md5", path: txt.path, isFolder: false) == Hashes.hex(.md5, data: Data("hello world\nsecond line\n".utf8)))
        #expect(r.text("sha256", path: txt.path, isFolder: false)?.count == 64)
        #expect(r.text("crc32", path: txt.path, isFolder: false)?.count == 8)
        #expect(r.text("character-encoding", path: txt.path, isFolder: false) == "ASCII")
        #expect(r.text("content-type", path: txt.path, isFolder: false) == "text/plain")
        #expect(r.text("shortcut-target", path: link.path, isFolder: false) == txt.path)
        #expect(r.text("owner", path: txt.path, isFolder: false) == NSUserName())
        #expect(r.number("hard-link-count", path: txt.path, isFolder: false) == 1)
        #expect(r.text("file-signature", path: txt.path, isFolder: false) == "Text")
        #expect(PropertyReader.kind(forPath: "/x/a.jpg", isFolder: false) == "Picture")
        #expect(PropertyReader.kind(forPath: "/x/Foo.app", isFolder: true) == "Program")
        #expect(PropertyReader.perceivedType(forPath: "/x/a.txt", isFolder: false) == "text")
        // zip container listing
        let zipPath = dir.appendingPathComponent("a.zip").path
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); p.arguments = ["-q", "-j", zipPath, txt.path]
        try p.run(); p.waitUntilExit()
        #expect(r.list("container-filenames", path: zipPath, isFolder: false) == ["hello.txt"])
        #expect(r.number("container-file-count", path: zipPath, isFolder: false) == 1)
        #expect(ContentSearch.matches(path: txt.path, matcher: TextMatcher(pattern: "second", mode: MatchMode()), encoding: .auto, limit: 0, eachLine: true))
        #expect(!ContentSearch.matches(path: txt.path, matcher: TextMatcher(pattern: "world second", mode: MatchMode()), encoding: .auto, limit: 0, eachLine: true))
        #expect(ContentSearch.matchesHex(path: txt.path, hexPattern: "68656C6C6F", limit: 0))
        #expect(Hashes.hex(.md5, data: Data("abc".utf8)) == "900150983cd24fb0d6963f7d28e17f72")
        #expect(Hashes.hex(.sha1, data: Data("abc".utf8)) == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(Hashes.hex(.crc32, data: Data("123456789".utf8)) == "cbf43926")
        #expect(Hashes.hex(.crc64, data: Data("123456789".utf8)) == "995dc9bbdf1939fa")
        #expect(!PropertyReader.isRunning(path: "/nonexistent/app"))
        #expect(PropertyReader.isRunning(path: "/sbin/launchd"))
        let sig = r.text("digital-signature-name", path: "/Applications/Safari.app", isFolder: true)
        #expect(sig?.isEmpty == false)
        #expect(r.text("product-version", path: "/Applications/Safari.app", isFolder: true)?.isEmpty == false)
    }
}
