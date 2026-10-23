import Foundation

/// Parses Everything search syntax into a `ParsedQuery`.
public struct QueryParser {
    public var options: ParseOptions
    /// Known function names (canonical: lowercase, no dashes). Unknown `name:` prefixes are literal text.
    public var functionNames: Set<String>
    /// Function names that take the directive path (sort:, columns:, …) — still produce a term for extraction.
    public init(options: ParseOptions = ParseOptions(), functionNames: Set<String> = Functions.canonicalNames) {
        self.options = options
        self.functionNames = functionNames
    }

    /// Length of a Windows drive prefix (`C:` or `C:/`) at the start of a value, or nil.
    static func driveLetterPrefix(_ v: String) -> Int? {
        let u = Array(v.unicodeScalars)
        guard u.count >= 2, u[1] == ":", u[0].properties.isAlphabetic, u[0].value < 128 else { return nil }
        if u.count == 2 { return 2 }
        return (u[2] == "/" || u[2] == "\\") ? 2 : nil
    }

    public static func canonical(_ name: String) -> String {
        var out = ""
        for ch in name.lowercased() where ch != "-" && ch != "_" { out.append(ch) }
        return out
    }

    public func parse(_ input: String) -> ParsedQuery {
        var tokens = Lexer.mergeRegexAlternation(Lexer.tokenize(input))
        if options.literalOperators { tokens = applyLiteralOperators(tokens) }
        var state = ParseState(tokens: tokens, options: options, functionNames: functionNames, scalars: Array(input.unicodeScalars))
        let node = state.parseExpression(untilClose: false)
        var directives = state.directives
        var root = node.simplified()
        // Extract directive-only terms from the tree.
        root = extractDirectives(root, &directives).simplified()
        return ParsedQuery(root: root, directives: directives, globalModifiers: state.globalModifiers, original: input)
    }

    // MARK: literal operators (AND / OR / NOT words)

    private func applyLiteralOperators(_ tokens: [Lexer.Token]) -> [Lexer.Token] {
        var out: [Lexer.Token] = []
        for t in tokens {
            if case .word(let chars, let start, _, let quoted) = t, !quoted, chars.allSatisfy({ !$0.literal }) {
                let w = String(String.UnicodeScalarView(chars.map { $0.scalar }))
                switch w {
                case "AND": continue // implicit
                case "OR": out.append(.or(start)); continue
                case "NOT": out.append(.not(start)); continue
                default: break
                }
            }
            out.append(t)
        }
        return out
    }

    // MARK: directives

    private func extractDirectives(_ node: QueryNode, _ directives: inout [UIDirective]) -> QueryNode {
        switch node {
        case .term(let t):
            if let f = t.function, let d = QueryParser.directive(for: f, value: t.value) {
                directives.append(d)
                return .empty
            }
            return node
        case .not(let n):
            let inner = extractDirectives(n, &directives)
            return inner.isEmpty ? .empty : .not(inner)
        case .and(let a): return .and(a.map { extractDirectives($0, &directives) })
        case .or(let a): return .or(a.map { extractDirectives($0, &directives) })
        case .empty: return .empty
        }
    }

    static func list(_ v: String) -> [String] { v.split(separator: ";").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    static func directive(for canonical: String, value: String) -> UIDirective? {
        let v = value
        switch canonical {
        case "sort": return .sort(list(v))
        case "sortascending": return .sortAscending
        case "sortdescending": return .sortDescending
        case "sortmix": return .sortMix(true)
        case "nosortmix": return .sortMix(false)
        case "foldersfirst": return .foldersFirst(true)
        case "nofoldersfirst": return .foldersFirst(false)
        case "foldersfirstascending": return .foldersFirst(true)
        case "foldersfirstdescending": return .foldersFirst(false)
        case "count": return Int(v).map { .count($0) }
        case "maxthreads": return Int(v).map { .maxThreads($0) }
        case "columns": return .columns(list(v))
        case "addcolumns", "addcol", "addcolumn": return .addColumns(list(v))
        case "removecolumns", "removecolumn": return .removeColumns(list(v))
        case "layout": return .layout(list(v))
        case "addlayout": return .addLayout(list(v))
        case "removelayout": return .removeLayout(list(v))
        case "preview": return .preview(true)
        case "nopreview": return .preview(false)
        case "thumbnails": return .thumbnails(Int(v))
        case "details": return .details
        case "folderssidebar": return .foldersSidebar(true)
        case "nofolderssidebar": return .foldersSidebar(false)
        case "filterssidebar": return .filtersSidebar(true)
        case "nofilterssidebar": return .filtersSidebar(false)
        case "bookmarkssidebar": return .bookmarksSidebar(true)
        case "nobookmarkssidebar": return .bookmarksSidebar(false)
        case "alternaterowcolor": return .alternateRowColor(true)
        case "noalternaterowcolor": return .alternateRowColor(false)
        case "ontop": return .onTop(true)
        case "noontop": return .onTop(false)
        case "dupe", "dupes", "duplicates": return .dupe(list(v))
        case "unique": return .unique(list(v))
        case "distinct": return .distinct(list(v))
        case "distinctsort": return .distinctSort(list(v))
        case "dupecount": return Int(v).map { .dupeCount($0) }
        case "dupemin": return Int(v).map { .dupeMin($0) }
        case "dupemax": return Int(v).map { .dupeMax($0) }
        case "dupefrom": return .dupeFrom(v)
        case "newsearch": return .newSearch
        case "andsearch": return .andSearch
        case "newresultsonly": return .newResultsOnly
        case "nonewresults": return .noNewResults
        case "nop": return .nop
        case "nothing": return .nothing
        case "everything": return .everything
        case "bookmark": return .bookmark(v)
        case "filter": return .filter(v)
        case "includefilelist": return .includeFileList(v)
        default:
            if canonical.hasPrefix("column"), canonical.count == 7, let idx = Int(String(canonical.last!), radix: 16) { return .addColumn(index: idx, spec: v) }
            if canonical.hasPrefix("filelist"), canonical.count == 9, let idx = Int(String(canonical.last!)) { return .fileListSlot(idx, list(v)) }
            return nil
        }
    }

    /// Canonical names that are directives, not filters.
    public static let directiveNames: Set<String> = [
        "sort", "sortascending", "sortdescending", "sortmix", "nosortmix", "foldersfirst", "nofoldersfirst", "foldersfirstascending", "foldersfirstdescending",
        "count", "maxthreads", "columns", "addcolumns", "addcol", "addcolumn", "removecolumns", "removecolumn", "layout", "addlayout", "removelayout",
        "preview", "nopreview", "thumbnails", "details", "folderssidebar", "nofolderssidebar", "filterssidebar", "nofilterssidebar", "bookmarkssidebar",
        "nobookmarkssidebar", "alternaterowcolor", "noalternaterowcolor", "ontop", "noontop", "dupe", "dupes", "duplicates", "unique", "distinct", "distinctsort",
        "dupecount", "dupemin", "dupemax", "dupefrom", "newsearch", "andsearch", "newresultsonly", "nonewresults", "nop", "nothing", "everything",
        "bookmark", "filter", "includefilelist",
        "column0", "column1", "column2", "column3", "column4", "column5", "column6", "column7", "column8", "column9", "columna", "columnb", "columnc", "columnd", "columne", "columnf",
        "filelist0", "filelist1", "filelist2", "filelist3", "filelist4", "filelist5", "filelist6", "filelist7", "filelist8", "filelist9",
    ]
}

// MARK: - Recursive descent

private struct ParseState {
    let tokens: [Lexer.Token]
    var pos = 0
    let options: ParseOptions
    let functionNames: Set<String>
    let scalars: [Unicode.Scalar]
    var directives: [UIDirective] = []
    var globalModifiers = ModifierSet()
    var andPrecedence: Bool

    init(tokens: [Lexer.Token], options: ParseOptions, functionNames: Set<String>, scalars: [Unicode.Scalar]) {
        self.tokens = tokens; self.options = options; self.functionNames = functionNames; self.scalars = scalars
        andPrecedence = !options.orPrecedence
    }

    var atEnd: Bool { pos >= tokens.count }

    mutating func skipSpaces() { while pos < tokens.count, tokens[pos] == .space { pos += 1 } }

    /// expression := sequence of operands separated by spaces (AND) and `|` (OR).
    mutating func parseExpression(untilClose: Bool) -> QueryNode {
        // Collect a flat list of operands and operators, then fold by precedence.
        var items: [QueryNode] = []
        var ops: [Bool] = []  // true = OR between items[i] and items[i+1], false = AND
        var pendingOr = false
        var pendingNot = false
        var pendingModifiers: ModifierSet? = nil

        while pos < tokens.count {
            let t = tokens[pos]
            switch t {
            case .space:
                pos += 1
            case .close:
                pos += 1
                if untilClose { return fold(items, ops) }
                // stray '>' at top level: ignore
            case .or:
                pos += 1
                pendingOr = true
            case .not:
                pos += 1
                pendingNot.toggle()
            case .open:
                pos += 1
                var inner = parseExpression(untilClose: true)
                if let mods = pendingModifiers {
                    inner = inner.map { term in var t = term; t.modifiers = mods.merged(with: t.modifiers); return .term(t) }
                    pendingModifiers = nil
                }
                if pendingNot { inner = .not(inner); pendingNot = false }
                append(inner)
            case .word(let chars, let start, let end, let quoted):
                pos += 1
                // Modifier prefix applying to a following group: `case:<a b>` — detected when word ends with ':' and next token is '<'
                if let next = tokens[safe: pos], case .open = next, chars.last?.scalar == ":" && chars.last?.literal == false {
                    var mods = ModifierSet()
                    if applyModifierChain(chars, into: &mods) { pendingModifiers = mods; continue }
                }
                var node = parseWord(chars, start: start, end: end, quoted: quoted)
                if let mods = pendingModifiers {
                    node = node.map { term in var t = term; t.modifiers = mods.merged(with: t.modifiers); return .term(t) }
                    pendingModifiers = nil
                }
                if pendingNot { node = .not(node); pendingNot = false }
                append(node)
            }
        }
        return fold(items, ops)

        func append(_ n: QueryNode) {
            if n.isEmpty && !pendingOr { return }
            if !items.isEmpty { ops.append(pendingOr) }
            items.append(n)
            pendingOr = false
        }
    }

    func fold(_ items: [QueryNode], _ ops: [Bool]) -> QueryNode {
        guard !items.isEmpty else { return .empty }
        if items.count == 1 { return items[0] }
        if andPrecedence {
            // AND binds tighter: split on OR
            var orGroups: [[QueryNode]] = [[items[0]]]
            for (i, isOr) in ops.enumerated() {
                if isOr { orGroups.append([items[i + 1]]) } else { orGroups[orGroups.count - 1].append(items[i + 1]) }
            }
            let ands = orGroups.map { $0.count == 1 ? $0[0] : QueryNode.and($0) }
            return ands.count == 1 ? ands[0] : .or(ands)
        } else {
            // OR binds tighter: split on AND
            var andGroups: [[QueryNode]] = [[items[0]]]
            _ = andGroups
            for (i, isOr) in ops.enumerated() {
                if isOr { andGroups[andGroups.count - 1].append(items[i + 1]) } else { andGroups.append([items[i + 1]]) }
            }
            let ors = andGroups.map { $0.count == 1 ? $0[0] : QueryNode.or($0) }
            return ors.count == 1 ? ors[0] : .and(ors)
        }
    }

    /// Applies `mod1:mod2:...:` chain (word ending in colon) to mods. Returns false if any segment is not a modifier.
    mutating func applyModifierChain(_ chars: [Lexer.Char], into mods: inout ModifierSet) -> Bool {
        var segments: [String] = []
        var cur = ""
        for c in chars {
            if c.scalar == ":" && !c.literal { segments.append(cur); cur = "" } else { cur.unicodeScalars.append(c.scalar) }
        }
        if !cur.isEmpty { return false }
        for seg in segments {
            guard applyModifier(seg, into: &mods) else { return false }
        }
        return true
    }

    /// Applies a single modifier segment (may have `no`, `::`, `?` prefixes). Returns false if not a modifier.
    mutating func applyModifier(_ raw: String, into mods: inout ModifierSet) -> Bool {
        var name = QueryParser.canonical(raw)
        var isGlobal = false
        if name.hasPrefix("?") { isGlobal = true; name.removeFirst() }
        if name.hasPrefix("::") { name.removeFirst(2); mods.builtin = true }
        var enabled = true
        if ModifierSet.modifierNames.contains(name) {
            enabled = true
        } else if name.hasPrefix("no"), ModifierSet.modifierNames.contains(String(name.dropFirst(2))) {
            name = String(name.dropFirst(2)); enabled = false
        } else {
            return false
        }
        var target = ModifierSet()
        target.apply(name, enabled: enabled)
        if isGlobal { globalModifiers = globalModifiers.merged(with: target) }
        mods = mods.merged(with: target)
        return true
    }

    /// Parses one word into a term (or macro expansion placeholder).
    mutating func parseWord(_ chars: [Lexer.Char], start: Int, end: Int, quoted: Bool) -> QueryNode {
        var mods = globalModifiers
        var function: String? = nil
        var i = 0
        var quotedAny = quoted || chars.contains { $0.literal }
        var literalRest = false

        // Parse `prefix:` segments while they are modifiers or a function.
        while true {
            // find next unescaped ':' at or after i
            guard let colon = chars[i...].firstIndex(where: { $0.scalar == ":" && !$0.literal }) else { break }
            let segChars = chars[i..<colon]
            if segChars.contains(where: { $0.literal }) { break } // quoted prefix is text
            var seg = String(String.UnicodeScalarView(segChars.map { $0.scalar }))
            var star = false
            if seg.hasSuffix("*") { star = true; seg.removeLast() }
            if seg.isEmpty { break }
            let canonical = QueryParser.canonical(seg)
            if applyModifier(seg, into: &mods) {
                i = colon + 1
                if star { literalRest = true; break }
                continue
            }
            let fname: String
            if options.macroNames.contains(canonical) {
                fname = "macro:" + canonical
            } else if QueryParser.directiveNames.contains(canonical) {
                fname = canonical
            } else if let spec = FunctionCatalog.spec(canonical) {
                fname = spec.canonical
            } else if canonical.hasPrefix("no"), functionNames.contains(String(canonical.dropFirst(2))) {
                fname = canonical  // no-form of a flag function (handled by Functions)
            } else {
                break // unknown prefix: literal text
            }
            function = fname
            i = colon + 1
            if star { literalRest = true }
            break
        }

        var value: String
        var termEnd = end
        if literalRest {
            // Rest of the whole search text is the value.
            let from = (i < chars.count) ? chars[i].position : (chars.last.map { $0.position + 1 } ?? end)
            value = String(String.UnicodeScalarView(scalars[min(from, scalars.count)...]))
            pos = tokens.count
            termEnd = scalars.count
            quotedAny = true
        } else {
            value = String(String.UnicodeScalarView(chars[i...].map { $0.scalar }))
        }
        if options.replaceBackslashes && function != "regex" && mods.regex != true {
            // Treat backslashes as path separators (Windows-style input).
            if value.contains("\\") && !(function == nil && value.hasPrefix("\\") == false && mods.wildcards == true) {
                value = value.replacingOccurrences(of: "\\", with: "/")
            }
        }
        if options.replaceForwardSlashes && function == nil { value = value.replacingOccurrences(of: "/", with: "\\") }

        // A term that looks like a path (`/Users`, `\downloads`, `C:\Windows`) matches the full path.
        if function == nil, mods.regex != true {
            if let drive = QueryParser.driveLetterPrefix(value) { value = String(value.dropFirst(drive)); if !value.hasPrefix("/") { value = "/" + value } }
            if value.hasPrefix("/") && !(chars.first?.literal ?? false) { mods.path = true }
        }
        if function == nil && value.isEmpty && !quotedAny {
            // Modifier-only term (`file:`, `case:`): file/folder filters stay terms, other modifiers become global.
            if mods.fileOnly || mods.folderOnly {
                return .term(Term(modifiers: mods, function: nil, value: "", quoted: false, literalRest: false, range: start..<termEnd))
            }
            globalModifiers = globalModifiers.merged(with: mods)
            if let ap = mods.andPrecedence { andPrecedence = ap }
            return .empty
        }
        if let ap = mods.andPrecedence { andPrecedence = ap }
        let term = Term(modifiers: mods, function: function, value: value, quoted: quotedAny, literalRest: literalRest, range: start..<termEnd)
        return .term(term)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}
