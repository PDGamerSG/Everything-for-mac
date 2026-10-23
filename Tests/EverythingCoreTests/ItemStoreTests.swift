import Testing
import Foundation
@testable import EverythingCore

@Suite struct ItemStoreTests {
    func makeTree() -> (Index, ItemID, ItemID, ItemID) {
        let index = Index()
        let root = index.addRoot(kind: .volume, path: "/", label: "Macintosh HD")
        let users = index.store.add(ItemRecord(name: "Users", parent: root.item, flags: [.folder]))
        let admin = index.store.add(ItemRecord(name: "admin", parent: users, flags: [.folder]))
        let file = index.store.add(ItemRecord(name: "Résumé.PDF", parent: admin, size: 1234, dateModified: 5))
        return (index, root.item, admin, file)
    }

    @Test func addFindFullPath() {
        let (index, root, admin, file) = makeTree()
        let s = index.store
        #expect(s.count == 4)
        #expect(s.fullPath(file) == "/Users/admin/Résumé.PDF")
        #expect(s.path(file) == "/Users/admin")
        #expect(s.fullPath(root) == "/")
        #expect(s.fullPath(admin) == "/Users/admin")
        #expect(index.lookup(path: "/Users/admin/Résumé.PDF") == file)
        #expect(index.lookup(path: "/users/ADMIN/résumé.pdf") == file)
        #expect(index.lookup(path: "/Users/nobody") == nil)
        #expect(s.extensionName(file) == "PDF")
        #expect(s.extensions.lowerName(s.extensionID(file)) == "pdf")
        #expect(s.stem(file) == "Résumé")
        #expect(s.depth(file) == 3)
        #expect(!s.nameIsASCII(file))
        s.withUnicodeFoldedBytes(file) { #expect(String(decoding: $0, as: UTF8.self) == "resume.pdf") }
        #expect(s.childCount(admin) == 1)
    }

    @Test func renameMoveRemove() {
        let (index, root, admin, file) = makeTree()
        let s = index.store
        s.rename(file, to: "cv.txt")
        #expect(s.fullPath(file) == "/Users/admin/cv.txt")
        #expect(s.extensionName(file) == "txt")
        let tmp = s.add(ItemRecord(name: "tmp", parent: root, flags: [.folder]))
        s.move(admin, toParent: tmp)
        #expect(s.fullPath(file) == "/tmp/admin/cv.txt")
        #expect(s.childCount(tmp) == 1)
        let removed = s.remove(tmp)
        #expect(removed == 3)
        #expect(s.count == 2)
        #expect(!s.isAlive(file))
        #expect(index.lookup(path: "/tmp") == nil)
        // slot reuse keeps other IDs stable
        let n = s.add(ItemRecord(name: "new.txt", parent: root))
        #expect(s.isAlive(n))
        #expect(s.fullPath(root) == "/")
        s.compact()
        #expect(s.fullPath(n) == "/new.txt")
    }

    @Test func extensionTable() {
        let t = ExtensionTable()
        let a = t.id(for: "TXT"), b = t.id(for: "txt"), c = t.id(for: "jpg")
        #expect(a == b)
        #expect(a != c)
        #expect(t.name(0) == "")
        #expect(t.ids(matching: "j*") == [c])
        #expect(ItemStore.extensionOf(".bashrc") == "")
        #expect(ItemStore.extensionOf("archive.tar.gz") == "gz")
        #expect(ItemStore.extensionOf("noext") == "")
    }

    @Test func flagsMapping() {
        let f: ItemFlags = [.hidden, .locked, .folder]
        #expect(f.letters == "DHR")
        #expect(ItemFlags.fromWindowsAttributes(f.windowsAttributes) == f)
        #expect(ItemFlags.fromLetters("hr") == [.hidden, .locked])
        #expect(ItemFlags.fromLetters("q") == nil)
        #expect(ItemFlags([]).windowsAttributes == 0x80)
    }

    @Test func folderSizes() {
        let (index, root, admin, file) = makeTree()
        let s = index.store
        s.enableFolderSizeTracking()
        #expect(s.size(admin) == 1234)
        #expect(s.size(root) == 1234)
        s.update(file, size: 2000)
        #expect(s.size(root) == 2000)
        s.remove(file)
        #expect(s.size(admin) == 0)
    }

    @Test func filetime() {
        let ns: Int64 = 1_700_000_000_000_000_000
        let ft = Timestamps.toFiletime(ns)
        #expect(Timestamps.fromFiletime(ft) == ns)
        #expect(Timestamps.toFiletime(0) == 0)
    }

    @Test func ensureFolderCreatesChain() {
        let index = Index()
        _ = index.addRoot(kind: .volume, path: "/", label: "root")
        let id = index.ensureFolder(path: "/a/b/c")!
        #expect(index.store.fullPath(id) == "/a/b/c")
        #expect(index.ensureFolder(path: "/a/b") == index.store.parent(id))
        #expect(index.ensureFolder(path: "/Volumes/X/y") != nil) // under "/" root
        #expect(index.store.count == 7)
    }
}
