import Testing
import Foundation
@testable import EverythingCore

@Suite struct ScannerTests {
    @Test func listDirectoryMatchesFileManager() throws {
        let tree = try Fixtures.makeTree(files: 10, depth: 1, fanout: 2)
        defer { tree.cleanup() }
        let entries = try DirectoryLister.list(tree.root.path)
        let names = Set(entries.map { $0.name })
        let expected = Set(try FileManager.default.contentsOfDirectory(atPath: tree.root.path))
        #expect(names == expected)
        let link = entries.first { $0.name == "link-to-root" }
        #expect(link?.kind == .symlink)
        let app = entries.first { $0.name == "Thing0.app" }
        #expect(app?.kind == .directory)
        #expect(app?.itemFlags().contains(.package) == true)
        let hidden = entries.first { $0.name.hasPrefix(".") }
        #expect(hidden?.isHidden == true)
        let f = entries.first { $0.name == "file0_3.swift" }
        #expect(f?.size == 30)
        #expect((f?.dateModified ?? 0) > 1_000_000_000_000_000_000)
        #expect((f?.fileID ?? 0) > 0)
    }

    @Test func fullScanCountsAndPaths() throws {
        let tree = try Fixtures.makeTree(files: 20, depth: 3, fanout: 3)
        defer { tree.cleanup() }
        let index = Index()
        let root = index.addRoot(kind: .folder, path: tree.root.path, label: "fixture")
        let scanner = VolumeScanner(index: index)
        let stats = scanner.scan(rootPath: tree.root.path, rootItem: root.item)
        #expect(stats.files == tree.files)
        #expect(stats.folders == tree.folders)
        #expect(stats.errors == 0)
        #expect(index.store.count == tree.files + tree.folders + 1)
        for p in tree.paths.prefix(50) {
            let id = index.lookup(path: p)
            #expect(id != nil, "missing \(p)")
            if let id = id { #expect(index.store.fullPath(id) == p) }
        }
        // symlink not followed: nothing under link-to-root
        let link = index.lookup(path: tree.root.appendingPathComponent("link-to-root").path)!
        #expect(index.store.childCount(link) == 0)
        #expect(index.store.flags(link).contains(.symlink))
    }

    @Test func excludeRulesHonored() throws {
        let tree = try Fixtures.makeTree(files: 12, depth: 2, fanout: 2)
        defer { tree.cleanup() }
        let index = Index()
        let root = index.addRoot(kind: .folder, path: tree.root.path, label: "fixture")
        let rules = ExcludeRules(excludeHidden: true, excludeFolders: ["*/dir1_1", "*.app"], excludeFiles: ["*.jpg", "regex:_5\\.txt$"])
        let scanner = VolumeScanner(index: index, rules: rules)
        scanner.scan(rootPath: tree.root.path, rootItem: root.item)
        let s = index.store
        for i in 0..<s.slotCount where s.isAlive(ItemID(i)) {
            let id = ItemID(i)
            let name = s.name(id)
            if id == root.item { continue }
            #expect(!name.hasPrefix("."), "hidden leaked: \(name)")
            #expect(!name.hasSuffix(".jpg"))
            #expect(!name.hasSuffix(".app"))
            #expect(name != "dir1_1")
            #expect(!name.hasSuffix("_5.txt"))
            #expect(!s.fullPath(id).contains("/dir1_1/"))
        }
        #expect(index.lookup(path: tree.root.appendingPathComponent("dir0_1/file1_1.jpg").path) == nil)
        #expect(index.lookup(path: tree.root.appendingPathComponent("dir0_1/file1_3.swift").path) != nil)
    }

    @Test func includeOnlyFolders() throws {
        let tree = try Fixtures.makeTree(files: 5, depth: 2, fanout: 2, unicode: false)
        defer { tree.cleanup() }
        let index = Index()
        let root = index.addRoot(kind: .folder, path: tree.root.path, label: "fixture")
        let only = tree.root.appendingPathComponent("dir0_1").path
        let scanner = VolumeScanner(index: index, rules: ExcludeRules(includeOnlyFolders: [only]))
        scanner.scan(rootPath: tree.root.path, rootItem: root.item)
        #expect(index.lookup(path: only) != nil)
        #expect(index.lookup(path: tree.root.appendingPathComponent("dir0_1/file1_1.jpg").path) != nil)
        #expect(index.lookup(path: tree.root.appendingPathComponent("dir0_0").path) == nil)
        #expect(index.lookup(path: tree.root.appendingPathComponent("file0_1.jpg").path) == nil)
    }

    @Test func reconcileDetectsChanges() throws {
        let tree = try Fixtures.makeTree(files: 5, depth: 1, fanout: 1, unicode: false)
        defer { tree.cleanup() }
        let index = Index()
        let root = index.addRoot(kind: .folder, path: tree.root.path, label: "fixture")
        let scanner = VolumeScanner(index: index)
        scanner.scan(rootPath: tree.root.path, rootItem: root.item)
        let newFile = tree.root.appendingPathComponent("brand-new.txt")
        try Data("hello".utf8).write(to: newFile)
        try FileManager.default.removeItem(at: tree.root.appendingPathComponent("file0_1.jpg"))
        try Data("bigger content".utf8).write(to: tree.root.appendingPathComponent("file0_2.mp3"))
        let r = scanner.reconcile(folderPath: tree.root.path, item: root.item)
        #expect(r.created.count == 1)
        #expect(r.removed.count == 1)
        #expect(r.updated.count == 1)
        #expect(index.lookup(path: newFile.path) != nil)
        #expect(index.lookup(path: tree.root.appendingPathComponent("file0_1.jpg").path) == nil)
    }

    @Test func mountedVolumesIncludesRoot() {
        let vols = Volumes.mounted()
        #expect(vols.contains { $0.isRoot && $0.mountPoint == "/" })
        let root = vols.first { $0.isRoot }!
        #expect(root.fileSystem == "apfs")
        #expect(root.deviceID != 0)
    }

    @Test func scanSystemAreaCrossesFirmlinksNotOtherVolumes() throws {
        // /Applications lives on the Data volume reached through a firmlink from "/"
        let index = Index()
        let root = index.addRoot(kind: .volume, path: "/", label: "root")
        let vol = Volumes.mounted().first { $0.isRoot }!
        let rules = ExcludeRules(excludeFolders: ["/Volumes", "/System", "/Library", "/Users", "/private", "/usr", "/opt", "/bin", "/sbin", "/cores", "/home", "/etc", "/var", "/tmp", "/dev"])
        let scanner = VolumeScanner(index: index, rules: rules, allowedDevices: vol.allDeviceIDs)
        let stats = scanner.scan(rootPath: "/", rootItem: root.item)
        #expect(stats.folders > 10)
        #expect(index.lookup(path: "/Applications") != nil)
        #expect(index.lookup(path: "/Applications/Utilities") != nil)
    }
}
