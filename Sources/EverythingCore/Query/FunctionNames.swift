import Foundation

/// Kinds of values a search function accepts.
public enum ValueKind: Equatable, Sendable {
    case text          // substring match with modifiers
    case number        // comparisons/ranges
    case size
    case date
    case datePart(DatePart)
    case duration
    case flag          // empty value
    case list          // `;` separated OR list of names (ext:, filelist:)
    case path          // absolute path
    case hash
    case attributes
    case directive
}

public enum DatePart: Equatable, Sendable { case date, day, dayOfWeek, hour, month, time, year }

/// Static registry of every search function name, its aliases and value kind.
/// Predicate construction lives in `Functions.swift`.
public struct FunctionSpec: Sendable {
    public let name: String              // canonical display name with dashes, e.g. "date-modified"
    public let aliases: [String]         // alternate spellings with dashes
    public let kind: ValueKind
    public let property: String?         // backing property id when the function filters on a property
    public var canonical: String { QueryParser.canonical(name) }
    public var allCanonical: [String] { ([name] + aliases).map(QueryParser.canonical) }
}

public enum FunctionCatalog {
    public static let specs: [FunctionSpec] = {
        var s: [FunctionSpec] = []
        func f(_ name: String, _ aliases: [String] = [], _ kind: ValueKind, _ property: String? = nil) { s.append(FunctionSpec(name: name, aliases: aliases, kind: kind, property: property)) }
        func dateFamily(_ base: String, _ short: String) {
            f("date-\(base)", ["d\(short)"], .date, "date-\(base)")
            f("date-\(base)-date", ["d\(short)date"], .datePart(.date), "date-\(base)")
            f("date-\(base)-day", ["d\(short)day"], .datePart(.day), "date-\(base)")
            f("date-\(base)-day-of-week", ["d\(short)dow"], .datePart(.dayOfWeek), "date-\(base)")
            f("date-\(base)-hour", ["d\(short)hour"], .datePart(.hour), "date-\(base)")
            f("date-\(base)-month", ["d\(short)month"], .datePart(.month), "date-\(base)")
            f("date-\(base)-time", ["d\(short)time"], .datePart(.time), "date-\(base)")
            f("date-\(base)-year", ["d\(short)year"], .datePart(.year), "date-\(base)")
        }
        // Name / path
        f("name", [], .text, "name"); f("stem", ["name-part"], .text, "stem"); f("ext", [], .list, "extension"); f("extension", [], .text, "extension")
        f("path", [], .text, "full-path"); f("full-path", ["fullpath", "full-path-and-name"], .text, "full-path"); f("location", ["loc"], .text, "path")
        f("name-length", ["namelen"], .number, "name-length"); f("full-path-length", ["fullpathlen", "pathlen", "path-length"], .number, "full-path-length")
        f("parent", [], .path); f("parent-name", [], .text, "path"); f("ancestor", [], .path); f("ancestor-name", [], .text)
        f("child", [], .text); f("child-file", [], .text); f("child-folder", [], .text)
        f("child-count", [], .number, "child-count"); f("child-file-count", [], .number, "child-file-count"); f("child-folder-count", [], .number, "child-folder-count")
        f("descendant", [], .text); f("descendant-file", [], .text); f("descendant-folder", [], .text)
        f("descendant-count", [], .number, "descendant-count"); f("descendant-file-count", [], .number, "descendant-file-count"); f("descendant-folder-count", [], .number, "descendant-folder-count")
        f("sibling", [], .text); f("sibling-file", [], .text); f("sibling-folder", [], .text)
        f("parent-count", ["depth"], .number, "depth"); f("empty", [], .flag); f("root", [], .flag); f("file", ["files"], .flag); f("folder", ["folders"], .flag)
        f("kind", [], .text, "kind"); f("type", [], .text, "type"); f("perceived-type", [], .text, "perceived-type"); f("volume-label", ["volume"], .text, "volume-label")
        f("file-id", ["frn", "inode"], .number, "file-id"); f("parent-file-id", ["parentfrn"], .number); f("hard-link-count", ["hardlinkcount"], .number, "hard-link-count")
        f("hard-link-filenames", ["hard-link-filename"], .text); f("owner", [], .text, "owner"); f("computer", [], .text); f("shared-with", [], .text)
        f("alternate-data-stream-count", ["adscount", "xattr-count"], .number, "xattr-count"); f("alternate-data-stream-names", ["adsnames", "adsname", "xattr-names", "xattr"], .text, "xattr-names")
        f("offline", [], .flag); f("online", [], .flag); f("offline-availability", [], .text); f("offline-status", [], .text); f("status", [], .text)
        f("rating", [], .number, "rating"); f("tags", ["tag"], .text, "tags"); f("comment", [], .text, "comment")
        // Size / dates
        f("size", [], .size, "size"); f("size-on-disk", ["sizeondisk", "allocation-size"], .size, "size-on-disk")
        dateFamily("modified", "m"); dateFamily("created", "c"); dateFamily("accessed", "a")
        f("date-changed", ["dchanged", "date-attribute-changed"], .date, "date-changed")
        f("date-recently-changed", ["rc", "recent-change", "recentchange", "dateRecentlyChanged"], .date, "date-recently-changed")
        f("date-run", ["daterun"], .date, "date-run"); f("run-count", ["runcount"], .number, "run-count")
        f("date-deleted", [], .date); f("date-added", ["dadded"], .date, "date-added")
        f("attributes", ["attr", "attrib"], .attributes, "attributes"); f("ancestor-attributes", ["ancestor-attrib"], .attributes); f("child-attributes", ["child-attrib"], .attributes)
        // Content (slow)
        f("content", [], .text, "content"); f("ansi-content", ["ansicontent"], .text, "content"); f("utf8-content", ["utf8content"], .text, "content")
        f("utf16-content", ["utf16content"], .text, "content"); f("utf16be-content", [], .text, "content"); f("ascii-content", [], .text, "content")
        f("binary", [], .text, "content"); f("hex", [], .text, "content"); f("byte-stream", ["bytestream"], .text, "content")
        f("character-encoding", ["encoding"], .text, "character-encoding"); f("content-type", ["mime"], .text, "content-type"); f("file-signature", ["signature"], .text, "file-signature")
        f("crc32", ["crc"], .hash, "crc32"); f("crc64", [], .hash, "crc64"); f("md5", [], .hash, "md5"); f("sha1", [], .hash, "sha1"); f("sha256", [], .hash, "sha256"); f("sha512", [], .hash, "sha512")
        f("first-bytes", ["firstbytes"], .text, "first-bytes"); f("last-bytes", ["lastbytes"], .text, "last-bytes")
        f("system-index", ["si", "spotlight"], .text); f("line-count", ["linecount"], .number, "line-count"); f("word-count", ["wordcount"], .number, "word-count")
        // Audio / video / image / document properties (Spotlight backed)
        for (n, a, k) in [
            ("album", [], ValueKind.text), ("album-artist", [], .text), ("artist", [], .text), ("audio-bitrate", [], .number), ("audio-bits-per-sample", [], .number),
            ("audio-channels", [], .number), ("audio-format", [], .text), ("audio-sample-rate", [], .number), ("audio-track-count", [], .number),
            ("authors", ["author"], .text), ("beats-per-minute", ["bpm"], .number), ("composer", [], .text), ("conductor", [], .text), ("copyright", [], .text),
            ("date-encoded", ["date-media-created"], .date), ("date-released", [], .date), ("description", [], .text), ("encoded-by", [], .text), ("genre", [], .text),
            ("initial-key", [], .text), ("length", ["duration"], .duration), ("mood", [], .text), ("parental-rating", [], .text), ("parental-rating-reason", [], .text),
            ("part-of-a-compilation", [], .flag), ("part-of-set", [], .text), ("period", [], .text), ("producer", [], .text), ("protected", [], .flag), ("publisher", [], .text),
            ("software", [], .text), ("subtitle", [], .text), ("title", [], .text), ("total-bitrate", [], .number), ("track", [], .number), ("year", [], .number),
            ("category", [], .text), ("company", [], .text), ("content-status", [], .text), ("date-content-created", [], .date), ("date-printed", [], .date), ("date-saved", [], .date),
            ("document-content-type", [], .text), ("last-author", [], .text), ("page-count", [], .number), ("slide-count", [], .number), ("total-editing-time", [], .duration),
            ("digital-signature-name", ["signature-name", "code-signature"], .text), ("digital-signature-timestamp", [], .date), ("is-running", [], .flag), ("language", [], .text),
            ("product-name", [], .text), ("product-version", [], .text), ("trademarks", ["trademark"], .text), ("version", [], .text),
            ("35mm-focal-length", [], .number), ("altitude", [], .number), ("aperture", [], .number), ("aspect-ratio", [], .text), ("bit-depth", ["bpp"], .number), ("brightness", [], .number),
            ("camera-maker", ["cameramake", "camera-make"], .text), ("camera-model", [], .text), ("contrast", [], .text), ("date-acquired", [], .date), ("date-taken", [], .date),
            ("dimensions", [], .text), ("exif-version", [], .text), ("exposure-bias", [], .number), ("exposure-program", [], .text), ("exposure-time", [], .number), ("flash-mode", [], .text),
            ("focal-length", [], .number), ("frame-count", [], .number), ("f-stop", ["fstop"], .number), ("height", ["high"], .number), ("horizontal-resolution", [], .number),
            ("iso-speed", ["iso"], .number), ("latitude", [], .number), ("longitude", [], .number), ("lens-model", [], .text), ("light-source", [], .text), ("max-aperture", [], .number),
            ("metering-mode", [], .text), ("orientation", [], .text), ("people", [], .text), ("saturation", [], .text), ("subject", [], .text), ("subject-distance", [], .number),
            ("vertical-resolution", [], .number), ("white-balance", [], .text), ("width", ["wide"], .number), ("color-space", ["colorspace"], .text),
            ("director", [], .text), ("frame-rate", ["fps"], .number), ("video-bitrate", [], .number), ("video-format", ["codec"], .text), ("video-track-count", [], .number),
            ("subtitle-track-count", [], .number), ("writer", [], .text),
            ("container-file-count", [], .number), ("container-filenames", ["container-filename"], .text),
            ("from", [], .text), ("to", [], .text), ("date-received", [], .date), ("date-sent", [], .date),
            ("shortcut-target", ["symlink-target", "link-target", "target"], .text), ("url", [], .text),
        ] as [(String, [String], ValueKind)] { f(n, a, k, n) }
        // Lists / index
        f("filelist", ["file-list"], .list); f("filelist-filename", ["file-list-filename"], .text, "filelist-filename"); f("filelist-full-path", [], .text, "filelist-full-path")
        f("exists", [], .path); f("file-exists", ["fileexists"], .path); f("folder-exists", ["folderexists"], .path); f("network-index-host", [], .text, "network-index-host"); f("include-file-list", [], .directive)
        f("ancestor-file-list", [], .text); f("child-file-list", [], .text); f("exists-in-filelist", [], .flag)
        // Regex capture / eval
        for i in 0...9 { f("regular-expression-match\(i)", ["regmatch\(i)", "regex-match\(i)"], .text, "regmatch\(i)") }
        f("eval", [], .text)
        // Control / UI (directives)
        for d in QueryParser.directiveNames { f(d, [], .directive) }
        return s
    }()

    public static let byCanonical: [String: FunctionSpec] = {
        var m: [String: FunctionSpec] = [:]
        for s in specs { for c in s.allCanonical where m[c] == nil { m[c] = s } }
        return m
    }()

    public static let canonicalNames: Set<String> = Set(byCanonical.keys)

    public static func spec(_ canonical: String) -> FunctionSpec? { byCanonical[canonical] }
}

/// Entry point the parser uses for name resolution; predicate building is in Functions.swift.
public enum Functions {
    public static var canonicalNames: Set<String> { FunctionCatalog.canonicalNames }
}
