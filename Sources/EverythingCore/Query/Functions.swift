import Foundation

/// Everything the compiler needs besides the parsed query.
public struct CompileEnv {
    public var defaults = MatchDefaults()
    public var wholeFilenameForWildcards = true
    public var sizeStandard: SizeStandard = .jedec
    public var pinyinDefault = false
    /// Canonical macro name → search text (from filters with a macro).
    public var macros: [String: String] = [:]
    public var fileListSlots: [Int: [String]] = [:]
    public var contentSizeLimit = 32 * 1024 * 1024
    public var now = Date()
    /// Used to resolve parent:/ancestor:/exists: at compile time.
    public var index: Index? = nil
    public var parseOptions = ParseOptions()
    var depth = 0

    public init() {}
}

public struct Highlighter: Sendable {
    public let scope: TextScope
    public let matcher: TextMatcher
}

public final class CompiledQuery: @unchecked Sendable {
    public let parsed: ParsedQuery
    public let predicate: Predicate
    public let highlighters: [Highlighter]
    public let errors: [String]
    public let noReorder: Bool
    public var directives: [UIDirective] { parsed.directives }
    public var usesDisk: Bool { predicate.cost >= 100 }
    public var text: String { parsed.original }

    init(parsed: ParsedQuery, predicate: Predicate, highlighters: [Highlighter], errors: [String], noReorder: Bool) {
        self.parsed = parsed; self.predicate = predicate; self.highlighters = highlighters; self.errors = errors; self.noReorder = noReorder
    }
}

public enum QueryCompiler {
    public static func compile(_ text: String, env: CompileEnv) -> CompiledQuery {
        var opts = env.parseOptions
        opts.defaults = env.defaults
        opts.macroNames = Set(env.macros.keys)
        return compile(QueryParser(options: opts).parse(text), env: env)
    }

    public static func compile(_ parsed: ParsedQuery, env: CompileEnv) -> CompiledQuery {
        var state = CompileState(env: env)
        let pred = state.compile(parsed.root)
        return CompiledQuery(parsed: parsed, predicate: pred, highlighters: state.highlighters, errors: state.errors, noReorder: state.noReorder)
    }
}

// MARK: - Compile state

struct CompileState {
    let env: CompileEnv
    var highlighters: [Highlighter] = []
    var errors: [String] = []
    var noReorder = false
    var lastRegex: (scope: TextScope, matcher: TextMatcher)? = nil

    init(env: CompileEnv) { self.env = env }

    mutating func compile(_ node: QueryNode) -> Predicate {
        switch node {
        case .empty: return AllPredicate()
        case .term(let t): return compileTerm(t)
        case .not(let n):
            let before = highlighters.count
            let p = compile(n)
            highlighters.removeSubrange(before...)   // negated terms are not highlighted
            return NotPredicate(p)
        case .and(let a):
            let ps = a.map { compile($0) }
            return AndPredicate(ps, reorder: !noReorder)
        case .or(let a):
            let ps = a.map { compile($0) }
            return OrPredicate(ps, reorder: !noReorder)
        }
    }

    func mode(_ t: Term) -> MatchMode {
        MatchMode(defaults: env.defaults, modifiers: t.modifiers, wholeFilenameForWildcards: env.wholeFilenameForWildcards, pinyinDefault: env.pinyinDefault)
    }

    mutating func matcher(_ t: Term, pattern: String? = nil) -> TextMatcher {
        let m = TextMatcher(pattern: pattern ?? t.value, mode: mode(t))
        if let e = m.compileError { errors.append(e) }
        return m
    }

    func textScope(_ t: Term) -> TextScope {
        (t.modifiers.path ?? env.defaults.matchPath) ? .fullPath : .name
    }

    mutating func textPredicate(_ t: Term, scope: TextScope, pattern: String? = nil, highlight: Bool = true) -> Predicate {
        if t.modifiers.len {
            guard let range = ValueParser.parseNumber(t.value) else { return NonePredicate() }
            return ClosurePredicate(cost: 5) { id, ctx in
                let s = CompileState.scopeString(scope, id, ctx)
                return range.contains(Int64(s.utf16.count))
            }
        }
        let m = matcher(t, pattern: pattern)
        if m.mode.regex { lastRegex = (scope, m) }
        if highlight && !t.modifiers.noHighlight && !t.value.isEmpty { highlighters.append(Highlighter(scope: scope, matcher: m)) }
        var pred: Predicate = TextPredicate(matcher: m, scope: scope)
        if t.modifiers.fileOnly { pred = AndPredicate([FlagPredicate(files: true), pred]) }
        if t.modifiers.folderOnly { pred = AndPredicate([FlagPredicate(files: false), pred]) }
        return pred
    }

    static func scopeString(_ scope: TextScope, _ id: ItemID, _ ctx: EvalContext) -> String {
        switch scope {
        case .name: return ctx.store.name(id)
        case .stem: return ctx.store.stem(id)
        case .ext: return ctx.store.extensionName(id)
        case .fullPath: return ctx.fullPath(id)
        case .parentPath: return ctx.parentPath(id)
        }
    }

    // MARK: terms

    mutating func compileTerm(_ t: Term) -> Predicate {
        if t.modifiers.noReorder { noReorder = true }
        guard let fn = t.function else {
            // Plain text (or modifier-only term such as `file:`).
            if t.value.isEmpty && !t.quoted {
                if t.modifiers.fileOnly { return FlagPredicate(files: true) }
                if t.modifiers.folderOnly { return FlagPredicate(files: false) }
                return AllPredicate()
            }
            return textPredicate(t, scope: textScope(t))
        }
        if fn.hasPrefix("macro:") { return compileMacro(String(fn.dropFirst(6)), t) }
        return compileFunction(fn, t)
    }

    mutating func compileMacro(_ name: String, _ t: Term) -> Predicate {
        guard env.depth < 8, let search = env.macros[name] else { errors.append("Unknown macro \(name):"); return NonePredicate() }
        var sub = env
        sub.depth += 1
        var opts = sub.parseOptions
        opts.defaults = env.defaults
        opts.macroNames = Set(env.macros.keys)
        let parsed = QueryParser(options: opts).parse(search)
        var inner = CompileState(env: sub)
        var pred = inner.compile(parsed.root)
        errors.append(contentsOf: inner.errors)
        if !t.value.isEmpty {
            var tt = t; tt.function = nil
            pred = AndPredicate([pred, textPredicate(tt, scope: textScope(tt))])
        }
        return pred
    }

    mutating func compileFunction(_ fn: String, _ t: Term) -> Predicate {
        let v = t.value.trimmingCharacters(in: .whitespaces)
        let m = t.modifiers
        switch fn {
        // MARK: name / path scopes
        case "name": return textPredicate(t, scope: .name)
        case "stem", "namepart": return textPredicate(t, scope: .stem)
        case "extension": return textPredicate(t, scope: .ext, highlight: false)
        case "path", "fullpath", "fullpathandname": return textPredicate(t, scope: .fullPath)
        case "location", "loc": return textPredicate(t, scope: .parentPath)
        case "ext":
            let store = env.index?.store
            var ids = Set<UInt16>()
            var matchers: [String] = []
            for item in ValueParser.list(v) {
                let e = item.hasPrefix(".") ? String(item.dropFirst()) : item
                if let s = store { ids.formUnion(s.extensions.ids(matching: e)) } else { matchers.append(e.lowercased()) }
            }
            if store != nil {
                if v.isEmpty { return ClosurePredicate(cost: 1) { id, ctx in ctx.store.extensionID(id) != 0 } }
                // resolve lazily too, so extensions added after compile still match
                let patterns = ValueParser.list(v).map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
                return ExtensionPredicate(initial: ids, patterns: patterns)
            }
            return ClosurePredicate(cost: 2) { id, ctx in matchers.contains(ctx.store.extensionName(id).lowercased()) }
        case "namelength", "namelen":
            guard let r = ValueParser.parseNumber(v) else { return NonePredicate() }
            return ClosurePredicate(cost: 2) { id, ctx in r.contains(Int64(ctx.store.name(id).utf16.count)) }
        case "fullpathlength", "fullpathlen", "pathlen", "pathlength":
            guard let r = ValueParser.parseNumber(v) else { return NonePredicate() }
            return ClosurePredicate(cost: 10) { id, ctx in r.contains(Int64(ctx.fullPath(id).utf16.count)) }

        // MARK: hierarchy
        case "parent":
            return parentPredicate(v, ancestor: false)
        case "ancestor":
            return parentPredicate(v, ancestor: true)
        case "parentname":
            let mt = matcher(t)
            return ClosurePredicate(cost: 3) { id, ctx in
                let p = ctx.store.parent(id); return p != invalidItem && mt.matches(ctx.store.name(p))
            }
        case "ancestorname":
            let mt = matcher(t)
            return ClosurePredicate(cost: 5) { id, ctx in
                var p = ctx.store.parent(id)
                while p != invalidItem { if mt.matches(ctx.store.name(p)) { return true }; p = ctx.store.parent(p) }
                return false
            }
        case "child", "childfile", "childfolder":
            let mt = matcher(t)
            let onlyFiles = fn == "childfile", onlyFolders = fn == "childfolder"
            return ClosurePredicate(cost: 8) { id, ctx in
                let s = ctx.store
                guard s.isFolder(id) else { return false }
                var hit = false
                s.forEachChild(of: id) { c in
                    if hit { return }
                    if onlyFiles && s.isFolder(c) { return }
                    if onlyFolders && !s.isFolder(c) { return }
                    if mt.usesFoldedBytes { if s.withUnicodeFoldedBytes(c, { mt.matchesFolded($0) }) { hit = true } }
                    else if mt.matches(s.name(c)) { hit = true }
                }
                return hit
            }
        case "descendant", "descendantfile", "descendantfolder":
            let mt = matcher(t)
            let onlyFiles = fn == "descendantfile", onlyFolders = fn == "descendantfolder"
            return ClosurePredicate(cost: 30) { id, ctx in
                let s = ctx.store
                guard s.isFolder(id) else { return false }
                var stack: [ItemID] = [id]
                while let cur = stack.popLast() {
                    var hit = false
                    s.forEachChild(of: cur) { c in
                        if hit { return }
                        let f = s.isFolder(c)
                        if f { stack.append(c) }
                        if onlyFiles && f { return }
                        if onlyFolders && !f { return }
                        if mt.matches(s.name(c)) { hit = true }
                    }
                    if hit { return true }
                }
                return false
            }
        case "sibling", "siblingfile", "siblingfolder":
            let mt = matcher(t)
            let onlyFiles = fn == "siblingfile", onlyFolders = fn == "siblingfolder"
            return ClosurePredicate(cost: 8) { id, ctx in
                let s = ctx.store
                let p = s.parent(id); guard p != invalidItem else { return false }
                var hit = false
                s.forEachChild(of: p) { c in
                    if hit || c == id { return }
                    if onlyFiles && s.isFolder(c) { return }
                    if onlyFolders && !s.isFolder(c) { return }
                    if mt.matches(s.name(c)) { hit = true }
                }
                return hit
            }
        case "childcount", "childfilecount", "childfoldercount", "descendantcount", "descendantfilecount", "descendantfoldercount":
            guard let r = ValueParser.parseNumber(v) else { return NonePredicate() }
            let prop = fn
            return ClosurePredicate(cost: fn.hasPrefix("descendant") ? 40 : 3) { id, ctx in
                guard ctx.store.isFolder(id) else { return false }
                let n = PropertyAccess.value(prop, id: id, ctx: ctx)?.asNumber ?? 0
                return r.contains(Int64(n))
            }
        case "parentcount", "depth":
            guard let r = ValueParser.parseNumber(v) else { return NonePredicate() }
            return ClosurePredicate(cost: 2) { id, ctx in r.contains(Int64(ctx.store.depth(id))) }
        case "empty":
            return ClosurePredicate(cost: 1) { id, ctx in ctx.store.isFolder(id) && ctx.store.childCount(id) == 0 }
        case "root":
            return ClosurePredicate(cost: 1) { id, ctx in ctx.store.flags(id).contains(.root) }
        case "file", "files": return FlagPredicate(files: true)
        case "folder", "folders": return FlagPredicate(files: false)

        // MARK: size & dates
        case "size":
            guard let r = ValueParser.parseSize(v, standard: m.metric == true ? .metric : env.sizeStandard) else { errors.append("Invalid size"); return NonePredicate() }
            if m.fromDisk || m.notIndexed {
                return ClosurePredicate(cost: 100) { id, ctx in
                    let n = ctx.properties.number("size", path: ctx.fullPath(id), isFolder: ctx.store.isFolder(id))
                    return r.contains(Int64(n ?? 0), known: n != nil)
                }
            }
            return ClosurePredicate(cost: 1) { id, ctx in
                let s = ctx.store
                if s.isFolder(id) && !s.trackFolderSize { return r.unknown }
                return r.contains(Int64(s.size(id)))
            }
        case "sizeondisk", "allocationsize":
            guard let r = ValueParser.parseSize(v, standard: env.sizeStandard) else { return NonePredicate() }
            return ClosurePredicate(cost: 100) { id, ctx in
                let n = ctx.properties.number("sizeondisk", path: ctx.fullPath(id), isFolder: ctx.store.isFolder(id))
                return r.contains(Int64(n ?? 0), known: n != nil)
            }
        case "datemodified", "datecreated", "dateaccessed", "datechanged", "daterecentlychanged", "daterun", "dateadded", "datedeleted":
            guard let r = ValueParser.parseDate(v, now: env.now) else { errors.append("Invalid date"); return NonePredicate() }
            let prop = fn
            let fromDisk = m.fromDisk || m.notIndexed
            let cost = (prop == "dateadded" || prop == "datedeleted" || fromDisk) ? 100 : (prop == "daterun" || prop == "daterecentlychanged" ? 10 : 1)
            return ClosurePredicate(cost: cost) { id, ctx in
                let ns: Int64
                if fromDisk && (prop == "datemodified" || prop == "datecreated" || prop == "dateaccessed" || prop == "datechanged") {
                    ns = ctx.properties.date(prop, path: ctx.fullPath(id), isFolder: ctx.store.isFolder(id)) ?? 0
                } else if prop == "datedeleted" {
                    let p = ctx.fullPath(id)
                    ns = p.contains("/.Trash/") ? (ctx.properties.date("dateadded", path: p, isFolder: ctx.store.isFolder(id)) ?? 0) : 0
                } else {
                    ns = PropertyAccess.value(prop, id: id, ctx: ctx)?.asDate ?? 0
                }
                return r.contains(ns)
            }
        case let f where f.hasPrefix("date") && (f.hasSuffix("date") || f.hasSuffix("day") || f.hasSuffix("dayofweek") || f.hasSuffix("hour") || f.hasSuffix("month") || f.hasSuffix("time") || f.hasSuffix("year")) && FunctionCatalog.spec(f) != nil:
            return datePartPredicate(f, v)
        case "runcount":
            guard let r = ValueParser.parseNumber(v) else { return NonePredicate() }
            return ClosurePredicate(cost: 10) { id, ctx in r.contains(Int64(ctx.runHistory?.runCount(forPath: ctx.fullPath(id)) ?? 0)) }

        // MARK: attributes / flags
        case "attributes", "attrib", "attr":
            guard let flags = CompileState.parseAttributes(v) else { errors.append("Invalid attributes"); return NonePredicate() }
            if v.isEmpty { return AllPredicate() }
            return ClosurePredicate(cost: 1) { id, ctx in ctx.store.flags(id).isSuperset(of: flags) }
        case "ancestorattributes", "ancestorattrib":
            guard let flags = CompileState.parseAttributes(v) else { return NonePredicate() }
            return ClosurePredicate(cost: 4) { id, ctx in
                var p = ctx.store.parent(id)
                while p != invalidItem { if ctx.store.flags(p).isSuperset(of: flags) { return true }; p = ctx.store.parent(p) }
                return false
            }
        case "childattributes", "childattrib":
            guard let flags = CompileState.parseAttributes(v) else { return NonePredicate() }
            return ClosurePredicate(cost: 8) { id, ctx in
                var hit = false
                ctx.store.forEachChild(of: id) { if !hit && ctx.store.flags($0).isSuperset(of: flags) { hit = true } }
                return hit
            }
        case "offline": return ClosurePredicate(cost: 1) { id, ctx in ctx.store.flags(id).contains(.offline) }
        case "online": return ClosurePredicate(cost: 1) { id, ctx in !ctx.store.flags(id).contains(.offline) }
        case "fileid", "frn", "inode":
            guard let r = ValueParser.parseNumber(v) ?? ValueParser.parseInteger(v).map({ NumRange.exact($0) }) else { return NonePredicate() }
            return ClosurePredicate(cost: 1) { id, ctx in r.contains(Int64(bitPattern: ctx.store.inode(id))) }
        case "parentfileid", "parentfrn":
            guard let r = ValueParser.parseNumber(v) else { return NonePredicate() }
            return ClosurePredicate(cost: 1) { id, ctx in let p = ctx.store.parent(id); return p != invalidItem && r.contains(Int64(bitPattern: ctx.store.inode(p))) }
        case "volumelabel", "volume":
            let mt = matcher(t)
            return ClosurePredicate(cost: 3) { id, ctx in ctx.index.root(containing: id).map { mt.matches($0.label) } ?? false }
        case "networkindexhost":
            let mt = matcher(t)
            return ClosurePredicate(cost: 3) { id, ctx in ctx.index.root(containing: id).map { $0.kind == .network && mt.matches($0.path) } ?? false }
        case "filelistfilename", "filelistfullpath":
            let mt = matcher(t)
            return ClosurePredicate(cost: 3) { id, ctx in ctx.fileListFilenames[ctx.store.root(of: id)].map { mt.matches($0) } ?? false }

        // MARK: lists
        case "filelist", "filelist0", "filelist1", "filelist2", "filelist3", "filelist4", "filelist5", "filelist6", "filelist7", "filelist8", "filelist9":
            var entries = ValueParser.list(v)
            if fn.count == 9, let slot = Int(String(fn.last!)), let s = env.fileListSlots[slot] { entries = s }
            let names = Set(entries.filter { !$0.contains("/") && !$0.contains("*") && !$0.contains("?") }.map { $0.lowercased() })
            let paths = Set(entries.filter { $0.contains("/") && !$0.contains("*") && !$0.contains("?") }.map { Paths.normalize($0).lowercased() })
            let wild = entries.filter { $0.contains("*") || $0.contains("?") }.map { WildcardPattern($0, extended: false, starAll: $0.contains("/")) }
            return ClosurePredicate(cost: 4) { id, ctx in
                let n = ctx.store.name(id).lowercased()
                if names.contains(n) { return true }
                if !paths.isEmpty || wild.contains(where: { $0.source.contains("/") }) {
                    let p = ctx.fullPath(id).lowercased()
                    if paths.contains(p) { return true }
                    for w in wild where w.source.contains("/") && w.matches(p) { return true }
                }
                for w in wild where !w.source.contains("/") && w.matches(n) { return true }
                return false
            }
        case "exists", "fileexists", "folderexists":
            let wantFolder: Bool? = fn == "folderexists" ? true : (fn == "fileexists" ? false : nil)
            let template = Paths.normalize(v)
            if !template.contains("$") {
                let found = env.index?.lookup(path: template)
                let ok = found.map { id in wantFolder == nil || env.index!.store.isFolder(id) == wantFolder! } ?? false
                return ok ? AllPredicate() : NonePredicate()
            }
            return ClosurePredicate(cost: 12) { id, ctx in
                let p = PropertyAccess.substitute(template, id: id, ctx: ctx)
                guard let found = ctx.index.lookup(path: p) else { return false }
                return wantFolder == nil || ctx.store.isFolder(found) == wantFolder!
            }
        case "existsinfilelist", "childfilelist", "ancestorfilelist", "includefilelist": return NonePredicate()

        // MARK: regex captures / eval
        case let f where f.hasPrefix("regularexpressionmatch") || f.hasPrefix("regmatch") || f.hasPrefix("regexmatch"):
            guard let n = Int(String(f.last!)), let last = lastRegex, let re = try? NSRegularExpression(pattern: last.matcher.pattern, options: last.matcher.mode.matchCase ? [] : [.caseInsensitive]) else { return NonePredicate() }
            var tt = t; tt.function = nil
            let mt = matcher(tt)
            let scope = last.scope
            return ClosurePredicate(cost: 20) { id, ctx in
                let s = CompileState.scopeString(scope, id, ctx)
                guard let match = re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)), n < match.numberOfRanges, let r = Range(match.range(at: n), in: s) else { return false }
                return mt.matches(String(s[r]))
            }
        case "eval":
            let template = v
            return ClosurePredicate(cost: 15) { id, ctx in Expression.isTrue(PropertyAccess.substitute(template, id: id, ctx: ctx)) }

        // MARK: content (slow)
        case "content", "ansicontent", "utf8content", "utf16content", "utf16becontent", "asciicontent", "bytestream":
            var enc: ContentSearch.Encoding = .auto
            switch fn { case "ansicontent": enc = .ansi; case "utf8content": enc = .utf8; case "utf16content": enc = .utf16le; case "utf16becontent": enc = .utf16be; case "asciicontent": enc = .ascii; case "bytestream": enc = .binary; default: break }
            if let e = m.contentEncoding { switch e { case "ansi": enc = .ansi; case "utf8": enc = .utf8; case "utf16", "utf16le": enc = .utf16le; case "utf16be": enc = .utf16be; case "ascii": enc = .ascii; default: break } }
            if m.binary { enc = .binary }
            var tt = t; tt.function = nil
            let mt = matcher(tt)
            let limit = env.contentSizeLimit, eachLine = m.eachLine
            if m.hex { return ClosurePredicate(cost: 1000) { id, ctx in !ctx.store.isFolder(id) && ContentSearch.matchesHex(path: ctx.fullPath(id), hexPattern: v, limit: limit) } }
            return ClosurePredicate(cost: 1000) { id, ctx in
                guard !ctx.store.isFolder(id), !ctx.cancelled() else { return false }
                return ContentSearch.matches(path: ctx.fullPath(id), matcher: mt, encoding: enc, limit: limit, eachLine: eachLine)
            }
        case "binary":
            var tt = t; tt.function = nil
            let mt = matcher(tt); let limit = env.contentSizeLimit
            return ClosurePredicate(cost: 1000) { id, ctx in !ctx.store.isFolder(id) && ContentSearch.matches(path: ctx.fullPath(id), matcher: mt, encoding: .binary, limit: limit, eachLine: false) }
        case "hex":
            let limit = env.contentSizeLimit
            return ClosurePredicate(cost: 1000) { id, ctx in !ctx.store.isFolder(id) && ContentSearch.matchesHex(path: ctx.fullPath(id), hexPattern: v, limit: limit) }
        case "firstbytes", "lastbytes":
            let bytes = CompileState.hexOrText(v)
            let first = fn == "firstbytes"
            return ClosurePredicate(cost: 500) { id, ctx in
                guard !ctx.store.isFolder(id) else { return false }
                let p = ctx.fullPath(id)
                guard let d = first ? ContentSearch.firstBytes(path: p, count: bytes.count) : ContentSearch.lastBytes(path: p, count: bytes.count) else { return false }
                return Array(d) == bytes
            }
        case "crc32", "crc", "crc64", "md5", "sha1", "sha256", "sha512":
            let algo = HashAlgorithm(rawValue: fn == "crc" ? "crc32" : fn)!
            let wanted = Set(ValueParser.list(v).map { $0.lowercased() })
            return ClosurePredicate(cost: 2000) { id, ctx in
                guard !ctx.store.isFolder(id), !ctx.cancelled() else { return false }
                guard let h = ctx.properties.text(algo.rawValue, path: ctx.fullPath(id), isFolder: false) else { return false }
                return wanted.isEmpty ? true : wanted.contains(h)
            }
        case "systemindex", "si", "spotlight":
            let paths = CompileState.spotlightPaths(query: v)
            return ClosurePredicate(cost: 10) { id, ctx in paths.contains(ctx.fullPath(id)) }
        case "linecount", "wordcount", "containerfilecount", "hardlinkcount", "xattrcount", "alternatedatastreamcount", "adscount":
            guard let r = ValueParser.parseNumber(v) else { return NonePredicate() }
            let prop = fn
            return ClosurePredicate(cost: prop == "hardlinkcount" || prop.contains("xattr") || prop.contains("ads") ? 100 : 800) { id, ctx in
                guard let n = ctx.properties.number(prop, path: ctx.fullPath(id), isFolder: ctx.store.isFolder(id)) else { return r.unknown }
                return r.contains(Int64(n))
            }

        // MARK: kind / type
        case "kind", "type", "perceivedtype":
            let mt = matcher(t)
            let prop = fn
            return ClosurePredicate(cost: 15) { id, ctx in mt.matches(PropertyAccess.text(prop, id: id, ctx: ctx)) }
        case "isrunning":
            return ClosurePredicate(cost: 300) { id, ctx in ctx.properties.value("isrunning", path: ctx.fullPath(id), isFolder: ctx.store.isFolder(id))?.asBool ?? false }

        // MARK: generic property-backed functions
        default:
            guard let spec = FunctionCatalog.spec(fn) else {
                // no-form of a flag function (e.g. no-empty:)
                if fn.hasPrefix("no"), FunctionCatalog.spec(String(fn.dropFirst(2))) != nil {
                    var tt = t; tt.function = String(fn.dropFirst(2))
                    return NotPredicate(compileFunction(tt.function!, tt))
                }
                errors.append("Unknown function \(fn):")
                return NonePredicate()
            }
            return propertyPredicate(spec, t)
        }
    }

    // MARK: helpers

    func parentPredicate(_ v: String, ancestor: Bool) -> Predicate {
        let path = Paths.normalize(v)
        guard let index = env.index else { return NonePredicate() }
        if path.contains("*") || path.contains("?") {
            let w = WildcardPattern(path, extended: false, starAll: true)
            return ClosurePredicate(cost: 12) { id, ctx in
                if ancestor {
                    var p = ctx.store.parent(id)
                    while p != invalidItem { if w.matches(ctx.fullPath(p)) { return true }; p = ctx.store.parent(p) }
                    return false
                }
                let p = ctx.store.parent(id)
                return p != invalidItem && w.matches(ctx.fullPath(p))
            }
        }
        guard let target = index.read({ index.lookup(path: path) }) else { return NonePredicate() }
        if ancestor { return ClosurePredicate(cost: 2) { id, ctx in ctx.store.isAncestor(target, of: id) } }
        return ClosurePredicate(cost: 1) { id, ctx in ctx.store.parent(id) == target }
    }

    mutating func datePartPredicate(_ fn: String, _ v: String) -> Predicate {
        guard let spec = FunctionCatalog.spec(fn), case .datePart(let part) = spec.kind, let base = spec.property else { return NonePredicate() }
        let prop = QueryParser.canonical(base)
        let cal = Calendar.current
        switch part {
        case .date:
            guard let r = ValueParser.parseDate(v, now: env.now) else { return NonePredicate() }
            return ClosurePredicate(cost: 2) { id, ctx in r.contains(PropertyAccess.value(prop, id: id, ctx: ctx)?.asDate ?? 0) }
        case .day:
            guard let r = ValueParser.parseNumber(v) else { return NonePredicate() }
            return ClosurePredicate(cost: 20) { id, ctx in let ns = PropertyAccess.value(prop, id: id, ctx: ctx)?.asDate ?? 0; return ns != 0 && r.contains(Int64(cal.component(.day, from: Timestamps.toDate(ns)))) }
        case .dayOfWeek:
            guard let r = ValueParser.parseWeekday(v) else { return NonePredicate() }
            return ClosurePredicate(cost: 20) { id, ctx in let ns = PropertyAccess.value(prop, id: id, ctx: ctx)?.asDate ?? 0; return ns != 0 && r.contains(Int64(cal.component(.weekday, from: Timestamps.toDate(ns)) - 1)) }
        case .hour:
            guard let r = ValueParser.parseNumber(v) else { return NonePredicate() }
            return ClosurePredicate(cost: 20) { id, ctx in let ns = PropertyAccess.value(prop, id: id, ctx: ctx)?.asDate ?? 0; return ns != 0 && r.contains(Int64(cal.component(.hour, from: Timestamps.toDate(ns)))) }
        case .month:
            guard let r = ValueParser.parseMonth(v) else { return NonePredicate() }
            return ClosurePredicate(cost: 20) { id, ctx in let ns = PropertyAccess.value(prop, id: id, ctx: ctx)?.asDate ?? 0; return ns != 0 && r.contains(Int64(cal.component(.month, from: Timestamps.toDate(ns)))) }
        case .time:
            guard let r = ValueParser.parseTimeOfDay(v) else { return NonePredicate() }
            return ClosurePredicate(cost: 20) { id, ctx in
                let ns = PropertyAccess.value(prop, id: id, ctx: ctx)?.asDate ?? 0
                guard ns != 0 else { return false }
                let d = Timestamps.toDate(ns)
                let c = cal.dateComponents([.hour, .minute, .second], from: d)
                return r.contains(Int64((c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)))
            }
        case .year:
            guard let r = ValueParser.parseNumber(v) else { return NonePredicate() }
            return ClosurePredicate(cost: 20) { id, ctx in let ns = PropertyAccess.value(prop, id: id, ctx: ctx)?.asDate ?? 0; return ns != 0 && r.contains(Int64(cal.component(.year, from: Timestamps.toDate(ns)))) }
        }
    }

    mutating func propertyPredicate(_ spec: FunctionSpec, _ t: Term) -> Predicate {
        let prop = QueryParser.canonical(spec.property ?? spec.name)
        let v = t.value.trimmingCharacters(in: .whitespaces)
        let m = t.modifiers
        let cost = 100
        switch spec.kind {
        case .number, .size, .duration:
            let r: NumRange?
            if m.hexToNumber, let i = Int64(v.replacingOccurrences(of: "0x", with: ""), radix: 16) { r = .exact(i) }
            else if spec.kind == .size { r = ValueParser.parseSize(v, standard: env.sizeStandard) }
            else if spec.kind == .duration { r = ValueParser.parseDuration(v) }
            else { r = ValueParser.parseNumber(v, unit: { u in
                switch u { case "kbps", "kb": return 1000; case "mbps", "mb": return 1_000_000; case "khz": return 1000; case "mhz": return 1_000_000; case "mm", "m", "x", "mp", "dpi", "fps", "hz", "s", "sec": return 1; default: return nil } }) }
            guard let range = r else { errors.append("Invalid value for \(spec.name):"); return NonePredicate() }
            return ClosurePredicate(cost: cost) { id, ctx in
                guard let n = PropertyAccess.value(prop, id: id, ctx: ctx)?.asNumber else { return range.unknown }
                return range.contains(Int64(n.rounded()))
            }
        case .date:
            guard let range = ValueParser.parseDate(v, now: env.now) else { errors.append("Invalid date"); return NonePredicate() }
            return ClosurePredicate(cost: cost) { id, ctx in range.contains(PropertyAccess.value(prop, id: id, ctx: ctx)?.asDate ?? 0) }
        case .flag:
            return ClosurePredicate(cost: cost) { id, ctx in PropertyAccess.value(prop, id: id, ctx: ctx)?.asBool ?? false }
        case .hash:
            let wanted = Set(ValueParser.list(v).map { $0.lowercased() })
            return ClosurePredicate(cost: 2000) { id, ctx in
                guard let h = PropertyAccess.value(prop, id: id, ctx: ctx)?.asText else { return false }
                return wanted.isEmpty || wanted.contains(h.lowercased())
            }
        case .text, .list, .path, .attributes, .directive, .datePart:
            if m.toNumber || m.toInteger {
                guard let range = ValueParser.parseNumber(v) else { return NonePredicate() }
                return ClosurePredicate(cost: cost) { id, ctx in
                    guard let n = PropertyAccess.value(prop, id: id, ctx: ctx)?.asNumber else { return range.unknown }
                    return range.contains(Int64(n))
                }
            }
            if m.len {
                guard let range = ValueParser.parseNumber(v) else { return NonePredicate() }
                return ClosurePredicate(cost: cost) { id, ctx in range.contains(Int64(PropertyAccess.text(prop, id: id, ctx: ctx).utf16.count)) }
            }
            var tt = t; tt.function = nil
            let mt = matcher(tt)
            let allStrings = m.allStrings
            let multi = m.multiString ?? true
            return ClosurePredicate(cost: cost) { id, ctx in
                guard let val = PropertyAccess.value(prop, id: id, ctx: ctx) else { return false }
                if v.isEmpty { return !val.asText.isEmpty }
                switch val {
                case .list(let items) where multi:
                    return allStrings ? items.allSatisfy { mt.matches($0) } : items.contains { mt.matches($0) }
                default:
                    return mt.matches(val.asText)
                }
            }
        }
    }

    static func parseAttributes(_ v: String) -> ItemFlags? {
        let t = v.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return ItemFlags() }
        if t.lowercased().hasPrefix("0x"), let n = UInt32(t.dropFirst(2), radix: 16) { return ItemFlags.fromWindowsAttributes(n) }
        if let n = UInt32(t) { return ItemFlags.fromWindowsAttributes(n) }
        return ItemFlags.fromLetters(t)
    }

    static func hexOrText(_ v: String) -> [UInt8] {
        let clean = v.replacingOccurrences(of: " ", with: "")
        if clean.count >= 2, clean.count % 2 == 0, clean.allSatisfy({ $0.isHexDigit }) {
            var out: [UInt8] = []
            var i = clean.startIndex
            while i < clean.endIndex { let n = clean.index(i, offsetBy: 2); out.append(UInt8(clean[i..<n], radix: 16)!); i = n }
            return out
        }
        return Array(v.utf8)
    }

    static func spotlightPaths(query: String) -> Set<String> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = query.contains("=") || query.contains("kMDItem") ? [query] : ["-name", query]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
    }
}

// MARK: - Specialized predicates

public final class FlagPredicate: Predicate {
    let files: Bool
    public init(files: Bool) { self.files = files }
    public var cost: Int { 0 }
    public func eval(_ id: ItemID, _ ctx: EvalContext) -> Bool { ctx.store.isFolder(id) != files }
}

/// `ext:` list; resolves wildcard patterns against the live extension table on each new generation.
public final class ExtensionPredicate: Predicate {
    private var ids: Set<UInt16>
    private let patterns: [String]
    private var tableCount = -1
    private let lock = NSLock()
    public init(initial: Set<UInt16>, patterns: [String]) { ids = initial; self.patterns = patterns }
    public var cost: Int { 1 }
    public func eval(_ id: ItemID, _ ctx: EvalContext) -> Bool {
        let table = ctx.store.extensions
        if table.count != tableCount {
            lock.lock()
            if table.count != tableCount {
                var s = Set<UInt16>()
                for p in patterns { s.formUnion(table.ids(matching: p)) }
                ids = s; tableCount = table.count
            }
            lock.unlock()
        }
        return ids.contains(ctx.store.extensionID(id))
    }
}
