import Foundation
import Testing
@testable import es
import EverythingIPC
import EverythingCore

@Suite struct ESOptionTests {
    @Test func ignoresExecutablePathInArguments() throws {
        let options = try ESOptions.parse(["/Applications/Everything.app/Contents/MacOS/es", "-json", "invoice"])
        #expect(options.search == "invoice")
        #expect(try ESOptions.parse(["./es"]).search.isEmpty)
    }
    @Test func parsesEverythingStyleSwitches() throws {
        let options = try ESOptions.parse([
            "es", "-regex", "-path", "-sort", "size", "-sort-descending",
            "-columns", "name;full-path;size", "-csv", "-no-header", "-count", "25",
            "invoice.*"
        ])
        #expect(options.defaults.regex)
        #expect(options.defaults.matchPath)
        #expect(options.sort == "size")
        #expect(options.ascending == false)
        #expect(options.columns == ["name", "fullpath", "size"])
        #expect(options.format == .csv)
        #expect(options.includeHeader == false)
        #expect(options.count == 25)
        #expect(options.search == "invoice.*")
    }

    @Test func parsesOutputAndErrorFlags() throws {
        let options = try ESOptions.parse(["es", "-json", "-no-result-error", "-timeout", "1500", "-db", "/tmp/x.db", "foo"])
        #expect(options.format == .json)
        #expect(options.noResultError)
        #expect(options.timeoutMs == 1500)
        #expect(options.databasePath == "/tmp/x.db")
        #expect(options.search == "foo")
    }

    @Test func rejectsMissingValuesAndUnknownSwitches() {
        #expect(throws: ESParseError.self) { try ESOptions.parse(["es", "-count"]) }
        #expect(throws: ESParseError.self) { try ESOptions.parse(["es", "-not-a-switch"]) }
    }
}

@Suite(.serialized) struct ESIntegrationTests {
    @Test func launchesExecutableAgainstSavedDatabase() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("es-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let index = Index()
        let root = index.addRoot(kind: .folder, path: "/Fixture", label: "Fixture")
        index.store.add(ItemRecord(name: "invoice.txt", parent: root.item, size: 42))
        let database = support.appendingPathComponent("Everything.db")
        try IndexDB.save(index, to: database)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/arm64-apple-macosx/debug/es")
        process.arguments = ["-db", database.path, "-json", "invoice"]
        var environment = ProcessInfo.processInfo.environment
        environment["EVERYTHING_APP_SUPPORT"] = support.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["totalResults"] as? Int == 1)
        #expect((json["results"] as? [[String: Any]])?.first?["full_path"] as? String == "/Fixture/invoice.txt")
    }
}

@Suite struct ESOutputTests {
    let items = [
        IPCItem(type: "file", name: "a,b.txt", path: "/tmp", fullPath: "/tmp/a,b.txt", itemID: 1),
        IPCItem(type: "folder", name: "Docs", path: "/", fullPath: "/Docs", itemID: 2)
    ]

    @Test func csvQuotesAndHeaders() {
        let text = ESOutput.render(items: items, totalResults: 2, format: .csv, columns: ["name", "fullpath"], includeHeader: true)
        #expect(text == "Name,Full Path\r\n\"a,b.txt\",\"/tmp/a,b.txt\"\r\nDocs,/Docs\r\n")
    }

    @Test func jsonHasStableShape() throws {
        let text = ESOutput.render(items: items, totalResults: 2, format: .json, columns: ["fullpath"], includeHeader: true)
        let data = try #require(text.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["totalResults"] as? Int == 2)
        #expect((object["results"] as? [[String: Any]])?.first?["full_path"] as? String == "/tmp/a,b.txt")
    }
}
