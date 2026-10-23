import Foundation
@testable import EverythingCore

/// Builds a temporary directory tree for scanner/monitor tests.
enum Fixtures {
    struct Tree {
        let root: URL
        var files = 0
        var folders = 0
        var paths: [String] = []
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    static func makeTree(files perDir: Int = 20, depth: Int = 4, fanout: Int = 3, unicode: Bool = true) throws -> Tree {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("evt-fixture-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var tree = Tree(root: root)
        func fill(_ dir: URL, _ level: Int) throws {
            for i in 0..<perDir {
                let ext = ["txt", "jpg", "mp3", "swift", "PDF", ""][i % 6]
                var name = "file\(level)_\(i)" + (ext.isEmpty ? "" : "." + ext)
                if unicode && i % 5 == 0 { name = "Üñíçødé-文件\(level)_\(i).txt" }
                if i % 7 == 0 { name = "." + name }  // hidden
                let url = dir.appendingPathComponent(name)
                try Data(repeating: 0x41, count: i * 10).write(to: url)
                tree.files += 1; tree.paths.append(url.path)
            }
            // a symlink to the root (must not be followed)
            let link = dir.appendingPathComponent("link-to-root")
            try fm.createSymbolicLink(at: link, withDestinationURL: root)
            tree.files += 1; tree.paths.append(link.path)
            if level < depth {
                for j in 0..<fanout {
                    let sub = dir.appendingPathComponent(j == 0 && unicode ? "Ordner \(level)-\(j) ä" : "dir\(level)_\(j)", isDirectory: true)
                    try fm.createDirectory(at: sub, withIntermediateDirectories: true)
                    tree.folders += 1; tree.paths.append(sub.path)
                    try fill(sub, level + 1)
                }
                let bundle = dir.appendingPathComponent("Thing\(level).app", isDirectory: true)
                try fm.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
                tree.folders += 3
                try Data("x".utf8).write(to: bundle.appendingPathComponent("Contents/MacOS/Thing"))
                tree.files += 1
            }
        }
        try fill(root, 0)
        return tree
    }
}
