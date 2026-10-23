import Foundation

public enum RootKind: UInt8, Codable, Sendable {
    case volume = 0
    case folder = 1
    case fileList = 2
    case network = 3
}

/// A top-level indexed location: a mounted volume, a user folder, a file list, or a remote index.
public struct Root: Equatable, Sendable {
    public var kind: RootKind
    public var path: String            // mount point or folder path or file list path or host
    public var label: String           // volume name / display name
    public var uuid: String
    public var item: ItemID            // the root item in the store
    public var lastEventID: UInt64     // FSEvents event id after last applied change
    public var scanDate: Int64         // ns since 1970
    public var includeOnly: [String]   // folder include-only patterns (volume/folder/network)
    public var monitor: Bool
    public var deviceID: Int32         // st_dev at scan time
    public var fileSystem: String
    public var online: Bool

    public init(kind: RootKind, path: String, label: String, uuid: String, item: ItemID, lastEventID: UInt64 = 0,
                scanDate: Int64 = 0, includeOnly: [String] = [], monitor: Bool = true, deviceID: Int32 = 0,
                fileSystem: String = "", online: Bool = true) {
        self.kind = kind; self.path = path; self.label = label; self.uuid = uuid; self.item = item
        self.lastEventID = lastEventID; self.scanDate = scanDate; self.includeOnly = includeOnly
        self.monitor = monitor; self.deviceID = deviceID; self.fileSystem = fileSystem; self.online = online
    }
}

/// The whole index: a store plus the registry of roots, guarded by a reader/writer lock.
public final class Index: @unchecked Sendable {
    public let store: ItemStore
    public private(set) var roots: [Root] = []
    private var rwlock = pthread_rwlock_t()
    public var dbLoaded = false

    public init(store: ItemStore = ItemStore()) {
        self.store = store
        pthread_rwlock_init(&rwlock, nil)
    }

    deinit { pthread_rwlock_destroy(&rwlock) }

    // MARK: locking

    public func read<R>(_ body: () throws -> R) rethrows -> R {
        pthread_rwlock_rdlock(&rwlock); defer { pthread_rwlock_unlock(&rwlock) }
        return try body()
    }

    public func write<R>(_ body: () throws -> R) rethrows -> R {
        pthread_rwlock_wrlock(&rwlock); defer { pthread_rwlock_unlock(&rwlock) }
        return try body()
    }

    // MARK: roots (call inside write)

    @discardableResult
    public func addRoot(kind: RootKind, path: String, label: String, uuid: String = "", includeOnly: [String] = [],
                        monitor: Bool = true, deviceID: Int32 = 0, fileSystem: String = "", itemName: String? = nil) -> Root {
        if let existing = roots.first(where: { $0.path == path && $0.kind == kind }) { return existing }
        var flags: ItemFlags = [.folder, .root]
        if kind == .fileList { flags.insert(.fileList) }
        let id = store.add(ItemRecord(name: itemName ?? path, parent: invalidItem, flags: flags))
        let r = Root(kind: kind, path: path, label: label, uuid: uuid, item: id, includeOnly: includeOnly,
                     monitor: monitor, deviceID: deviceID, fileSystem: fileSystem)
        roots.append(r)
        return r
    }

    public func removeRoot(_ root: Root) {
        guard let i = roots.firstIndex(where: { $0.item == root.item }) else { return }
        store.remove(root.item)
        roots.remove(at: i)
    }

    public func updateRoot(_ root: Root) {
        guard let i = roots.firstIndex(where: { $0.item == root.item }) else { return }
        roots[i] = root
    }

    public func setRoots(_ newRoots: [Root]) { roots = newRoots }

    public func root(containing id: ItemID) -> Root? {
        let r = store.root(of: id)
        return roots.first { $0.item == r }
    }

    public func root(forPath path: String) -> Root? {
        var best: Root? = nil
        for r in roots {
            let rp = r.path
            if path == rp || path.hasPrefix(rp.hasSuffix("/") ? rp : rp + "/") {
                if best == nil || rp.count > best!.path.count { best = r }
            }
        }
        return best
    }

    public var rootItems: [ItemID] { roots.map { $0.item } }

    // MARK: lookup

    public func lookup(path: String) -> ItemID? {
        store.find(path: Paths.normalize(path), roots: rootItems)
    }

    /// Ensures the folder chain for `path` exists under its root, creating missing folders.
    /// Returns nil when no root covers the path.
    public func ensureFolder(path: String) -> ItemID? {
        let p = Paths.normalize(path)
        guard let root = root(forPath: p) else { return nil }
        var rest = Substring(p.dropFirst(root.path.count))
        if rest.hasPrefix("/") { rest = rest.dropFirst() }
        var cur = root.item
        for comp in rest.split(separator: "/") {
            if let c = store.childCaseInsensitive(of: cur, named: String(comp)) {
                cur = c
            } else {
                cur = store.add(ItemRecord(name: String(comp), parent: cur, flags: [.folder]))
            }
        }
        return cur
    }

    public var statistics: IndexStatistics {
        var files = 0, folders = 0
        for i in 0..<store.slotCount where store.isAlive(ItemID(i)) {
            if store.isFolder(ItemID(i)) { folders += 1 } else { files += 1 }
        }
        return IndexStatistics(files: files, folders: folders, roots: roots.count, nameBytes: store.nameBlob.count,
                               slots: store.slotCount, generation: store.generation)
    }
}

public struct IndexStatistics: Equatable, Sendable {
    public var files: Int
    public var folders: Int
    public var roots: Int
    public var nameBytes: Int
    public var slots: Int
    public var generation: UInt64
    public var total: Int { files + folders }
}
