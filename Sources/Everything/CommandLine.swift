import Foundation

public struct AppCommandLine: Equatable, Sendable {
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case missingValue(String)
        case invalidValue(String, String)
        case unknownOption(String)
        public var description: String {
            switch self { case .missingValue(let option): return "missing value for \(option)"; case .invalidValue(let option, let value): return "invalid value for \(option): \(value)"; case .unknownOption(let option): return "unknown option: \(option)" }
        }
    }
    public var search: String?
    public var startup = false
    public var noWindow = false
    public var noAutoIndex = false
    public var rescan = false
    public var rescanAll = false
    public var save = false
    public var exit = false
    public var toggle = false
    public var instance = ""
    public var url: String?
    public var help = false
    public var version = false

    public static func parse(_ argv: [String]) throws -> AppCommandLine {
        var out = AppCommandLine(search: nil)
        var terms: [String] = []
        var i = argv.first == "Everything" || argv.first == "everything" ? 1 : 0
        func value(_ option: String) throws -> String { guard i + 1 < argv.count else { throw Error.missingValue(option) }; i += 1; return argv[i] }
        while i < argv.count {
            let arg = argv[i]; guard arg.hasPrefix("-") && arg != "-" else { terms.append(arg); i += 1; continue }
            switch arg.lowercased() {
            case "-s", "-search", "-search*": out.search = try value(arg)
            case "-startup": out.startup = true
            case "-no-window": out.noWindow = true
            case "-no-auto-index": out.noAutoIndex = true
            case "-rescan": out.rescan = true
            case "-rescan-all": out.rescanAll = true
            case "-save", "-save-db", "-save-database": out.save = true
            case "-exit", "-close-all": out.exit = true
            case "-toggle-window": out.toggle = true
            case "-instance": out.instance = try value(arg)
            case "-url": out.url = try value(arg)
            case "-h", "-help", "--help": out.help = true
            case "-version", "--version": out.version = true
            default: throw Error.unknownOption(arg)
            }
            i += 1
        }
        if !terms.isEmpty { out.search = [out.search, terms.joined(separator: " ")].compactMap { $0 }.joined(separator: " ") }
        if let url = out.url, let components = URLComponents(string: url), components.scheme?.lowercased() == "es" { out.search = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        return out
    }

    public init(search: String?) { self.search = search }
}
