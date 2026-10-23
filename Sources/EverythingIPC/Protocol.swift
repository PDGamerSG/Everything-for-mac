import Foundation
import EverythingCore

/// Wire protocol between the Everything app and its clients (`es`, SDK, HTTP server, ETP server).
/// Frames: 4-byte little-endian payload length followed by UTF-8 JSON.
public let ipcProtocolVersion = 1

public struct IPCQueryParams: Codable, Equatable, Sendable {
    public var search = ""
    public var matchCase: Bool? = nil
    public var matchWholeWord: Bool? = nil
    public var matchPath: Bool? = nil
    public var matchDiacritics: Bool? = nil
    public var matchPrefix: Bool? = nil
    public var matchSuffix: Bool? = nil
    public var ignorePunctuation: Bool? = nil
    public var ignoreWhitespace: Bool? = nil
    public var regex: Bool? = nil
    public var sort: String? = nil             // property id, optional "-descending"
    public var ascending: Bool? = nil
    public var foldersFirst: Int? = nil        // FoldersFirst raw value
    public var offset = 0
    public var count = 0                       // 0 = all
    public var columns: [String] = []          // extra properties to return
    public var highlight = false
    public var filter: String? = nil           // filter name
    public var omissions: Bool? = nil
    public var filterSearch: String? = nil     // literal secondary search (ETP FILTER_SEARCH)
    public var maxThreads: Int? = nil

    public init(search: String = "") { self.search = search }
}

public struct IPCItem: Codable, Equatable, Sendable {
    public var type: String                    // "file" | "folder" | "volume"
    public var name: String
    public var path: String
    public var fullPath: String
    public var size: UInt64?
    public var dateModified: Int64?
    public var dateCreated: Int64?
    public var dateAccessed: Int64?
    public var attributes: String?
    public var attributesValue: UInt32?
    public var runCount: Int?
    public var dateRun: Int64?
    public var dateRecentlyChanged: Int64?
    public var fileListFilename: String?
    public var extensionName: String?
    public var highlightedName: String?
    public var highlightedPath: String?
    public var properties: [String: String]?
    public var itemID: Int32

    public init(type: String, name: String, path: String, fullPath: String, itemID: Int32) {
        self.type = type; self.name = name; self.path = path; self.fullPath = fullPath; self.itemID = itemID
    }
}

public struct IPCQueryResult: Codable, Equatable, Sendable {
    public var totalFiles: Int
    public var totalFolders: Int
    public var totalResults: Int
    public var items: [IPCItem]
    public var generation: UInt64
    public var seconds: Double
    public var errors: [String]
    public var totalSize: UInt64?
    public init(totalFiles: Int, totalFolders: Int, totalResults: Int, items: [IPCItem], generation: UInt64, seconds: Double, errors: [String], totalSize: UInt64? = nil) {
        self.totalFiles = totalFiles; self.totalFolders = totalFolders; self.totalResults = totalResults; self.items = items
        self.generation = generation; self.seconds = seconds; self.errors = errors; self.totalSize = totalSize
    }
}

public struct IPCJournalParams: Codable, Equatable, Sendable {
    public var fromChangeID: UInt64? = nil
    public var toChangeID: UInt64? = nil
    public var fromDate: Int64? = nil
    public var toDate: Int64? = nil
    public var actions: [String]? = nil        // JournalEntry.Action raw values
    public var text = ""
    public var regex = false
    public var addedOnly = false
    public var removedOnly = false
    public var watch = false                   // block until a matching change arrives (or timeout)
    public var timeoutMs = 0
    public init() {}
}

public struct IPCJournalResult: Codable, Equatable, Sendable {
    public var journalID: UInt64
    public var nextChangeID: UInt64
    public var firstChangeID: UInt64
    public var entries: [JournalEntry]
    public init(journalID: UInt64, nextChangeID: UInt64, firstChangeID: UInt64, entries: [JournalEntry]) {
        self.journalID = journalID; self.nextChangeID = nextChangeID; self.firstChangeID = firstChangeID; self.entries = entries
    }
}

public struct IPCRequest: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case ping, version, isDBLoaded, isAdmin, rebuildDB, saveDB, saveRunHistory, deleteRunHistory, updateAllFolderIndexes, exit
        case query, runCountGet, runCountSet, runCountInc, journal, folderSize, command, statistics, roots, settingsGet, settingsSet
        case indexRoots, rescanAll, monitorPause, monitorResume
    }
    public var kind: Kind
    public var query: IPCQueryParams? = nil
    public var path: String? = nil
    public var count: Int? = nil
    public var args: [String]? = nil
    public var journal: IPCJournalParams? = nil
    public var key: String? = nil
    public var value: String? = nil

    public init(kind: Kind) { self.kind = kind }
    public static func query(_ q: IPCQueryParams) -> IPCRequest { var r = IPCRequest(kind: .query); r.query = q; return r }
}

public struct IPCRootInfo: Codable, Equatable, Sendable {
    public var kind: String
    public var path: String
    public var label: String
    public var itemCount: Int
    public var online: Bool
    public init(kind: String, path: String, label: String, itemCount: Int, online: Bool) {
        self.kind = kind; self.path = path; self.label = label; self.itemCount = itemCount; self.online = online
    }
}

public struct IPCResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String? = nil
    public var version: String? = nil
    public var bool: Bool? = nil
    public var int: Int? = nil
    public var int64: Int64? = nil
    public var uint64: UInt64? = nil
    public var string: String? = nil
    public var query: IPCQueryResult? = nil
    public var journal: IPCJournalResult? = nil
    public var roots: [IPCRootInfo]? = nil
    public var dictionary: [String: String]? = nil

    public init(ok: Bool = true) { self.ok = ok }
    public static func failure(_ message: String) -> IPCResponse { var r = IPCResponse(ok: false); r.error = message; return r }
    public static func value(_ b: Bool) -> IPCResponse { var r = IPCResponse(); r.bool = b; return r }
    public static func value(_ i: Int) -> IPCResponse { var r = IPCResponse(); r.int = i; return r }
    public static func value(_ i: Int64) -> IPCResponse { var r = IPCResponse(); r.int64 = i; return r }
    public static func value(_ u: UInt64) -> IPCResponse { var r = IPCResponse(); r.uint64 = u; return r }
    public static func value(_ s: String) -> IPCResponse { var r = IPCResponse(); r.string = s; return r }
}

/// Something that answers IPC requests (the app engine, or an in-process fake for tests).
public protocol IPCService: AnyObject {
    func handle(_ request: IPCRequest, completion: @escaping (IPCResponse) -> Void)
}

public enum IPCCodec {
    public static let encoder: JSONEncoder = { let e = JSONEncoder(); return e }()
    public static let decoder = JSONDecoder()

    public static func encode<T: Encodable>(_ v: T) throws -> Data { try encoder.encode(v) }
    public static func decode<T: Decodable>(_ t: T.Type, _ d: Data) throws -> T { try decoder.decode(t, from: d) }

    public static func frame(_ payload: Data) -> Data {
        var len = UInt32(payload.count).littleEndian
        var out = Data(bytes: &len, count: 4)
        out.append(payload)
        return out
    }
}

public let everythingVersion = "1.5.0.1424"
public let everythingVersionComponents = (major: 1, minor: 5, revision: 0, build: 1424)
