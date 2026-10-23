import Foundation
import Darwin

/// One entry returned by `DirectoryLister`.
public struct DirEntry: Sendable {
    public enum Kind: Sendable { case file, directory, symlink, other }
    public var name: String
    public var kind: Kind
    public var size: UInt64
    public var dateModified: Int64
    public var dateCreated: Int64
    public var dateAccessed: Int64
    public var dateChanged: Int64
    public var bsdFlags: UInt32
    public var mode: UInt32
    public var fileID: UInt64
    public var deviceID: Int32

    public var isHidden: Bool { bsdFlags & UInt32(UF_HIDDEN) != 0 || name.hasPrefix(".") }
    public var isSystemProtected: Bool { bsdFlags & UInt32(SF_RESTRICTED) != 0 }

    /// Index flags derived from the entry.
    public func itemFlags() -> ItemFlags {
        var f = ItemFlags()
        switch kind {
        case .directory: f.insert(.folder)
        case .symlink: f.insert(.symlink)
        default: break
        }
        if isHidden { f.insert(.hidden) }
        if bsdFlags & (UInt32(UF_IMMUTABLE) | UInt32(SF_IMMUTABLE)) != 0 { f.insert(.locked) }
        if bsdFlags & UInt32(UF_COMPRESSED) != 0 { f.insert(.compressed) }
        if bsdFlags & UInt32(SF_RESTRICTED) != 0 { f.insert(.systemProtected) }
        if bsdFlags & UInt32(SF_DATALESS) != 0 { f.insert(.offline) }
        if kind == .file && mode & 0o111 != 0 { f.insert(.executable) }
        if kind == .directory && DirectoryLister.isPackageName(name) { f.insert(.package) }
        return f
    }

    public func record(parent: ItemID) -> ItemRecord {
        ItemRecord(name: name, parent: parent, flags: itemFlags(), size: kind == .file ? size : 0,
                   dateModified: dateModified, dateCreated: dateCreated, dateAccessed: dateAccessed, dateChanged: dateChanged, inode: fileID)
    }
}

/// Fast single-level directory enumeration via getattrlistbulk(2).
public enum DirectoryLister {
    public static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "xcodeproj", "xcworkspace", "playground", "photoslibrary", "musiclibrary",
        "tvlibrary", "appex", "prefpane", "qlgenerator", "mdimporter", "saver", "wdgt", "lproj", "nib", "storyboardc", "xcassets",
        "imovielibrary", "fcpbundle", "band", "pages", "numbers", "key", "scptd", "rtfd", "sparsebundle", "pkg", "mpkg", "dSYM",
        "xcdatamodeld", "xcdatamodel", "docset", "safariextz", "download", "workflow", "action", "localized", "cdr",
    ]

    public static func isPackageName(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return packageExtensions.contains(String(name[name.index(after: dot)...]).lowercased())
    }

    private static var attrList: attrlist = {
        var a = attrlist()
        a.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        let c1: UInt32 = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_DEVID)
        let c2: UInt32 = UInt32(ATTR_CMN_OBJTYPE) | UInt32(ATTR_CMN_CRTIME) | UInt32(ATTR_CMN_MODTIME)
        let c3: UInt32 = UInt32(ATTR_CMN_CHGTIME) | UInt32(ATTR_CMN_ACCTIME) | UInt32(ATTR_CMN_ACCESSMASK)
        let c4: UInt32 = UInt32(ATTR_CMN_FLAGS) | UInt32(ATTR_CMN_FILEID) | UInt32(ATTR_CMN_ERROR)
        a.commonattr = c1 | c2 | c3 | c4
        a.fileattr = UInt32(ATTR_FILE_DATALENGTH)
        return a
    }()

    public enum ListError: Error { case open(Int32), read(Int32) }

    /// Lists a directory. Returns entries in file-system order. Does not follow symlinks.
    public static func list(_ path: String, bufferSize: Int = 512 * 1024) throws -> [DirEntry] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if fd < 0 { throw ListError.open(errno) }
        defer { close(fd) }
        return try list(fd: fd, bufferSize: bufferSize)
    }

    public static func list(fd: Int32, bufferSize: Int = 512 * 1024) throws -> [DirEntry] {
        var attrs = attrList
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buf.deallocate() }
        var out: [DirEntry] = []
        while true {
            let n = getattrlistbulk(fd, &attrs, buf, bufferSize, UInt64(FSOPT_PACK_INVAL_ATTRS))
            if n < 0 {
                if errno == EINTR { continue }
                throw ListError.read(errno)
            }
            if n == 0 { break }
            var p = buf
            for _ in 0..<Int(n) {
                let entryStart = p
                let len = Int(p.loadUnaligned(as: UInt32.self))
                var f = p + 4
                let returned = f.loadUnaligned(as: attribute_set_t.self); f += MemoryLayout<attribute_set_t>.size
                var entry = DirEntry(name: "", kind: .other, size: 0, dateModified: 0, dateCreated: 0, dateAccessed: 0, dateChanged: 0, bsdFlags: 0, mode: 0, fileID: 0, deviceID: 0)
                var errorCode: UInt32 = 0
                if returned.commonattr & UInt32(ATTR_CMN_ERROR) != 0 { errorCode = f.loadUnaligned(as: UInt32.self); f += 4 }
                if returned.commonattr & UInt32(ATTR_CMN_NAME) != 0 {
                    let ref = f.loadUnaligned(as: attrreference_t.self)
                    let cstr = (f + Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                    entry.name = String(cString: cstr)
                    f += MemoryLayout<attrreference_t>.size
                }
                if returned.commonattr & UInt32(ATTR_CMN_DEVID) != 0 { entry.deviceID = f.loadUnaligned(as: dev_t.self); f += MemoryLayout<dev_t>.size }
                if returned.commonattr & UInt32(ATTR_CMN_OBJTYPE) != 0 {
                    let t = f.loadUnaligned(as: fsobj_type_t.self); f += 4
                    switch t {
                    case UInt32(VREG.rawValue): entry.kind = .file
                    case UInt32(VDIR.rawValue): entry.kind = .directory
                    case UInt32(VLNK.rawValue): entry.kind = .symlink
                    default: entry.kind = .other
                    }
                }
                if returned.commonattr & UInt32(ATTR_CMN_CRTIME) != 0 { entry.dateCreated = Timestamps.fromTimespec(f.loadUnaligned(as: timespec.self)); f += 16 }
                if returned.commonattr & UInt32(ATTR_CMN_MODTIME) != 0 { entry.dateModified = Timestamps.fromTimespec(f.loadUnaligned(as: timespec.self)); f += 16 }
                if returned.commonattr & UInt32(ATTR_CMN_CHGTIME) != 0 { entry.dateChanged = Timestamps.fromTimespec(f.loadUnaligned(as: timespec.self)); f += 16 }
                if returned.commonattr & UInt32(ATTR_CMN_ACCTIME) != 0 { entry.dateAccessed = Timestamps.fromTimespec(f.loadUnaligned(as: timespec.self)); f += 16 }
                if returned.commonattr & UInt32(ATTR_CMN_ACCESSMASK) != 0 { entry.mode = f.loadUnaligned(as: UInt32.self); f += 4 }
                if returned.commonattr & UInt32(ATTR_CMN_FLAGS) != 0 { entry.bsdFlags = f.loadUnaligned(as: UInt32.self); f += 4 }
                if returned.commonattr & UInt32(ATTR_CMN_FILEID) != 0 { entry.fileID = f.loadUnaligned(as: UInt64.self); f += 8 }
                if returned.fileattr & UInt32(ATTR_FILE_DATALENGTH) != 0 { entry.size = UInt64(max(0, f.loadUnaligned(as: off_t.self))); f += 8 }
                if errorCode == 0 && !entry.name.isEmpty { out.append(entry) }
                p = entryStart + len
            }
        }
        return out
    }

    /// stat-based single entry (used for FSEvents updates and rescans).
    public static func entry(atPath path: String) -> DirEntry? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let kind: DirEntry.Kind
        switch st.st_mode & S_IFMT {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        return DirEntry(name: Paths.lastComponent(path), kind: kind, size: kind == .file ? UInt64(st.st_size) : 0,
                        dateModified: Timestamps.fromTimespec(st.st_mtimespec), dateCreated: Timestamps.fromTimespec(st.st_birthtimespec),
                        dateAccessed: Timestamps.fromTimespec(st.st_atimespec), dateChanged: Timestamps.fromTimespec(st.st_ctimespec),
                        bsdFlags: st.st_flags, mode: UInt32(st.st_mode), fileID: st.st_ino, deviceID: st.st_dev)
    }
}
