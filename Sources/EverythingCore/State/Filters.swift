import Foundation

/// A search filter (Search menu / filter bar). Also provides a macro (`audio:`).
public struct Filter: Equatable, Hashable, Codable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var search: String
    public var macro: String
    public var matchCase: Bool
    public var matchWholeWord: Bool
    public var matchPath: Bool
    public var matchDiacritics: Bool
    public var regex: Bool
    public var matchPrefix: Bool
    public var matchSuffix: Bool
    public var ignorePunctuation: Bool
    public var ignoreWhitespace: Bool
    public var key: String           // keyboard shortcut (e.g. "cmd+1")

    public init(name: String, search: String, macro: String = "", matchCase: Bool = false, matchWholeWord: Bool = false, matchPath: Bool = false,
                matchDiacritics: Bool = false, regex: Bool = false, matchPrefix: Bool = false, matchSuffix: Bool = false, ignorePunctuation: Bool = false,
                ignoreWhitespace: Bool = false, key: String = "") {
        self.name = name; self.search = search; self.macro = macro; self.matchCase = matchCase; self.matchWholeWord = matchWholeWord
        self.matchPath = matchPath; self.matchDiacritics = matchDiacritics; self.regex = regex; self.matchPrefix = matchPrefix
        self.matchSuffix = matchSuffix; self.ignorePunctuation = ignorePunctuation; self.ignoreWhitespace = ignoreWhitespace; self.key = key
    }

    public var defaults: MatchDefaults {
        var d = MatchDefaults()
        d.matchCase = matchCase; d.matchWholeWords = matchWholeWord; d.matchPath = matchPath; d.matchDiacritics = matchDiacritics
        d.regex = regex; d.matchPrefix = matchPrefix; d.matchSuffix = matchSuffix; d.ignorePunctuation = ignorePunctuation; d.ignoreWhitespace = ignoreWhitespace
        return d
    }

    public var isEverything: Bool { name == "Everything" && search.isEmpty }
    public var isSeparator: Bool { search.lowercased().contains("menu-separator:") }
}

/// Default filters (Everything's set, extended with macOS formats).
public enum DefaultFilters {
    public static let audio = "ext:aac;ac3;aif;aifc;aiff;alac;ape;au;caf;cda;dts;fla;flac;it;m1a;m2a;m3u;m3u8;m4a;m4b;m4p;mid;midi;mka;mod;mp2;mp3;mpa;oga;ogg;opus;ra;rmi;s3m;snd;spc;umx;voc;wav;wma;xm"
    public static let compressed = "ext:7z;ace;apk;ar;arj;bz2;cab;cpio;deb;dmg;gz;gzip;ipa;iso;jar;lz;lz4;lzma;pkg;r00;r01;r02;r03;r04;r05;r06;r07;r08;r09;r10;r11;r12;r13;r14;r15;r16;r17;r18;r19;r20;r21;r22;r23;r24;r25;r26;r27;r28;r29;rar;rpm;sit;sitx;tar;tbz;tbz2;tgz;txz;xar;xz;z;zip;zst"
    public static let document = "ext:c;chm;cpp;csv;cxx;doc;docm;docx;dot;dotm;dotx;epub;h;hpp;htm;html;hxx;ini;java;js;json;key;lua;m;md;mht;mhtml;mm;numbers;odp;ods;odt;pages;pdf;plist;potm;potx;ppam;pps;ppsm;ppsx;ppt;pptm;pptx;py;rb;rtf;rtfd;sh;sldm;sldx;swift;tex;thmx;ts;txt;vsd;wpd;wps;wri;xlam;xls;xlsb;xlsm;xlsx;xltm;xltx;xml;yaml;yml"
    public static let executable = "ext:app;appimage;bat;bin;cmd;command;dylib;exe;kext;msi;msp;run;scpt;scr;sh;tool;workflow"
    public static let folder = "folder:"
    public static let picture = "ext:ani;avif;bmp;cr2;dng;gif;heic;heif;icns;ico;jp2;jpe;jpeg;jpg;jxl;nef;pcx;png;psd;raw;svg;tga;tif;tiff;webp;wmf"
    public static let video = "ext:3g2;3gp;3gp2;3gpp;amr;amv;asf;avi;bdmv;bik;d2v;divx;drc;dsa;dsm;dss;dsv;evo;f4v;flc;fli;flic;flv;hdmov;ifo;ivf;m1v;m2p;m2t;m2ts;m2v;m4v;mkv;mov;mp2v;mp4;mp4v;mpe;mpeg;mpg;mpls;mpv2;mpv4;mts;ogm;ogv;pss;pva;qt;ram;ratdvd;rm;rmm;rmvb;roq;rpm;smil;smk;swf;tp;tpr;ts;vob;vp6;webm;wm;wmp;wmv"

    public static var all: [Filter] {
        [
            Filter(name: "Everything", search: "", key: "cmd+0"),
            Filter(name: "Audio", search: audio, macro: "audio", key: "cmd+1"),
            Filter(name: "Compressed", search: compressed, macro: "zip", key: "cmd+2"),
            Filter(name: "Document", search: document, macro: "doc", key: "cmd+3"),
            Filter(name: "Executable", search: executable, macro: "exe", key: "cmd+4"),
            Filter(name: "Folder", search: folder, macro: "", key: "cmd+5"),
            Filter(name: "Picture", search: picture, macro: "image", key: "cmd+6"),
            Filter(name: "Video", search: video, macro: "video", key: "cmd+7"),
        ]
    }

    /// Built-in macro aliases (`pic:` for Picture).
    public static let macroAliases: [String: String] = ["pic": "image", "picture": "image", "audio": "audio", "music": "audio", "doc": "doc", "document": "doc", "exe": "exe", "video": "video", "zip": "zip", "archive": "zip"]
}

/// Filters.csv persistence: `Name,Case,Whole Word,Path,Diacritics,Regex,Search,Macro,Key` (+ 1.5 columns).
public final class FilterStore: @unchecked Sendable {
    public private(set) var filters: [Filter]
    private let lock = NSLock()
    public var onChange: (() -> Void)?

    public init(filters: [Filter] = DefaultFilters.all) { self.filters = filters }

    public static let headers = ["Name", "Case", "Whole Word", "Path", "Diacritics", "Regex", "Search", "Macro", "Key", "Prefix", "Suffix", "Ignore Punctuation", "Ignore Whitespace"]

    public static func load(from url: URL = AppPaths.filtersFile) -> FilterStore {
        guard let t = CSVTable.load(url), t.column("Name") != nil else { return FilterStore() }
        var out: [Filter] = []
        for r in t.rows {
            guard let name = t.value(r, "Name"), !name.isEmpty else { continue }
            func b(_ c: String) -> Bool { INIFile.parseBool(t.value(r, c) ?? "0") ?? false }
            out.append(Filter(name: name, search: t.value(r, "Search") ?? "", macro: t.value(r, "Macro") ?? "", matchCase: b("Case"), matchWholeWord: b("Whole Word"),
                              matchPath: b("Path"), matchDiacritics: b("Diacritics"), regex: b("Regex"), matchPrefix: b("Prefix"), matchSuffix: b("Suffix"),
                              ignorePunctuation: b("Ignore Punctuation"), ignoreWhitespace: b("Ignore Whitespace"), key: t.value(r, "Key") ?? ""))
        }
        return FilterStore(filters: out.isEmpty ? DefaultFilters.all : out)
    }

    public func table() -> CSVTable {
        lock.lock(); defer { lock.unlock() }
        var t = CSVTable(headers: FilterStore.headers)
        for f in filters {
            t.rows.append([f.name, f.matchCase ? "1" : "0", f.matchWholeWord ? "1" : "0", f.matchPath ? "1" : "0", f.matchDiacritics ? "1" : "0", f.regex ? "1" : "0",
                           f.search, f.macro, f.key, f.matchPrefix ? "1" : "0", f.matchSuffix ? "1" : "0", f.ignorePunctuation ? "1" : "0", f.ignoreWhitespace ? "1" : "0"])
        }
        return t
    }

    public func save(to url: URL = AppPaths.filtersFile) throws { try table().write(to: url) }

    public func filter(named name: String) -> Filter? {
        lock.lock(); defer { lock.unlock() }
        return filters.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func set(_ list: [Filter]) { lock.lock(); filters = list; lock.unlock(); onChange?() }
    public func add(_ f: Filter) { lock.lock(); filters.append(f); lock.unlock(); onChange?() }
    public func remove(named name: String) { lock.lock(); filters.removeAll { $0.name == name }; lock.unlock(); onChange?() }
    public func update(_ f: Filter, originalName: String) {
        lock.lock()
        if let i = filters.firstIndex(where: { $0.name == originalName }) { filters[i] = f } else { filters.append(f) }
        lock.unlock(); onChange?()
    }
    public func move(from: Int, to: Int) {
        lock.lock()
        guard from >= 0, from < filters.count, to >= 0, to < filters.count else { lock.unlock(); return }
        let f = filters.remove(at: from); filters.insert(f, at: to)
        lock.unlock(); onChange?()
    }
    public func resetToDefaults() { set(DefaultFilters.all) }

    /// Macro table for the query compiler: canonical macro name → search.
    public var macros: [String: String] {
        lock.lock(); defer { lock.unlock() }
        var m: [String: String] = [:]
        for f in filters where !f.macro.isEmpty {
            let search = f.regex ? "regex:" + f.search : f.search
            m[QueryParser.canonical(f.macro)] = search
        }
        for (alias, target) in DefaultFilters.macroAliases where m[alias] == nil { if let s = m[target] { m[alias] = s } }
        return m
    }
}
