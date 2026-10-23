import Foundation
import CoreServices
import UniformTypeIdentifiers
import Security
import Darwin

public enum PropertyValue: Equatable, Sendable {
    case text(String)
    case number(Double)
    case date(Int64)
    case list([String])
    case bool(Bool)

    public var asText: String {
        switch self {
        case .text(let s): return s
        case .number(let d): return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case .date(let ns): return DateFormat.iso(ns)
        case .list(let l): return l.joined(separator: "; ")
        case .bool(let b): return b ? "Yes" : "No"
        }
    }
    public var asNumber: Double? {
        switch self {
        case .number(let d): return d
        case .text(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        case .date(let ns): return Double(ns)
        case .bool(let b): return b ? 1 : 0
        case .list(let l): return l.first.flatMap { Double($0) }
        }
    }
    public var asDate: Int64? { if case .date(let ns) = self { return ns }; return nil }
    public var asList: [String] {
        switch self {
        case .list(let l): return l
        case .text(let s): return s.isEmpty ? [] : [s]
        default: return [asText]
        }
    }
    public var asBool: Bool {
        switch self {
        case .bool(let b): return b
        case .number(let d): return d != 0
        case .text(let s): return !s.isEmpty && s.lowercased() != "no" && s != "0"
        case .list(let l): return !l.isEmpty
        case .date(let ns): return ns != 0
        }
    }
}

/// Reads non-indexed properties from disk (stat, Spotlight metadata, code signatures, archives, content) with caching.
public final class PropertyReader: @unchecked Sendable {
    private final class Box { let value: PropertyValue?; init(_ v: PropertyValue?) { value = v } }
    private let cache = NSCache<NSString, Box>()
    private let mdCache = NSCache<NSString, MDItem>()
    private let lock = NSLock()
    public var contentSizeLimit = 32 * 1024 * 1024
    private var ownerNames: [uid_t: String] = [:]

    public init(cacheLimit: Int = 100_000) {
        cache.countLimit = cacheLimit
        mdCache.countLimit = 8192
    }

    public func clearCache() { cache.removeAllObjects(); mdCache.removeAllObjects() }
    public func invalidate(path: String) {
        mdCache.removeObject(forKey: path as NSString)
        // Per-property entries are keyed "prop|path"; NSCache cannot enumerate, so entries expire naturally.
    }

    // MARK: public API

    public func value(_ property: String, path: String, isFolder: Bool) -> PropertyValue? {
        let canonical = QueryParser.canonical(property)
        let key = (canonical + "|" + path) as NSString
        if let b = cache.object(forKey: key) { return b.value }
        let v = compute(canonical, path: path, isFolder: isFolder)
        cache.setObject(Box(v), forKey: key)
        return v
    }

    public func text(_ property: String, path: String, isFolder: Bool) -> String? { value(property, path: path, isFolder: isFolder)?.asText }
    public func number(_ property: String, path: String, isFolder: Bool) -> Double? { value(property, path: path, isFolder: isFolder)?.asNumber }
    public func date(_ property: String, path: String, isFolder: Bool) -> Int64? { value(property, path: path, isFolder: isFolder)?.asDate }
    public func list(_ property: String, path: String, isFolder: Bool) -> [String]? { value(property, path: path, isFolder: isFolder)?.asList }

    // MARK: computation

    private func compute(_ p: String, path: String, isFolder: Bool) -> PropertyValue? {
        switch p {
        case "sizeondisk", "allocationsize":
            var st = stat(); guard lstat(path, &st) == 0 else { return nil }
            return .number(Double(st.st_blocks) * 512)
        case "owner":
            var st = stat(); guard lstat(path, &st) == 0 else { return nil }
            return .text(ownerName(st.st_uid))
        case "hardlinkcount":
            var st = stat(); guard lstat(path, &st) == 0 else { return nil }
            return .number(Double(st.st_nlink))
        case "size":
            var st = stat(); guard lstat(path, &st) == 0 else { return nil }
            return .number(Double(st.st_size))
        case "datemodified", "datecreated", "dateaccessed", "datechanged":
            var st = stat(); guard lstat(path, &st) == 0 else { return nil }
            switch p {
            case "datemodified": return .date(Timestamps.fromTimespec(st.st_mtimespec))
            case "datecreated": return .date(Timestamps.fromTimespec(st.st_birthtimespec))
            case "dateaccessed": return .date(Timestamps.fromTimespec(st.st_atimespec))
            default: return .date(Timestamps.fromTimespec(st.st_ctimespec))
            }
        case "xattrcount", "xattrnames", "alternatedatastreamcount", "alternatedatastreamnames", "adscount", "adsnames":
            let names = xattrNames(path)
            return p.contains("count") ? .number(Double(names.count)) : .list(names)
        case "shortcuttarget", "symlinktarget", "linktarget", "target":
            return linkTarget(path).map { .text($0) }
        case "url":
            return urlTarget(path).map { .text($0) }
        case "contenttype", "mime":
            let ut = UTType(filenameExtension: (path as NSString).pathExtension) ?? (isFolder ? .folder : .data)
            return .text(ut.preferredMIMEType ?? ut.identifier)
        case "type":
            if isFolder { return .text(DirectoryLister.isPackageName(Paths.lastComponent(path)) ? "Application" : "Folder") }
            let ext = (path as NSString).pathExtension
            if let ut = UTType(filenameExtension: ext), let d = ut.localizedDescription { return .text(d) }
            return .text(ext.isEmpty ? "File" : ext.uppercased() + " File")
        case "kind":
            return .text(PropertyReader.kind(forPath: path, isFolder: isFolder))
        case "perceivedtype":
            return .text(PropertyReader.perceivedType(forPath: path, isFolder: isFolder))
        case "filesignature":
            return .text(PropertyReader.fileSignature(path: path))
        case "characterencoding", "encoding":
            guard let d = ContentSearch.read(path: path, limit: 65536) else { return nil }
            return .text(ContentSearch.detectEncoding(d))
        case "linecount":
            return ContentSearch.counts(path: path, limit: contentSizeLimit).map { .number(Double($0.lines)) }
        case "wordcount":
            return ContentSearch.counts(path: path, limit: contentSizeLimit).map { .number(Double($0.words)) }
        case "crc32", "crc64", "md5", "sha1", "sha256", "sha512":
            guard !isFolder, let algo = HashAlgorithm(rawValue: p) else { return nil }
            return Hashes.hex(algo, path: path).map { .text($0) }
        case "digitalsignaturename", "signaturename", "codesignature":
            return codeSignature(path: path).map { .text($0.authority) }
        case "digitalsignaturetimestamp":
            return codeSignature(path: path)?.timestamp.map { .date($0) }
        case "isrunning":
            return .bool(PropertyReader.isRunning(path: path))
        case "productname":
            return bundleInfo(path: path, key: "CFBundleName") ?? bundleInfo(path: path, key: "CFBundleDisplayName")
        case "productversion":
            return bundleInfo(path: path, key: "CFBundleShortVersionString")
        case "version":
            return bundleInfo(path: path, key: "CFBundleVersion") ?? spotlight(path, "kMDItemVersion")
        case "containerfilecount":
            return ArchiveLister.entries(path: path).map { .number(Double($0.count)) }
        case "containerfilenames", "containerfilename":
            return ArchiveLister.entries(path: path).map { .list($0) }
        case "dimensions":
            guard let w = spotlight(path, "kMDItemPixelWidth")?.asNumber, let h = spotlight(path, "kMDItemPixelHeight")?.asNumber else { return nil }
            return .text("\(Int(w))x\(Int(h))")
        case "aspectratio":
            guard let w = spotlight(path, "kMDItemPixelWidth")?.asNumber, let h = spotlight(path, "kMDItemPixelHeight")?.asNumber, h > 0 else { return nil }
            return .number(w / h)
        case "orientation":
            guard let o = spotlight(path, "kMDItemOrientation")?.asNumber else { return nil }
            return .text(o == 1 ? "Portrait" : "Landscape")
        case "from", "to", "subject", "datesent", "datereceived":
            if let v = emailHeader(path: path, property: p) { return v }
            return spotlightProperty(p, path: path)
        case "tags", "tag":
            if let t = spotlight(path, "kMDItemUserTags") { return t }
            return spotlight(path, "kMDItemKeywords")
        default:
            return spotlightProperty(p, path: path)
        }
    }

    private func spotlightProperty(_ canonical: String, path: String) -> PropertyValue? {
        guard let prop = PropertyCatalog.byCanonical[canonical], case .spotlight(let key) = prop.source else { return nil }
        return spotlight(path, key)
    }

    // MARK: Spotlight

    public func spotlight(_ path: String, _ key: String) -> PropertyValue? {
        let k = path as NSString
        var item = mdCache.object(forKey: k)
        if item == nil {
            guard let created = MDItemCreate(nil, path as CFString) else { return nil }
            item = created
            mdCache.setObject(created, forKey: k)
        }
        guard let raw = MDItemCopyAttribute(item, key as CFString) else { return nil }
        return PropertyReader.convert(raw as AnyObject)
    }

    static func convert(_ raw: AnyObject) -> PropertyValue? {
        if let s = raw as? String { return .text(s) }
        if let n = raw as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        }
        if let d = raw as? Date { return .date(Timestamps.fromDate(d)) }
        if let a = raw as? [Any] { return .list(a.map { ($0 as? String) ?? "\($0)" }) }
        return .text("\(raw)")
    }

    // MARK: helpers

    private func ownerName(_ uid: uid_t) -> String {
        lock.lock(); defer { lock.unlock() }
        if let n = ownerNames[uid] { return n }
        let name = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? String(uid)
        ownerNames[uid] = name
        return name
    }

    private func xattrNames(_ path: String) -> [String] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var buf = [CChar](repeating: 0, count: size)
        let n = listxattr(path, &buf, size, XATTR_NOFOLLOW)
        guard n > 0 else { return [] }
        return buf[0..<n].split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }

    private func linkTarget(_ path: String) -> String? {
        if let t = try? FileManager.default.destinationOfSymbolicLink(atPath: path) { return t }
        let url = URL(fileURLWithPath: path)
        if let v = try? url.resourceValues(forKeys: [.isAliasFileKey]), v.isAliasFile == true, let r = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]) {
            return r.path
        }
        return nil
    }

    private func urlTarget(_ path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "webloc" || ext == "inetloc" {
            if let d = FileManager.default.contents(atPath: path), let plist = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] {
                return plist["URL"] as? String
            }
        }
        if ext == "url", let text = try? String(contentsOfFile: path, encoding: .utf8) {
            for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) where line.hasPrefix("URL=") { return String(line.dropFirst(4)) }
        }
        return nil
    }

    private func bundleInfo(path: String, key: String) -> PropertyValue? {
        guard let b = Bundle(path: path), let v = b.object(forInfoDictionaryKey: key) else { return nil }
        return PropertyReader.convert(v as AnyObject)
    }

    private struct Signature { let authority: String; let timestamp: Int64? }
    private func codeSignature(path: String) -> Signature? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let c = code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(c, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess, let d = info as? [String: Any] else { return nil }
        var authority = ""
        if let certs = d[kSecCodeInfoCertificates as String] as? [SecCertificate], let first = certs.first {
            var cn: CFString?
            if SecCertificateCopyCommonName(first, &cn) == errSecSuccess, let s = cn as String? { authority = s }
        }
        if authority.isEmpty, let team = d[kSecCodeInfoTeamIdentifier as String] as? String { authority = team }
        if authority.isEmpty, let ident = d[kSecCodeInfoIdentifier as String] as? String { authority = ident }
        guard !authority.isEmpty else { return nil }
        let ts = (d[kSecCodeInfoTimestamp as String] as? Date).map { Timestamps.fromDate($0) }
        return Signature(authority: authority, timestamp: ts)
    }

    static func isRunning(path: String) -> Bool {
        let n = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard n > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(n) / MemoryLayout<pid_t>.size + 1)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let target = path.hasSuffix(".app") ? path + "/" : path
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(got) / MemoryLayout<pid_t>.size) where pid > 0 {
            let r = proc_pidpath(pid, &buf, UInt32(buf.count))
            if r > 0 {
                let p = String(cString: buf)
                if p == path || p.hasPrefix(target) { return true }
            }
        }
        return false
    }

    private func emailHeader(path: String, property: String) -> PropertyValue? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard ext == "eml" || ext == "emlx" || ext == "msg" || ext == "mbox" else { return nil }
        guard let data = ContentSearch.read(path: path, limit: 65536) else { return nil }
        let text = ContentSearch.decode(data, encoding: .auto)
        let header: String
        switch property {
        case "from": header = "from"
        case "to": header = "to"
        case "subject": header = "subject"
        default: header = "date"
        }
        var value: String? = nil
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = String(rawLine)
            if line.isEmpty { break }
            if let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == header {
                value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard let v = value else { return nil }
        if header == "date" {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
            if let d = f.date(from: v) { return .date(Timestamps.fromDate(d)) }
            return nil
        }
        return .text(v)
    }

    // MARK: kind / signature tables

    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "heic", "heif", "webp", "psd", "svg", "ico", "icns", "raw", "cr2", "nef", "arw", "dng", "jp2", "pcx", "tga", "wmf", "ani", "avif", "jxl"]
    static let audioExts: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "aifc", "flac", "ogg", "oga", "wma", "alac", "opus", "mid", "midi", "m4b", "m4p", "caf", "ac3", "dts", "au", "snd", "mka", "mpa", "mp2", "ra", "cda", "it", "mod", "xm", "s3m", "umx", "voc", "spc", "m3u", "m3u8"]
    static let videoExts: Set<String> = ["mp4", "m4v", "mov", "avi", "mkv", "wmv", "flv", "webm", "mpg", "mpeg", "m2ts", "mts", "ts", "3gp", "3g2", "ogv", "vob", "divx", "asf", "rm", "rmvb", "mpe", "m2v", "m1v", "mp2v", "mp4v", "f4v", "hdmov", "ifo", "qt", "swf", "wm", "wmp", "amv", "bik", "evo", "dsm", "dsv", "dsa", "dss", "ogm", "pva", "tp", "tpr", "mpls", "bdmv", "smk", "roq", "pss", "ratdvd", "rmm", "smil", "d2v", "drc", "flc", "fli", "flic", "ivf", "m2p", "m2t", "vp6"]
    static let documentExts: Set<String> = ["doc", "docx", "docm", "dot", "dotx", "dotm", "pdf", "txt", "rtf", "rtfd", "odt", "pages", "numbers", "key", "xls", "xlsx", "xlsm", "xlsb", "xlam", "xltx", "xltm", "ppt", "pptx", "pptm", "pps", "ppsx", "ppsm", "potx", "potm", "ppam", "sldx", "sldm", "thmx", "csv", "tsv", "md", "markdown", "htm", "html", "mht", "mhtml", "xml", "json", "yaml", "yml", "ini", "cfg", "conf", "log", "tex", "epub", "mobi", "chm", "wpd", "wps", "wri", "vsd", "c", "cpp", "cxx", "h", "hpp", "hxx", "m", "mm", "swift", "java", "kt", "js", "ts", "py", "rb", "go", "rs", "cs", "php", "lua", "sh", "zsh", "bash", "pl", "sql", "plist", "strings"]
    static let compressedExts: Set<String> = ["zip", "7z", "rar", "tar", "gz", "gzip", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "lz", "lzma", "lz4", "zst", "z", "cab", "arj", "ace", "jar", "war", "iso", "dmg", "pkg", "sit", "sitx", "cpio", "ar", "deb", "rpm", "apk", "ipa", "xar", "r00", "r01", "r02", "r03"]
    static let executableExts: Set<String> = ["app", "command", "tool", "exe", "bat", "cmd", "msi", "msp", "scr", "sh", "dylib", "so", "kext", "action", "workflow", "scpt", "applescript", "bin", "run", "appimage"]

    public static func kind(forPath path: String, isFolder: Bool) -> String {
        let name = Paths.lastComponent(path)
        let ext = ItemStore.extensionOf(name).lowercased()
        if isFolder { return DirectoryLister.isPackageName(name) ? (ext == "app" ? "Program" : "Package") : "Folder" }
        if imageExts.contains(ext) { return "Picture" }
        if audioExts.contains(ext) { return "Music" }
        if videoExts.contains(ext) { return "Video" }
        if compressedExts.contains(ext) { return "Compressed" }
        if executableExts.contains(ext) { return "Program" }
        if documentExts.contains(ext) { return "Document" }
        if let ut = UTType(filenameExtension: ext) {
            if ut.conforms(to: .image) { return "Picture" }
            if ut.conforms(to: .audio) { return "Music" }
            if ut.conforms(to: .movie) || ut.conforms(to: .video) { return "Video" }
            if ut.conforms(to: .archive) { return "Compressed" }
            if ut.conforms(to: .executable) || ut.conforms(to: .application) { return "Program" }
            if ut.conforms(to: .text) || ut.conforms(to: .content) || ut.conforms(to: .sourceCode) { return "Document" }
            if ut.conforms(to: .font) { return "Font" }
        }
        return "File"
    }

    public static func perceivedType(forPath path: String, isFolder: Bool) -> String {
        switch kind(forPath: path, isFolder: isFolder) {
        case "Folder": return "folder"
        case "Picture": return "image"
        case "Music": return "audio"
        case "Video": return "video"
        case "Compressed": return "compressed"
        case "Program", "Package": return "application"
        case "Document":
            let ext = ItemStore.extensionOf(Paths.lastComponent(path)).lowercased()
            return ["txt", "md", "log", "c", "cpp", "h", "swift", "py", "js", "json", "xml", "yaml", "yml", "csv", "ini", "cfg", "sh"].contains(ext) ? "text" : "document"
        default: return "unknown"
        }
    }

    static let signatures: [([UInt8], String)] = [
        ([0x89, 0x50, 0x4E, 0x47], "PNG"), ([0xFF, 0xD8, 0xFF], "JPEG"), ([0x47, 0x49, 0x46, 0x38], "GIF"), ([0x25, 0x50, 0x44, 0x46], "PDF"),
        ([0x50, 0x4B, 0x03, 0x04], "ZIP"), ([0x50, 0x4B, 0x05, 0x06], "ZIP"), ([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], "7-Zip"), ([0x52, 0x61, 0x72, 0x21], "RAR"),
        ([0x1F, 0x8B], "GZIP"), ([0x42, 0x5A, 0x68], "BZIP2"), ([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00], "XZ"), ([0x4D, 0x5A], "Windows Executable"),
        ([0xCF, 0xFA, 0xED, 0xFE], "Mach-O 64"), ([0xCE, 0xFA, 0xED, 0xFE], "Mach-O 32"), ([0xCA, 0xFE, 0xBA, 0xBE], "Mach-O Universal"), ([0x7F, 0x45, 0x4C, 0x46], "ELF"),
        ([0x49, 0x44, 0x33], "MP3 (ID3)"), ([0xFF, 0xFB], "MP3"), ([0x66, 0x4C, 0x61, 0x43], "FLAC"), ([0x4F, 0x67, 0x67, 0x53], "OGG"), ([0x52, 0x49, 0x46, 0x46], "RIFF"),
        ([0x42, 0x4D], "BMP"), ([0x49, 0x49, 0x2A, 0x00], "TIFF"), ([0x4D, 0x4D, 0x00, 0x2A], "TIFF"), ([0x38, 0x42, 0x50, 0x53], "PSD"),
        ([0x53, 0x51, 0x4C, 0x69, 0x74, 0x65], "SQLite"), ([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74], "Binary Plist"), ([0x3C, 0x3F, 0x78, 0x6D, 0x6C], "XML"),
        ([0x1A, 0x45, 0xDF, 0xA3], "Matroska/WebM"), ([0x00, 0x00, 0x01, 0xBA], "MPEG-PS"), ([0x00, 0x00, 0x01, 0xB3], "MPEG Video"), ([0x46, 0x4C, 0x56], "FLV"),
        ([0x4D, 0x54, 0x68, 0x64], "MIDI"), ([0x25, 0x21, 0x50, 0x53], "PostScript"), ([0x7B, 0x5C, 0x72, 0x74, 0x66], "RTF"), ([0xD0, 0xCF, 0x11, 0xE0], "OLE Compound (MS Office)"),
        ([0x75, 0x73, 0x74, 0x61, 0x72], "TAR"), ([0x21, 0x3C, 0x61, 0x72, 0x63, 0x68, 0x3E], "AR/DEB"), ([0x78, 0x61, 0x72, 0x21], "XAR/PKG"), ([0x00, 0x61, 0x73, 0x6D], "WebAssembly"),
        ([0x23, 0x21], "Script"), ([0xEF, 0xBB, 0xBF], "UTF-8 Text"), ([0xFF, 0xFE], "UTF-16 Text"), ([0x52, 0x49, 0x46, 0x46], "WAV/AVI"),
    ]

    public static func fileSignature(path: String) -> String {
        guard let d = ContentSearch.read(path: path, limit: 16), !d.isEmpty else { return "" }
        let bytes = [UInt8](d)
        if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) { return "MP4/MOV/HEIC" }
        for (sig, name) in signatures where bytes.count >= sig.count && Array(bytes[0..<sig.count]) == sig { return name }
        return bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) ? "Text" : "Binary"
    }
}

/// Lists file names inside zip and tar archives (for `container-file-count:` / `container-filenames:`).
public enum ArchiveLister {
    public static func entries(path: String) -> [String]? {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "zip", "jar", "war", "apk", "ipa", "xpi", "docx", "xlsx", "pptx", "epub", "odt", "ods", "odp", "pages", "numbers", "key": return zipEntries(path: path)
        case "tar": return tarEntries(path: path)
        default: return nil
        }
    }

    static func zipEntries(path: String) -> [String]? {
        guard let fh = FileHandle(forReadingAtPath: path), let size = try? fh.seekToEnd(), size >= 22 else { return nil }
        defer { try? fh.close() }
        let tailLen = min(size, 65_557)
        try? fh.seek(toOffset: size - tailLen)
        guard let tail = try? fh.readToEnd() else { return nil }
        // find EOCD signature 0x06054b50 scanning backwards
        var eocd = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail[tail.startIndex + i] == 0x50, tail[tail.startIndex + i + 1] == 0x4B, tail[tail.startIndex + i + 2] == 0x05, tail[tail.startIndex + i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        func u16(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 }
        func u32(_ d: Data, _ o: Int) -> Int { u16(d, o) | u16(d, o + 2) << 16 }
        let count = u16(tail, eocd + 10)
        let cdSize = u32(tail, eocd + 12)
        let cdOffset = u32(tail, eocd + 16)
        guard cdSize < 64 * 1024 * 1024, UInt64(cdOffset) < size else { return nil }
        try? fh.seek(toOffset: UInt64(cdOffset))
        guard let cd = try? fh.read(upToCount: cdSize) else { return nil }
        var names: [String] = []
        var p = 0
        while p + 46 <= cd.count, names.count < max(count, 1) {
            guard u32(cd, p) == 0x02014b50 else { break }
            let nameLen = u16(cd, p + 28), extraLen = u16(cd, p + 30), commentLen = u16(cd, p + 32)
            let flags = u16(cd, p + 8)
            let nameData = cd[(cd.startIndex + p + 46)..<(cd.startIndex + p + 46 + nameLen)]
            let name = (flags & 0x800 != 0 ? String(data: nameData, encoding: .utf8) : String(data: nameData, encoding: .windowsCP1252)) ?? String(decoding: nameData, as: UTF8.self)
            names.append(name)
            p += 46 + nameLen + extraLen + commentLen
        }
        return names
    }

    static func tarEntries(path: String) -> [String]? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var names: [String] = []
        var offset: UInt64 = 0
        while names.count < 100_000 {
            try? fh.seek(toOffset: offset)
            guard let header = try? fh.read(upToCount: 512), header.count == 512 else { break }
            if header.allSatisfy({ $0 == 0 }) { break }
            let nameData = header.prefix(100).prefix { $0 != 0 }
            var name = String(decoding: nameData, as: UTF8.self)
            let prefixData = header[(header.startIndex + 345)..<(header.startIndex + 500)].prefix { $0 != 0 }
            if !prefixData.isEmpty { name = String(decoding: prefixData, as: UTF8.self) + "/" + name }
            let sizeField = String(decoding: header[(header.startIndex + 124)..<(header.startIndex + 136)].prefix { $0 != 0 && $0 != 0x20 }, as: UTF8.self)
            let size = UInt64(sizeField, radix: 8) ?? 0
            if !name.isEmpty { names.append(name) }
            offset += 512 + ((size + 511) / 512) * 512
        }
        return names
    }
}
