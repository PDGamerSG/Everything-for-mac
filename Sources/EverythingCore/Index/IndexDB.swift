import Foundation
import zlib

/// Binary persistence of an `Index` to `Everything.db`.
///
/// Layout (little endian):
///   magic "EVTM" | u32 version | u32 flags | u64 generation
///   roots: u32 count, each { u8 kind, str path, str label, str uuid, i32 item, u64 lastEventID, i64 scanDate,
///                            u32 includeOnlyCount + strs, u8 monitor, i32 deviceID, str fileSystem }
///   extensions: u32 count, strs
///   items: u32 slotCount, then columns in order:
///     nameBlob (u32 len + bytes), nameOffset[i32], nameLength[u16], parent[i32], flags[u16], size[u64],
///     dateModified[i64], dateCreated[i64], dateAccessed[i64], dateChanged[i64], inode[u64], ext[u16]
///   u32 crc32 of everything before it
public enum IndexDB {
    public static let magic: [UInt8] = Array("EVTM".utf8)
    public static let version: UInt32 = 1

    public enum DBError: Error, Equatable {
        case badMagic, unsupportedVersion(UInt32), truncated, badCRC, corrupt(String)
    }

    // MARK: save

    public static func save(_ index: Index, to url: URL) throws {
        let data = index.read { encode(index) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    public static func encode(_ index: Index) -> Data {
        let s = index.store
        var w = ByteWriter()
        w.bytes(magic)
        w.u32(version)
        w.u32(s.trackFolderSize ? 1 : 0)
        w.u64(s.generation)
        w.u32(UInt32(index.roots.count))
        for r in index.roots {
            w.u8(r.kind.rawValue); w.str(r.path); w.str(r.label); w.str(r.uuid); w.i32(r.item)
            w.u64(r.lastEventID); w.i64(r.scanDate)
            w.u32(UInt32(r.includeOnly.count)); for p in r.includeOnly { w.str(p) }
            w.u8(r.monitor ? 1 : 0); w.i32(r.deviceID); w.str(r.fileSystem)
        }
        let exts = s.extensions.allNames
        w.u32(UInt32(exts.count)); for e in exts { w.str(e) }
        w.u32(UInt32(s.slotCount))
        w.u32(UInt32(s.nameBlob.count)); w.bytes(s.nameBlob)
        w.array(s.nameOffset); w.array(s.nameLength); w.array(s.parentArr)
        w.array(s.flagsArr.map { $0.rawValue })
        w.array(s.sizeArr); w.array(s.dateModifiedArr); w.array(s.dateCreatedArr); w.array(s.dateAccessedArr)
        w.array(s.dateChangedArr); w.array(s.inodeArr); w.array(s.extArr)
        let crc = w.data.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt($0.count)) }
        w.u32(UInt32(crc))
        return w.data
    }

    // MARK: load

    public static func load(from url: URL) throws -> Index {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> Index {
        guard data.count >= 20 else { throw DBError.truncated }
        var r = ByteReader(data)
        guard try r.bytes(4) == magic else { throw DBError.badMagic }
        let v = try r.u32()
        guard v == version else { throw DBError.unsupportedVersion(v) }
        // CRC check first
        let body = data.subdata(in: 0..<(data.count - 4))
        let stored = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: data.count - 4, as: UInt32.self) }
        let crc = body.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt($0.count)) }
        guard UInt32(crc) == stored else { throw DBError.badCRC }

        let flags = try r.u32()
        let generation = try r.u64()
        let store = ItemStore()
        let index = Index(store: store)
        let rootCount = Int(try r.u32())
        var roots: [Root] = []
        for _ in 0..<rootCount {
            let kind = RootKind(rawValue: try r.u8()) ?? .folder
            let path = try r.str(), label = try r.str(), uuid = try r.str()
            let item = try r.i32(); let lastEventID = try r.u64(); let scanDate = try r.i64()
            let n = Int(try r.u32()); var inc: [String] = []; for _ in 0..<n { inc.append(try r.str()) }
            let monitor = try r.u8() == 1; let dev = try r.i32(); let fs = try r.str()
            roots.append(Root(kind: kind, path: path, label: label, uuid: uuid, item: item, lastEventID: lastEventID,
                              scanDate: scanDate, includeOnly: inc, monitor: monitor, deviceID: dev, fileSystem: fs))
        }
        let extCount = Int(try r.u32()); var exts: [String] = []; exts.reserveCapacity(extCount)
        for _ in 0..<extCount { exts.append(try r.str()) }
        store.extensions.load(names: exts)
        let slots = Int(try r.u32())
        let blobLen = Int(try r.u32())
        store.nameBlob = Array(try r.bytes(blobLen))
        store.nameOffset = try r.array(Int32.self, slots)
        store.nameLength = try r.array(UInt16.self, slots)
        store.parentArr = try r.array(Int32.self, slots)
        store.flagsArr = try r.array(UInt16.self, slots).map { ItemFlags(rawValue: $0) }
        store.sizeArr = try r.array(UInt64.self, slots)
        store.dateModifiedArr = try r.array(Int64.self, slots)
        store.dateCreatedArr = try r.array(Int64.self, slots)
        store.dateAccessedArr = try r.array(Int64.self, slots)
        store.dateChangedArr = try r.array(Int64.self, slots)
        store.inodeArr = try r.array(UInt64.self, slots)
        store.extArr = try r.array(UInt16.self, slots)
        try store.rebuildDerived(generation: generation, trackFolderSize: flags & 1 != 0)
        index.setRoots(roots)
        index.dbLoaded = true
        return index
    }
}

extension ItemStore {
    /// Recomputes fold blob, ASCII flags, child links, counts and free slots after a raw column load.
    func rebuildDerived(generation: UInt64, trackFolderSize: Bool) throws {
        let n = parentArr.count
        guard nameOffset.count == n, nameLength.count == n, flagsArr.count == n, sizeArr.count == n,
              dateModifiedArr.count == n, extArr.count == n else { throw IndexDB.DBError.corrupt("column length mismatch") }
        foldBlob = [UInt8](repeating: 0, count: nameBlob.count)
        isASCII = [Bool](repeating: true, count: n)
        unicodeFold = [:]
        firstChild = [ItemID](repeating: invalidItem, count: n)
        nextSibling = [ItemID](repeating: invalidItem, count: n)
        prevSibling = [ItemID](repeating: invalidItem, count: n)
        childCountArr = [Int32](repeating: 0, count: n)
        var free: [ItemID] = []
        var live = 0
        var garbage = 0
        for i in 0..<n {
            if flagsArr[i].contains(.deleted) { free.append(ItemID(i)); garbage += Int(nameLength[i]); continue }
            live += 1
            let off = Int(nameOffset[i]), len = Int(nameLength[i])
            guard off + len <= nameBlob.count else { throw IndexDB.DBError.corrupt("name offset out of range") }
            var ascii = true
            for k in off..<off + len {
                let b = nameBlob[k]
                if b >= 0x80 { ascii = false; foldBlob[k] = b } else { foldBlob[k] = ItemStore.asciiLower[Int(b)] }
            }
            isASCII[i] = ascii
            if !ascii { unicodeFold[ItemID(i)] = Array(ItemStore.fold(name(ItemID(i))).utf8) }
        }
        // link children in reverse so that firstChild order matches insertion order
        for i in stride(from: n - 1, through: 0, by: -1) where !flagsArr[i].contains(.deleted) {
            let p = parentArr[i]
            guard p != invalidItem else { continue }
            guard Int(p) < n else { throw IndexDB.DBError.corrupt("parent out of range") }
            let head = firstChild[Int(p)]
            nextSibling[i] = head
            if head != invalidItem { prevSibling[Int(head)] = ItemID(i) }
            firstChild[Int(p)] = ItemID(i)
            childCountArr[Int(p)] += 1
        }
        setLoadedState(live: live, garbage: garbage, free: free, generation: generation)
        if trackFolderSize { enableFolderSizeTracking() }
    }
}

// MARK: - Byte helpers

struct ByteWriter {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func u64(_ v: UInt64) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
    mutating func i64(_ v: Int64) { u64(UInt64(bitPattern: v)) }
    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    mutating func str(_ s: String) { let u = Array(s.utf8); u32(UInt32(u.count)); bytes(u) }
    mutating func array<T: FixedWidthInteger>(_ a: [T]) {
        a.withUnsafeBufferPointer { data.append(UnsafeBufferPointer(start: UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: UInt8.self), count: a.count * MemoryLayout<T>.size)) }
    }
}

struct ByteReader {
    let data: Data
    var pos = 0
    init(_ d: Data) { data = d }
    mutating func need(_ n: Int) throws { if pos + n > data.count { throw IndexDB.DBError.truncated } }
    mutating func u8() throws -> UInt8 { try need(1); defer { pos += 1 }; return data[data.startIndex + pos] }
    mutating func u16() throws -> UInt16 { try need(2); defer { pos += 2 }; return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos, as: UInt16.self) }.littleEndian }
    mutating func u32() throws -> UInt32 { try need(4); defer { pos += 4 }; return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos, as: UInt32.self) }.littleEndian }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    mutating func u64() throws -> UInt64 { try need(8); defer { pos += 8 }; return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos, as: UInt64.self) }.littleEndian }
    mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }
    mutating func bytes(_ n: Int) throws -> [UInt8] { try need(n); defer { pos += n }; return Array(data[(data.startIndex + pos)..<(data.startIndex + pos + n)]) }
    mutating func str() throws -> String { let n = Int(try u32()); return String(decoding: try bytes(n), as: UTF8.self) }
    mutating func array<T: FixedWidthInteger>(_ t: T.Type, _ count: Int) throws -> [T] {
        let n = count * MemoryLayout<T>.size
        try need(n)
        defer { pos += n }
        return data.withUnsafeBytes { raw in
            var out = [T](repeating: 0, count: count)
            out.withUnsafeMutableBytes { dst in dst.copyBytes(from: UnsafeRawBufferPointer(rebasing: raw[pos..<pos + n])) }
            return out
        }
    }
}
