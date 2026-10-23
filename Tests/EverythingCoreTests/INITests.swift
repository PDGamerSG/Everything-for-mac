import Testing
import Foundation
@testable import EverythingCore

@Suite struct INITests {
    @Test func roundTripPreservesUnknownKeys() {
        let text = "[Everything]\nmatch_case=1\nsome_unknown=hello world\n;comment\nsearch_delay=250\n"
        let ini = INIFile(parsing: text)
        #expect(ini["match_case"] == "1")
        #expect(ini["some_unknown"] == "hello world")
        #expect(ini.int("search_delay", default: 0) == 250)
        #expect(ini.bool("match_case", default: false))
        #expect(ini.render() == "[Everything]\nmatch_case=1\nsome_unknown=hello world\nsearch_delay=250\n")
    }

    @Test func setRemoveMerge() {
        var ini = INIFile()
        ini.set("a", "1"); ini.set("b", "2"); ini.set("a", "3")
        #expect(ini["a"] == "3")
        ini.remove("a")
        #expect(ini["a"] == nil)
        #expect(ini["b"] == "2")
        var other = INIFile(); other.set("b", "9"); other.set("c", "c")
        ini.merge(other)
        #expect(ini["b"] == "9"); #expect(ini["c"] == "c")
    }

    @Test func crlfAndBoolForms() {
        let ini = INIFile(parsing: "x=true\r\ny=off\r\nz=yes\r\n")
        #expect(ini.bool("x", default: false))
        #expect(!ini.bool("y", default: true))
        #expect(ini.bool("z", default: false))
    }
}

@Suite struct CSVTests {
    @Test func quoting() {
        let text = "Name,Search\n\"a,\"\"b\"\"\",ext:cpp;h\nplain,\"multi\nline\"\n"
        let t = CSVTable.parse(text)
        #expect(t.headers == ["Name", "Search"])
        #expect(t.rows.count == 2)
        #expect(t.rows[0] == ["a,\"b\"", "ext:cpp;h"])
        #expect(t.rows[1] == ["plain", "multi\nline"])
        #expect(CSVTable.escape("a,\"b\"") == "\"a,\"\"b\"\"\"")
        #expect(t.render() == text)
    }

    @Test func bomAndLastColumnWins() {
        let text = "\u{FEFF}Filename,Size,Filename\r\nfirst,10,second\r\n"
        let t = CSVTable.parse(text)
        #expect(t.headers == ["Filename", "Size", "Filename"])
        #expect(t.value(t.rows[0], "filename") == "second")
        #expect(t.value(t.rows[0], "Size") == "10")
    }

    @Test func emptyTrailingLine() {
        let t = CSVTable.parse("a,b\n1,2\n")
        #expect(t.rows == [["1", "2"]])
    }
}

@Suite struct SettingsTests {
    @Test func defaultsAndOverrides() throws {
        let s = Settings()
        #expect(s.bool("search_as_you_type"))
        #expect(s.int("http_server_port") == 8080)
        #expect(s.string("home_filter") == "Everything")
        s.set("http_server_port", 9090)
        #expect(s.int("http_server_port") == 9090)
        #expect(s.isModified("http_server_port"))
        s.reset("http_server_port")
        #expect(!s.isModified("http_server_port"))
        #expect(s.list("exclude_folders").first == "/dev")
    }

    @Test func saveLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("Everything.ini")
        let s = Settings()
        s.set("match_case", true)
        s.set("folders", list: ["/tmp/a", "/tmp/b"])
        try s.save(to: url)
        let loaded = Settings.load(from: url)
        #expect(loaded.bool("match_case"))
        #expect(loaded.list("folders") == ["/tmp/a", "/tmp/b"])
        let md = MatchDefaults(settings: loaded)
        #expect(!md.matchCase)
    }
}
