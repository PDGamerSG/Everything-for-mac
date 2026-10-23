import Foundation

public typealias ItemID = Int32
public let invalidItem: ItemID = -1

/// File flags stored per item. Windows attribute letters map onto these where meaningful.
public struct ItemFlags: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let folder          = ItemFlags(rawValue: 1 << 0)   // D
    public static let hidden          = ItemFlags(rawValue: 1 << 1)   // H
    public static let symlink         = ItemFlags(rawValue: 1 << 2)   // L (reparse point)
    public static let package         = ItemFlags(rawValue: 1 << 3)   // app/bundle
    public static let locked          = ItemFlags(rawValue: 1 << 4)   // R (uchg / read-only)
    public static let compressed      = ItemFlags(rawValue: 1 << 5)   // C
    public static let systemProtected = ItemFlags(rawValue: 1 << 6)   // S (SIP / restricted)
    public static let root            = ItemFlags(rawValue: 1 << 7)   // volume or index root
    public static let fileList        = ItemFlags(rawValue: 1 << 8)   // came from a file list
    public static let offline         = ItemFlags(rawValue: 1 << 9)   // O (dataless / cloud)
    public static let executable      = ItemFlags(rawValue: 1 << 10)
    public static let alias           = ItemFlags(rawValue: 1 << 11)  // Finder alias
    public static let deleted         = ItemFlags(rawValue: 1 << 12)  // tombstone
    public static let encrypted       = ItemFlags(rawValue: 1 << 13)  // E
    public static let temporary       = ItemFlags(rawValue: 1 << 14)  // T
    public static let archive         = ItemFlags(rawValue: 1 << 15)  // A (never set on macOS)

    /// Windows FILE_ATTRIBUTE_* bitmask for EFU export / `attrib:` searches.
    public var windowsAttributes: UInt32 {
        var a: UInt32 = 0
        if contains(.locked) { a |= 0x1 }
        if contains(.hidden) { a |= 0x2 }
        if contains(.systemProtected) { a |= 0x4 }
        if contains(.folder) { a |= 0x10 }
        if contains(.archive) { a |= 0x20 }
        if contains(.temporary) { a |= 0x100 }
        if contains(.compressed) { a |= 0x800 }
        if contains(.offline) { a |= 0x1000 }
        if contains(.encrypted) { a |= 0x4000 }
        if contains(.symlink) || contains(.alias) { a |= 0x400 }
        if a == 0 { a = 0x80 } // NORMAL
        return a
    }

    public static func fromWindowsAttributes(_ a: UInt32) -> ItemFlags {
        var f = ItemFlags()
        if a & 0x1 != 0 { f.insert(.locked) }
        if a & 0x2 != 0 { f.insert(.hidden) }
        if a & 0x4 != 0 { f.insert(.systemProtected) }
        if a & 0x10 != 0 { f.insert(.folder) }
        if a & 0x20 != 0 { f.insert(.archive) }
        if a & 0x100 != 0 { f.insert(.temporary) }
        if a & 0x400 != 0 { f.insert(.symlink) }
        if a & 0x800 != 0 { f.insert(.compressed) }
        if a & 0x1000 != 0 { f.insert(.offline) }
        if a & 0x4000 != 0 { f.insert(.encrypted) }
        return f
    }

    /// Everything attribute letters: A C D E H I L N O P R S T U V X M
    public var letters: String {
        var s = ""
        if contains(.archive) { s += "A" }
        if contains(.compressed) { s += "C" }
        if contains(.folder) { s += "D" }
        if contains(.encrypted) { s += "E" }
        if contains(.hidden) { s += "H" }
        if contains(.symlink) || contains(.alias) { s += "L" }
        if contains(.offline) { s += "O" }
        if contains(.locked) { s += "R" }
        if contains(.systemProtected) { s += "S" }
        if contains(.temporary) { s += "T" }
        if s.isEmpty { s = "N" }
        return s
    }

    public static func fromLetters(_ letters: String) -> ItemFlags? {
        var f = ItemFlags()
        for ch in letters.uppercased() {
            switch ch {
            case "A": f.insert(.archive)
            case "C": f.insert(.compressed)
            case "D": f.insert(.folder)
            case "E": f.insert(.encrypted)
            case "H": f.insert(.hidden)
            case "L": f.insert(.symlink)
            case "O": f.insert(.offline)
            case "R": f.insert(.locked)
            case "S": f.insert(.systemProtected)
            case "T": f.insert(.temporary)
            case "N", "I", "P", "U", "V", "X", "M": break // accepted, never match on macOS
            default: return nil
            }
        }
        return f
    }
}

/// Input record for adding an item.
public struct ItemRecord: Equatable, Sendable {
    public var name: String
    public var parent: ItemID
    public var flags: ItemFlags
    public var size: UInt64
    public var dateModified: Int64   // nanoseconds since 1970 UTC, 0 = unknown
    public var dateCreated: Int64
    public var dateAccessed: Int64
    public var dateChanged: Int64
    public var inode: UInt64

    public init(name: String, parent: ItemID, flags: ItemFlags = [], size: UInt64 = 0,
                dateModified: Int64 = 0, dateCreated: Int64 = 0, dateAccessed: Int64 = 0, dateChanged: Int64 = 0, inode: UInt64 = 0) {
        self.name = name; self.parent = parent; self.flags = flags; self.size = size
        self.dateModified = dateModified; self.dateCreated = dateCreated; self.dateAccessed = dateAccessed
        self.dateChanged = dateChanged; self.inode = inode
    }
}

/// Columnar in-memory store of all indexed items. IDs are stable slots; removed slots become
/// tombstones (`.deleted`) and are reused by `add` after compaction.
///
/// Thread safety: callers coordinate through `Index.readLock/writeLock`. All readers may run
/// concurrently; a writer must be exclusive.
public final class ItemStore {
    // Names: one contiguous UTF-8 blob plus a case/diacritic-folded copy of the same length
    // when the name is pure ASCII (fast path) or a separate folded blob otherwise.
    @usableFromInline var nameBlob: [UInt8] = []
    @usableFromInline var foldBlob: [UInt8] = []          // lowercase ASCII fold; non-ASCII bytes copied (UTF-8), folded via foldedNames when needed
    @usableFromInline var nameOffset: [Int32] = []
    @usableFromInline var nameLength: [UInt16] = []
    @usableFromInline var isASCII: [Bool] = []
    /// For non-ASCII names: full Unicode fold (lowercase + diacritic strip) cached as UTF-8.
    @usableFromInline var unicodeFold: [ItemID: [UInt8]] = [:]

    @usableFromInline var parentArr: [ItemID] = []
    @usableFromInline var flagsArr: [ItemFlags] = []
    @usableFromInline var sizeArr: [UInt64] = []
    @usableFromInline var dateModifiedArr: [Int64] = []
    @usableFromInline var dateCreatedArr: [Int64] = []
    @usableFromInline var dateAccessedArr: [Int64] = []
    @usableFromInline var dateChangedArr: [Int64] = []
    @usableFromInline var inodeArr: [UInt64] = []
    @usableFromInline var extArr: [UInt16] = []
    @usableFromInline var firstChild: [ItemID] = []
    @usableFromInline var nextSibling: [ItemID] = []
    @usableFromInline var prevSibling: [ItemID] = []
    @usableFromInline var childCountArr: [Int32] = []
    @usableFromInline var folderSizeArr: [UInt64] = []    // optional (index_folder_size)

    public let extensions = ExtensionTable()
    public private(set) var liveCount: Int = 0
    public private(set) var garbageBytes: Int = 0
    public private(set) var generation: UInt64 = 0
    private var freeSlots: [ItemID] = []
    public var trackFolderSize = false

    public init() {}

    public var slotCount: Int { parentArr.count }
    public var count: Int { liveCount }

    public func reserve(_ n: Int) {
        nameOffset.reserveCapacity(n); nameLength.reserveCapacity(n); isASCII.reserveCapacity(n)
        parentArr.reserveCapacity(n); flagsArr.reserveCapacity(n); sizeArr.reserveCapacity(n)
        dateModifiedArr.reserveCapacity(n); dateCreatedArr.reserveCapacity(n); dateAccessedArr.reserveCapacity(n)
        dateChangedArr.reserveCapacity(n); inodeArr.reserveCapacity(n); extArr.reserveCapacity(n)
        firstChild.reserveCapacity(n); nextSibling.reserveCapacity(n); prevSibling.reserveCapacity(n); childCountArr.reserveCapacity(n)
        nameBlob.reserveCapacity(n * 20); foldBlob.reserveCapacity(n * 20)
    }

    // MARK: - Mutation

    @discardableResult
    public func add(_ r: ItemRecord) -> ItemID {
        let id: ItemID
        if let slot = freeSlots.popLast() {
            id = slot
            writeName(id, r.name, reuse: true)
            parentArr[Int(id)] = r.parent
            flagsArr[Int(id)] = r.flags
            sizeArr[Int(id)] = r.size
            dateModifiedArr[Int(id)] = r.dateModified
            dateCreatedArr[Int(id)] = r.dateCreated
            dateAccessedArr[Int(id)] = r.dateAccessed
            dateChangedArr[Int(id)] = r.dateChanged
            inodeArr[Int(id)] = r.inode
            extArr[Int(id)] = r.flags.contains(.folder) ? 0 : extensions.id(for: ItemStore.extensionOf(r.name))
            firstChild[Int(id)] = invalidItem
            nextSibling[Int(id)] = invalidItem
            prevSibling[Int(id)] = invalidItem
            childCountArr[Int(id)] = 0
            if trackFolderSize { folderSizeArr[Int(id)] = 0 }
        } else {
            id = ItemID(parentArr.count)
            nameOffset.append(0); nameLength.append(0); isASCII.append(true)
            writeName(id, r.name, reuse: false)
            parentArr.append(r.parent)
            flagsArr.append(r.flags)
            sizeArr.append(r.size)
            dateModifiedArr.append(r.dateModified)
            dateCreatedArr.append(r.dateCreated)
            dateAccessedArr.append(r.dateAccessed)
            dateChangedArr.append(r.dateChanged)
            inodeArr.append(r.inode)
            extArr.append(r.flags.contains(.folder) ? 0 : extensions.id(for: ItemStore.extensionOf(r.name)))
            firstChild.append(invalidItem)
            nextSibling.append(invalidItem)
            prevSibling.append(invalidItem)
            childCountArr.append(0)
            if trackFolderSize { folderSizeArr.append(0) }
        }
        link(id, under: r.parent)
        if trackFolderSize && !r.flags.contains(.folder) { addFolderSize(from: r.parent, delta: Int64(r.size)) }
        liveCount += 1
        generation &+= 1
        return id
    }

    /// Removes an item; folders are removed recursively. Returns the number of items removed.
    @discardableResult
    public func remove(_ id: ItemID) -> Int {
        guard isAlive(id) else { return 0 }
        var removed = 0
        var stack: [ItemID] = [id]
        var order: [ItemID] = []
        while let cur = stack.popLast() {
            order.append(cur)
            var c = firstChild[Int(cur)]
            while c != invalidItem { stack.append(c); c = nextSibling[Int(c)] }
        }
        for cur in order.reversed() {
            if trackFolderSize && !flagsArr[Int(cur)].contains(.folder) { addFolderSize(from: parentArr[Int(cur)], delta: -Int64(sizeArr[Int(cur)])) }
            unlink(cur)
            flagsArr[Int(cur)] = [.deleted]
            garbageBytes += Int(nameLength[Int(cur)])
            unicodeFold[cur] = nil
            firstChild[Int(cur)] = invalidItem
            freeSlots.append(cur)
            liveCount -= 1
            removed += 1
        }
        generation &+= 1
        return removed
    }

    public func rename(_ id: ItemID, to newName: String) {
        guard isAlive(id) else { return }
        garbageBytes += Int(nameLength[Int(id)])
        writeName(id, newName, reuse: true)
        if !flagsArr[Int(id)].contains(.folder) { extArr[Int(id)] = extensions.id(for: ItemStore.extensionOf(newName)) }
        generation &+= 1
    }

    public func move(_ id: ItemID, toParent newParent: ItemID) {
        guard isAlive(id), parentArr[Int(id)] != newParent else { return }
        if trackFolderSize {
            let sz = flagsArr[Int(id)].contains(.folder) ? Int64(folderSizeArr[Int(id)]) : Int64(sizeArr[Int(id)])
            addFolderSize(from: parentArr[Int(id)], delta: -sz)
            addFolderSize(from: newParent, delta: sz)
        }
        unlink(id)
        link(id, under: newParent)
        generation &+= 1
    }

    public func update(_ id: ItemID, size: UInt64? = nil, dateModified: Int64? = nil, dateCreated: Int64? = nil,
                       dateAccessed: Int64? = nil, dateChanged: Int64? = nil, flags: ItemFlags? = nil, inode: UInt64? = nil) {
        guard isAlive(id) else { return }
        if let s = size {
            if trackFolderSize && !flagsArr[Int(id)].contains(.folder) { addFolderSize(from: parentArr[Int(id)], delta: Int64(s) - Int64(sizeArr[Int(id)])) }
            sizeArr[Int(id)] = s
        }
        if let d = dateModified { dateModifiedArr[Int(id)] = d }
        if let d = dateCreated { dateCreatedArr[Int(id)] = d }
        if let d = dateAccessed { dateAccessedArr[Int(id)] = d }
        if let d = dateChanged { dateChangedArr[Int(id)] = d }
        if let f = flags { flagsArr[Int(id)] = f.subtracting(.deleted) }
        if let i = inode { inodeArr[Int(id)] = i }
        generation &+= 1
    }

    public func setFolderSize(_ id: ItemID, _ size: UInt64) {
        guard trackFolderSize, isAlive(id) else { return }
        folderSizeArr[Int(id)] = size
    }

    private func addFolderSize(from parent: ItemID, delta: Int64) {
        var p = parent
        while p != invalidItem {
            let cur = Int64(folderSizeArr[Int(p)])
            folderSizeArr[Int(p)] = UInt64(max(0, cur + delta))
            p = parentArr[Int(p)]
        }
    }

    public func enableFolderSizeTracking() {
        guard !trackFolderSize else { return }
        trackFolderSize = true
        folderSizeArr = [UInt64](repeating: 0, count: parentArr.count)
        recomputeFolderSizes()
    }

    public func recomputeFolderSizes() {
        guard trackFolderSize else { return }
        for i in 0..<folderSizeArr.count { folderSizeArr[i] = 0 }
        for i in 0..<parentArr.count where isAlive(ItemID(i)) && !flagsArr[i].contains(.folder) {
            addFolderSize(from: parentArr[i], delta: Int64(sizeArr[i]))
        }
    }

    private func link(_ id: ItemID, under parent: ItemID) {
        parentArr[Int(id)] = parent
        nextSibling[Int(id)] = invalidItem
        prevSibling[Int(id)] = invalidItem
        guard parent != invalidItem else { return }
        let head = firstChild[Int(parent)]
        nextSibling[Int(id)] = head
        if head != invalidItem { prevSibling[Int(head)] = id }
        firstChild[Int(parent)] = id
        childCountArr[Int(parent)] += 1
    }

    private func unlink(_ id: ItemID) {
        let parent = parentArr[Int(id)]
        let prev = prevSibling[Int(id)]
        let next = nextSibling[Int(id)]
        if prev != invalidItem { nextSibling[Int(prev)] = next } else if parent != invalidItem { firstChild[Int(parent)] = next }
        if next != invalidItem { prevSibling[Int(next)] = prev }
        if parent != invalidItem { childCountArr[Int(parent)] -= 1 }
        nextSibling[Int(id)] = invalidItem
        prevSibling[Int(id)] = invalidItem
    }

    private func writeName(_ id: ItemID, _ name: String, reuse: Bool) {
        var utf8 = Array(name.utf8)
        if utf8.count > 65535 { utf8 = Array(utf8[..<65535]) }
        let off = Int32(nameBlob.count)
        nameBlob.append(contentsOf: utf8)
        var ascii = true
        for b in utf8 {
            if b >= 0x80 { ascii = false; foldBlob.append(b) }
            else { foldBlob.append(ItemStore.asciiLower[Int(b)]) }
        }
        nameOffset[Int(id)] = off
        nameLength[Int(id)] = UInt16(utf8.count)
        isASCII[Int(id)] = ascii
        if ascii {
            unicodeFold[id] = nil
        } else {
            unicodeFold[id] = Array(ItemStore.fold(name).utf8)
        }
    }

    // MARK: - Reads

    @inlinable public func isAlive(_ id: ItemID) -> Bool {
        id >= 0 && Int(id) < flagsArr.count && !flagsArr[Int(id)].contains(.deleted)
    }

    @inlinable public func flags(_ id: ItemID) -> ItemFlags { flagsArr[Int(id)] }
    @inlinable public func isFolder(_ id: ItemID) -> Bool { flagsArr[Int(id)].contains(.folder) }
    @inlinable public func parent(_ id: ItemID) -> ItemID { parentArr[Int(id)] }
    @inlinable public func size(_ id: ItemID) -> UInt64 {
        if trackFolderSize && flagsArr[Int(id)].contains(.folder) { return folderSizeArr[Int(id)] }
        return sizeArr[Int(id)]
    }
    @inlinable public func fileSize(_ id: ItemID) -> UInt64 { sizeArr[Int(id)] }
    @inlinable public func dateModified(_ id: ItemID) -> Int64 { dateModifiedArr[Int(id)] }
    @inlinable public func dateCreated(_ id: ItemID) -> Int64 { dateCreatedArr[Int(id)] }
    @inlinable public func dateAccessed(_ id: ItemID) -> Int64 { dateAccessedArr[Int(id)] }
    @inlinable public func dateChanged(_ id: ItemID) -> Int64 { dateChangedArr[Int(id)] }
    @inlinable public func inode(_ id: ItemID) -> UInt64 { inodeArr[Int(id)] }
    @inlinable public func extensionID(_ id: ItemID) -> UInt16 { extArr[Int(id)] }
    @inlinable public func childCount(_ id: ItemID) -> Int { Int(childCountArr[Int(id)]) }
    @inlinable public func nameIsASCII(_ id: ItemID) -> Bool { isASCII[Int(id)] }
    @inlinable public func nameLengthUTF8(_ id: ItemID) -> Int { Int(nameLength[Int(id)]) }

    public func name(_ id: ItemID) -> String {
        let off = Int(nameOffset[Int(id)]), len = Int(nameLength[Int(id)])
        return nameBlob.withUnsafeBufferPointer { String(decoding: UnsafeBufferPointer(rebasing: $0[off..<off + len]), as: UTF8.self) }
    }

    /// Raw UTF-8 bytes of the name.
    @inlinable public func withNameBytes<R>(_ id: ItemID, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        let off = Int(nameOffset[Int(id)]), len = Int(nameLength[Int(id)])
        return nameBlob.withUnsafeBufferPointer { body(UnsafeBufferPointer(rebasing: $0[off..<off + len])) }
    }

    /// ASCII-lowercased bytes (non-ASCII bytes unchanged). Same length as the name.
    @inlinable public func withFoldedASCIIBytes<R>(_ id: ItemID, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        let off = Int(nameOffset[Int(id)]), len = Int(nameLength[Int(id)])
        return foldBlob.withUnsafeBufferPointer { body(UnsafeBufferPointer(rebasing: $0[off..<off + len])) }
    }

    /// Full Unicode fold (lowercase, diacritics stripped). For ASCII names this is the ASCII fold.
    public func withUnicodeFoldedBytes<R>(_ id: ItemID, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        if isASCII[Int(id)] { return withFoldedASCIIBytes(id, body) }
        if let f = unicodeFold[id] { return f.withUnsafeBufferPointer(body) }
        let f = Array(ItemStore.fold(name(id)).utf8)
        return f.withUnsafeBufferPointer(body)
    }

    public func stem(_ id: ItemID) -> String {
        let n = name(id)
        if isFolder(id) { return n }
        guard let dot = n.lastIndex(of: "."), dot != n.startIndex else { return n }
        return String(n[..<dot])
    }

    public func extensionName(_ id: ItemID) -> String {
        if isFolder(id) { return "" }
        return extensions.name(extArr[Int(id)])
    }

    public static func extensionOf(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        let ext = name[name.index(after: dot)...]
        if ext.contains("/") { return "" }
        return String(ext)
    }

    public func children(of id: ItemID) -> [ItemID] {
        var out: [ItemID] = []
        var c = firstChild[Int(id)]
        while c != invalidItem { out.append(c); c = nextSibling[Int(c)] }
        return out
    }

    @inlinable public func forEachChild(of id: ItemID, _ body: (ItemID) -> Void) {
        var c = firstChild[Int(id)]
        while c != invalidItem { body(c); c = nextSibling[Int(c)] }
    }

    public func child(of parent: ItemID, named name: String) -> ItemID? {
        let bytes = Array(name.utf8)
        var c = parent == invalidItem ? invalidItem : firstChild[Int(parent)]
        while c != invalidItem {
            if Int(nameLength[Int(c)]) == bytes.count {
                let off = Int(nameOffset[Int(c)])
                var eq = true
                for i in 0..<bytes.count where nameBlob[off + i] != bytes[i] { eq = false; break }
                if eq { return c }
            }
            c = nextSibling[Int(c)]
        }
        return nil
    }

    /// Case-insensitive child lookup (APFS default is case-insensitive).
    public func childCaseInsensitive(of parent: ItemID, named name: String) -> ItemID? {
        if let exact = child(of: parent, named: name) { return exact }
        let folded = Array(name.lowercased().utf8)
        var c = parent == invalidItem ? invalidItem : firstChild[Int(parent)]
        while c != invalidItem {
            if Int(nameLength[Int(c)]) == folded.count {
                let off = Int(nameOffset[Int(c)])
                var eq = true
                for i in 0..<folded.count where foldBlob[off + i] != folded[i] { eq = false; break }
                if eq { return c }
            }
            c = nextSibling[Int(c)]
        }
        return nil
    }

    public func depth(_ id: ItemID) -> Int {
        var d = 0
        var p = parentArr[Int(id)]
        while p != invalidItem { d += 1; p = parentArr[Int(p)] }
        return d
    }

    public func isAncestor(_ ancestor: ItemID, of id: ItemID) -> Bool {
        var p = parentArr[Int(id)]
        while p != invalidItem { if p == ancestor { return true }; p = parentArr[Int(p)] }
        return false
    }

    public func root(of id: ItemID) -> ItemID {
        var cur = id
        while parentArr[Int(cur)] != invalidItem { cur = parentArr[Int(cur)] }
        return cur
    }

    /// Full path, e.g. `/Users/admin/file.txt`. Root items carry their mount path as name.
    public func fullPath(_ id: ItemID) -> String {
        var parts: [ItemID] = []
        var cur = id
        while cur != invalidItem { parts.append(cur); cur = parentArr[Int(cur)] }
        var out = ""
        for (i, p) in parts.reversed().enumerated() {
            let n = name(p)
            if i == 0 {
                out = n
            } else {
                if !out.hasSuffix("/") { out += "/" }
                out += n
            }
        }
        return out
    }

    /// Parent path (Everything "Path" column), e.g. `/Users/admin`.
    public func path(_ id: ItemID) -> String {
        let p = parentArr[Int(id)]
        return p == invalidItem ? "" : fullPath(p)
    }

    /// Path length in UTF-16 units of the full path.
    public func fullPathLengthUTF16(_ id: ItemID) -> Int { fullPath(id).utf16.count }

    /// Resolve an absolute path to an item, walking from the matching root.
    public func find(path: String, roots: [ItemID]) -> ItemID? {
        var best: ItemID? = nil
        var bestLen = -1
        for r in roots {
            let rp = name(r)
            if path == rp || path.hasPrefix(rp.hasSuffix("/") ? rp : rp + "/") {
                if rp.count > bestLen { best = r; bestLen = rp.count }
            }
        }
        guard let root = best else { return nil }
        let rp = name(root)
        var rest = Substring(path.dropFirst(rp.count))
        if rest.hasPrefix("/") { rest = rest.dropFirst() }
        if rest.hasSuffix("/") { rest = rest.dropLast() }
        var cur = root
        for comp in rest.split(separator: "/") {
            guard let c = childCaseInsensitive(of: cur, named: String(comp)) else { return nil }
            cur = c
        }
        return cur
    }

    /// Iterate alive slots in chunks for parallel evaluation.
    public func chunkRanges(chunk: Int) -> [Range<Int>] {
        let n = parentArr.count
        guard n > 0 else { return [] }
        var out: [Range<Int>] = []
        var start = 0
        while start < n { let end = min(n, start + chunk); out.append(start..<end); start = end }
        return out
    }

    // MARK: - Compaction

    /// Rebuilds the name blobs without tombstone garbage. IDs are preserved.
    public func compactIfNeeded(threshold: Double = 0.25) {
        guard nameBlob.count > 0, Double(garbageBytes) / Double(nameBlob.count) > threshold else { return }
        compact()
    }

    public func compact() {
        var newBlob: [UInt8] = []; newBlob.reserveCapacity(nameBlob.count - garbageBytes)
        var newFold: [UInt8] = []; newFold.reserveCapacity(nameBlob.count - garbageBytes)
        for i in 0..<parentArr.count {
            if flagsArr[i].contains(.deleted) { nameOffset[i] = 0; nameLength[i] = 0; continue }
            let off = Int(nameOffset[i]), len = Int(nameLength[i])
            nameOffset[i] = Int32(newBlob.count)
            newBlob.append(contentsOf: nameBlob[off..<off + len])
            newFold.append(contentsOf: foldBlob[off..<off + len])
        }
        nameBlob = newBlob
        foldBlob = newFold
        garbageBytes = 0
    }

    /// Used by IndexDB after loading raw columns.
    func setLoadedState(live: Int, garbage: Int, free: [ItemID], generation: UInt64) {
        liveCount = live
        garbageBytes = garbage
        freeSlots = free
        self.generation = generation
    }

    // MARK: - Folding helpers

    @usableFromInline static let asciiLower: [UInt8] = (0..<128).map { b in (b >= 65 && b <= 90) ? UInt8(b + 32) : UInt8(b) }

    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    public static func foldCaseOnly(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }
}
