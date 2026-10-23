import Foundation

/// Uniform access to any property of an indexed item: index columns first, then history, then disk.
public enum PropertyAccess {
    public static func value(_ canonicalProperty: String, id: ItemID, ctx: EvalContext) -> PropertyValue? {
        let s = ctx.store
        switch canonicalProperty {
        case "name": return .text(s.name(id))
        case "stem", "namepart": return .text(s.stem(id))
        case "extension", "ext": return .text(s.extensionName(id))
        case "path", "location", "loc": return .text(ctx.parentPath(id))
        case "fullpath", "fullpathandname": return .text(ctx.fullPath(id))
        case "size": return .number(Double(s.size(id)))
        case "datemodified", "dm": return .date(s.dateModified(id))
        case "datecreated", "dc": return .date(s.dateCreated(id))
        case "dateaccessed", "da": return .date(s.dateAccessed(id))
        case "datechanged": return .date(s.dateChanged(id))
        case "attributes", "attrib", "attr": return .text(s.flags(id).letters)
        case "namelength", "namelen": return .number(Double(s.name(id).utf16.count))
        case "fullpathlength", "fullpathlen", "pathlen", "pathlength": return .number(Double(ctx.fullPath(id).utf16.count))
        case "depth", "parentcount": return .number(Double(s.depth(id)))
        case "childcount": return .number(Double(s.childCount(id)))
        case "childfilecount": var n = 0; s.forEachChild(of: id) { if !s.isFolder($0) { n += 1 } }; return .number(Double(n))
        case "childfoldercount": var n = 0; s.forEachChild(of: id) { if s.isFolder($0) { n += 1 } }; return .number(Double(n))
        case "descendantcount": return .number(Double(descendantCount(id, s, files: true, folders: true)))
        case "descendantfilecount": return .number(Double(descendantCount(id, s, files: true, folders: false)))
        case "descendantfoldercount": return .number(Double(descendantCount(id, s, files: false, folders: true)))
        case "fileid", "frn", "inode": return .number(Double(s.inode(id)))
        case "parentfileid", "parentfrn": let p = s.parent(id); return p == invalidItem ? nil : .number(Double(s.inode(p)))
        case "volumelabel", "volume": return ctx.index.root(containing: id).map { .text($0.label) }
        case "networkindexhost": return ctx.index.root(containing: id).flatMap { $0.kind == .network ? .text($0.path) : nil }
        case "filelistfilename": return ctx.fileListFilenames[s.root(of: id)].map { .text($0) }
        case "filelistfullpath": return ctx.fileListFilenames[s.root(of: id)].map { .text($0) }
        case "runcount": return .number(Double(ctx.runHistory?.runCount(forPath: ctx.fullPath(id)) ?? 0))
        case "daterun": return .date(ctx.runHistory?.dateRun(forPath: ctx.fullPath(id)) ?? 0)
        case "daterecentlychanged", "rc": return .date(ctx.recentChanges?.dateRecentlyChanged(forPath: ctx.fullPath(id)) ?? 0)
        case "kind": return .text(PropertyReader.kind(forPath: s.name(id), isFolder: s.isFolder(id)))
        case "perceivedtype": return .text(PropertyReader.perceivedType(forPath: s.name(id), isFolder: s.isFolder(id)))
        case "folder": return .bool(s.isFolder(id))
        case "file": return .bool(!s.isFolder(id))
        default:
            return ctx.properties.value(canonicalProperty, path: ctx.fullPath(id), isFolder: s.isFolder(id))
        }
    }

    public static func text(_ canonicalProperty: String, id: ItemID, ctx: EvalContext) -> String {
        value(canonicalProperty, id: id, ctx: ctx)?.asText ?? ""
    }

    public static func descendantCount(_ id: ItemID, _ s: ItemStore, files: Bool, folders: Bool) -> Int {
        var n = 0
        var stack: [ItemID] = [id]
        while let cur = stack.popLast() {
            s.forEachChild(of: cur) { c in
                let f = s.isFolder(c)
                if (f && folders) || (!f && files) { n += 1 }
                if f { stack.append(c) }
            }
        }
        return n
    }

    /// Replaces `$property:` tokens in a template with the item's values (used by exists:, eval:, custom columns).
    public static func substitute(_ template: String, id: ItemID, ctx: EvalContext) -> String {
        guard template.contains("$") else { return template }
        var out = ""
        var i = template.startIndex
        while i < template.endIndex {
            let c = template[i]
            if c == "$" {
                if template.index(after: i) < template.endIndex, template[template.index(after: i)] == "$" { out.append("$"); i = template.index(i, offsetBy: 2); continue }
                var j = template.index(after: i)
                var name = ""
                while j < template.endIndex, template[j] != ":", template[j].isLetter || template[j].isNumber || template[j] == "-" || template[j] == "_" { name.append(template[j]); j = template.index(after: j) }
                if j < template.endIndex, template[j] == ":", !name.isEmpty {
                    out += text(QueryParser.canonical(name), id: id, ctx: ctx)
                    i = template.index(after: j)
                    continue
                }
            }
            out.append(c)
            i = template.index(after: i)
        }
        return out
    }
}
