import Foundation

/// Materialized full paths for every folder in the store (raw UTF-8 and Unicode-folded), so that
/// path-based predicates can run without allocating strings per item.
public final class PathTable {
    public let generation: UInt64
    @usableFromInline var rawBlob: [UInt8] = []
    @usableFromInline var foldBlob: [UInt8] = []
    @usableFromInline var offset: [Int32]          // per slot; -1 when not a folder
    @usableFromInline var length: [Int32]
    @usableFromInline var foldOffset: [Int32]
    @usableFromInline var foldLength: [Int32]

    public init(store: ItemStore, roots: [ItemID]) {
        generation = store.generation
        let n = store.slotCount
        offset = [Int32](repeating: -1, count: n)
        length = [Int32](repeating: 0, count: n)
        foldOffset = [Int32](repeating: -1, count: n)
        foldLength = [Int32](repeating: 0, count: n)
        rawBlob.reserveCapacity(n * 8)
        foldBlob.reserveCapacity(n * 8)
        var stack: [ItemID] = roots.reversed()
        while let id = stack.popLast() {
            guard store.isAlive(id), store.isFolder(id) else { continue }
            let parent = store.parent(id)
            let rawStart = rawBlob.count
            let foldStart = foldBlob.count
            if parent == invalidItem {
                store.withNameBytes(id) { rawBlob.append(contentsOf: $0) }
                store.withUnicodeFoldedBytes(id) { foldBlob.append(contentsOf: $0) }
            } else {
                let po = Int(offset[Int(parent)]), pl = Int(length[Int(parent)])
                rawBlob.append(contentsOf: rawBlob[po..<po + pl])
                if !(pl == 1 && rawBlob[po] == 0x2F) { rawBlob.append(0x2F) }
                store.withNameBytes(id) { rawBlob.append(contentsOf: $0) }
                let fo = Int(foldOffset[Int(parent)]), fl = Int(foldLength[Int(parent)])
                foldBlob.append(contentsOf: foldBlob[fo..<fo + fl])
                if !(fl == 1 && foldBlob[fo] == 0x2F) { foldBlob.append(0x2F) }
                store.withUnicodeFoldedBytes(id) { foldBlob.append(contentsOf: $0) }
            }
            offset[Int(id)] = Int32(rawStart)
            length[Int(id)] = Int32(rawBlob.count - rawStart)
            foldOffset[Int(id)] = Int32(foldStart)
            foldLength[Int(id)] = Int32(foldBlob.count - foldStart)
            store.forEachChild(of: id) { if store.isFolder($0) { stack.append($0) } }
        }
    }

    public func hasFolder(_ id: ItemID) -> Bool { Int(id) < offset.count && offset[Int(id)] >= 0 }

    /// Raw UTF-8 bytes of a folder's full path.
    @inlinable public func withRawFolderPath<R>(_ id: ItemID, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        let o = Int(offset[Int(id)]), l = Int(length[Int(id)])
        return rawBlob.withUnsafeBufferPointer { body(UnsafeBufferPointer(rebasing: $0[o..<o + l])) }
    }

    @inlinable public func withFoldedFolderPath<R>(_ id: ItemID, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        let o = Int(foldOffset[Int(id)]), l = Int(foldLength[Int(id)])
        return foldBlob.withUnsafeBufferPointer { body(UnsafeBufferPointer(rebasing: $0[o..<o + l])) }
    }

    /// Full path bytes of any item (folder path + "/" + name) into a scratch buffer.
    public func fullPathBytes(_ id: ItemID, store: ItemStore, folded: Bool, into scratch: inout [UInt8]) {
        scratch.removeAll(keepingCapacity: true)
        if store.isFolder(id) && hasFolder(id) {
            if folded { withFoldedFolderPath(id) { scratch.append(contentsOf: $0) } } else { withRawFolderPath(id) { scratch.append(contentsOf: $0) } }
            return
        }
        let parent = store.parent(id)
        if parent != invalidItem && hasFolder(parent) {
            if folded { withFoldedFolderPath(parent) { scratch.append(contentsOf: $0) } } else { withRawFolderPath(parent) { scratch.append(contentsOf: $0) } }
            if !(scratch.count == 1 && scratch[0] == 0x2F) { scratch.append(0x2F) }
        }
        if folded { store.withUnicodeFoldedBytes(id) { scratch.append(contentsOf: $0) } } else { store.withNameBytes(id) { scratch.append(contentsOf: $0) } }
    }

    /// Parent path bytes ("Path" column) of any item.
    public func parentPathBytes(_ id: ItemID, store: ItemStore, folded: Bool, into scratch: inout [UInt8]) {
        scratch.removeAll(keepingCapacity: true)
        let parent = store.parent(id)
        guard parent != invalidItem, hasFolder(parent) else { return }
        if folded { withFoldedFolderPath(parent) { scratch.append(contentsOf: $0) } } else { withRawFolderPath(parent) { scratch.append(contentsOf: $0) } }
    }

    public var byteCount: Int { rawBlob.count + foldBlob.count }
}
