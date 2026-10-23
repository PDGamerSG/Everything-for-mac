import Testing
import Foundation
@testable import EverythingCore

@Suite struct IndexDBTests {
    func buildIndex(items: Int) -> Index {
        let index = Index()
        let root = index.addRoot(kind: .volume, path: "/", label: "Macintosh HD", uuid: "UUID-1", deviceID: 42, fileSystem: "apfs")
        var folders: [ItemID] = [root.item]
        var rng = SystemRandomNumberGenerator()
        for i in 0..<items {
            let parent = folders[Int.random(in: 0..<folders.count, using: &rng)]
            if i % 10 == 0 {
                folders.append(index.store.add(ItemRecord(name: "dir\(i)", parent: parent, flags: [.folder])))
            } else {
                let name = i % 7 == 0 ? "файл\(i).txt" : "file\(i).\(["txt","jpg","mp3","swift"][i % 4])"
                index.store.add(ItemRecord(name: name, parent: parent, flags: i % 13 == 0 ? [.hidden] : [], size: UInt64(i * 100),
                                           dateModified: Int64(i) * 1_000_000_000, dateCreated: 7, dateAccessed: 8, dateChanged: 9, inode: UInt64(i + 1000)))
            }
        }
        // some removals to create tombstones
        for id in folders.suffix(3) { index.store.remove(id) }
        var r = root; r.lastEventID = 999_999; r.scanDate = 123; r.includeOnly = ["/Users"]
        index.updateRoot(r)
        return index
    }

    @Test func roundTrip() throws {
        let index = buildIndex(items: 20_000)
        let data = IndexDB.encode(index)
        let loaded = try IndexDB.decode(data)
        let a = index.store, b = loaded.store
        #expect(a.count == b.count)
        #expect(a.slotCount == b.slotCount)
        #expect(loaded.roots.count == 1)
        #expect(loaded.roots[0].lastEventID == 999_999)
        #expect(loaded.roots[0].includeOnly == ["/Users"])
        #expect(loaded.roots[0].deviceID == 42)
        #expect(loaded.roots[0].fileSystem == "apfs")
        #expect(loaded.dbLoaded)
        for i in 0..<a.slotCount where a.isAlive(ItemID(i)) {
            let id = ItemID(i)
            #expect(b.isAlive(id))
            #expect(a.fullPath(id) == b.fullPath(id))
            #expect(a.size(id) == b.size(id))
            #expect(a.dateModified(id) == b.dateModified(id))
            #expect(a.flags(id) == b.flags(id))
            #expect(a.extensionName(id) == b.extensionName(id))
            #expect(a.childCount(id) == b.childCount(id))
            #expect(a.nameIsASCII(id) == b.nameIsASCII(id))
            if i > 200 { break }
        }
        // child lists equal as sets
        let rootA = index.roots[0].item
        #expect(Set(a.children(of: rootA)) == Set(b.children(of: rootA)))
        // adding after load reuses tombstones and works
        let n = b.add(ItemRecord(name: "after.txt", parent: loaded.roots[0].item))
        #expect(b.fullPath(n) == "/after.txt")
    }

    @Test func saveLoadFile() throws {
        let index = buildIndex(items: 500)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("evt-\(UUID().uuidString).db")
        try IndexDB.save(index, to: url)
        let loaded = try IndexDB.load(from: url)
        #expect(loaded.store.count == index.store.count)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func corruptionDetected() throws {
        let index = buildIndex(items: 100)
        var data = IndexDB.encode(index)
        data[100] ^= 0xFF
        #expect(throws: IndexDB.DBError.badCRC) { try IndexDB.decode(data) }
        var bad = data; bad[0] = 0x58
        #expect(throws: IndexDB.DBError.badMagic) { try IndexDB.decode(bad) }
        #expect(throws: IndexDB.DBError.truncated) { try IndexDB.decode(Data([1, 2, 3])) }
    }
}
