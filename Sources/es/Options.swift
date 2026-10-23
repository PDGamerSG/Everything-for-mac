import Foundation
import EverythingCore

public enum ESParseError: Error, Equatable, CustomStringConvertible {
    case missingValue(String)
    case invalidValue(String, String)
    case unknownOption(String)
    case usage(String)

    public var description: String {
        switch self {
        case .missingValue(let option): return "missing value for \(option)"
        case .invalidValue(let option, let value): return "invalid value for \(option): \(value)"
        case .unknownOption(let option): return "unknown option: \(option)"
        case .usage(let message): return message
        }
    }
}

public struct ESOptions: Equatable, Sendable {
    public var search = ""
    public var defaults = MatchDefaults()
    public var sort: String?
    public var ascending: Bool?
    public var columns = ["fullpath"]
    public var format: ExportFormat = .txt
    public var includeHeader = false
    public var count = 0
    public var offset = 0
    public var timeoutMs = 30_000
    public var databasePath: String?
    public var instance = ""
    public var filter: String?
    public var highlight = false
    public var noResultError = false
    public var help = false
    public var version = false

    public init() {}

    public static func parse(_ argv: [String]) throws -> ESOptions {
        var out = ESOptions()
        var terms: [String] = []
        var i = argv.first == "es" || argv.first == "ES" ? 1 : 0
        func value(_ option: String) throws -> String {
            guard i + 1 < argv.count else { throw ESParseError.missingValue(option) }
            i += 1
            return argv[i]
        }
        func integer(_ option: String) throws -> Int {
            let v = try value(option)
            guard let n = Int(v), n >= 0 else { throw ESParseError.invalidValue(option, v) }
            return n
        }
        while i < argv.count {
            let arg = argv[i]
            guard arg.hasPrefix("-") && arg != "-" else { terms.append(arg); i += 1; continue }
            let option = arg.lowercased()
            switch option {
            case "-h", "--help", "-help": out.help = true
            case "-version", "--version": out.version = true
            case "-case", "-match-case": out.defaults.matchCase = true
            case "-nocase", "-no-case": out.defaults.matchCase = false
            case "-whole", "-whole-word", "-match-whole-word": out.defaults.matchWholeWords = true
            case "-path", "-match-path": out.defaults.matchPath = true
            case "-diacritics", "-match-diacritics": out.defaults.matchDiacritics = true
            case "-prefix", "-match-prefix": out.defaults.matchPrefix = true
            case "-suffix", "-match-suffix": out.defaults.matchSuffix = true
            case "-ignore-punctuation": out.defaults.ignorePunctuation = true
            case "-ignore-whitespace": out.defaults.ignoreWhitespace = true
            case "-regex": out.defaults.regex = true
            case "-sort": out.sort = QueryParser.canonical(try value(arg))
            case "-sort-ascending", "-ascending": out.ascending = true
            case "-sort-descending", "-descending": out.ascending = false
            case "-columns", "-column":
                out.columns = try value(arg).split(separator: ";").map { QueryParser.canonical(String($0)) }.filter { !$0.isEmpty }
                if out.columns.isEmpty { throw ESParseError.invalidValue(arg, "empty columns") }
            case "-csv": out.format = .csv; out.includeHeader = true
            case "-tsv": out.format = .tsv; out.includeHeader = true
            case "-txt", "-text": out.format = .txt
            case "-efu": out.format = .efu; out.includeHeader = true
            case "-json": out.format = .json
            case "-m3u": out.format = .m3u
            case "-m3u8": out.format = .m3u8
            case "-header": out.includeHeader = true
            case "-no-header": out.includeHeader = false
            case "-count", "-max-results": out.count = try integer(arg)
            case "-offset": out.offset = try integer(arg)
            case "-timeout": out.timeoutMs = try integer(arg)
            case "-db", "-database": out.databasePath = try value(arg)
            case "-instance": out.instance = try value(arg)
            case "-filter": out.filter = try value(arg)
            case "-highlight": out.highlight = true
            case "-no-result-error", "-no-results-error": out.noResultError = true
            case "--": terms.append(contentsOf: argv[(i + 1)...]); i = argv.count
            default: throw ESParseError.unknownOption(arg)
            }
            i += 1
        }
        out.search = terms.joined(separator: " ")
        return out
    }
}
