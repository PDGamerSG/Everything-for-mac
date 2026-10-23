import Foundation
import Darwin

public struct ScanStats: Equatable, Sendable {
    public var files = 0
    public var folders = 0
    public var errors = 0
    public var seconds: Double = 0
    public var cancelled = false
    public init() {}
}

/// Parallel directory walker that fills an `Index` using getattrlistbulk.
public final class VolumeScanner {
    public let index: Index
    public var rules: ExcludeRules
    public var allowedDevices: Set<Int32>
    public var maxConcurrency: Int

    private let queue = DispatchQueue(label: "everything.scan", qos: .utility, attributes: .concurrent)
    private var statsLock = NSLock()
    private var stats = ScanStats()

    public init(index: Index, rules: ExcludeRules = .none, allowedDevices: Set<Int32> = [], maxConcurrency: Int = 0) {
        self.index = index
        self.rules = rules
        self.allowedDevices = allowedDevices
        self.maxConcurrency = maxConcurrency > 0 ? maxConcurrency : max(2, ProcessInfo.processInfo.activeProcessorCount * 2)
    }

    /// Scans `rootPath` and attaches everything under the existing root item `rootItem`.
    /// Existing children of `rootItem` are removed first (full rescan semantics).
    @discardableResult
    public func scan(rootPath: String, rootItem: ItemID, progress: ((Int) -> Void)? = nil, cancel: @escaping () -> Bool = { false }) -> ScanStats {
        let start = Date()
        statsLock.lock(); stats = ScanStats(); statsLock.unlock()
        index.write {
            for c in index.store.children(of: rootItem) { index.store.remove(c) }
        }
        if allowedDevices.isEmpty, let dev = Volumes.deviceID(of: rootPath) { allowedDevices = [dev] }
        let group = DispatchGroup()
        let sema = DispatchSemaphore(value: maxConcurrency)
        var counter = 0
        let counterLock = NSLock()

        func scanDir(_ path: String, _ parent: ItemID) {
            if cancel() { statsLock.lock(); stats.cancelled = true; statsLock.unlock(); return }
            let entries: [DirEntry]
            do { entries = try DirectoryLister.list(path) } catch {
                statsLock.lock(); stats.errors += 1; statsLock.unlock()
                return
            }
            var subdirs: [(String, ItemID)] = []
            var nf = 0, nd = 0
            index.write {
                let store = index.store
                for e in entries {
                    let childPath = Paths.join(path, e.name)
                    switch e.kind {
                    case .directory:
                        if !allowedDevices.isEmpty && !allowedDevices.contains(e.deviceID) { continue }
                        guard rules.allowsFolder(path: childPath, name: e.name, isHidden: e.isHidden, isSystem: e.isSystemProtected) else { continue }
                        let id = store.add(e.record(parent: parent))
                        nd += 1
                        subdirs.append((childPath, id))
                    case .file, .symlink, .other:
                        guard rules.allowsFile(path: childPath, name: e.name, isHidden: e.isHidden, isSystem: e.isSystemProtected) else { continue }
                        store.add(e.record(parent: parent))
                        nf += 1
                    }
                }
            }
            statsLock.lock(); stats.files += nf; stats.folders += nd; statsLock.unlock()
            if let progress = progress {
                counterLock.lock(); counter += nf + nd; let c = counter; counterLock.unlock()
                progress(c)
            }
            for (sp, sid) in subdirs {
                if sema.wait(timeout: .now()) == .success {
                    group.enter()
                    queue.async {
                        scanDir(sp, sid)
                        sema.signal()
                        group.leave()
                    }
                } else {
                    scanDir(sp, sid) // run inline when all workers are busy
                }
            }
        }

        scanDir(rootPath, rootItem)
        group.wait()
        statsLock.lock()
        stats.seconds = Date().timeIntervalSince(start)
        let result = stats
        statsLock.unlock()
        index.write { index.store.compactIfNeeded() }
        return result
    }

    /// Scans a single folder (non-recursive) and reconciles the index children of `item` with disk.
    /// Returns the set of changed item IDs (created/updated) and removed paths.
    public func reconcile(folderPath: String, item: ItemID) -> (created: [ItemID], updated: [ItemID], removed: [(ItemID, String)]) {
        guard let entries = try? DirectoryLister.list(folderPath) else { return ([], [], []) }
        var created: [ItemID] = [], updated: [ItemID] = [], removed: [(ItemID, String)] = []
        index.write {
            let store = index.store
            var existing: [String: ItemID] = [:]
            store.forEachChild(of: item) { existing[store.name($0)] = $0 }
            for e in entries {
                let childPath = Paths.join(folderPath, e.name)
                let allowed: Bool
                if e.kind == .directory {
                    allowed = (allowedDevices.isEmpty || allowedDevices.contains(e.deviceID)) && rules.allowsFolder(path: childPath, name: e.name, isHidden: e.isHidden, isSystem: e.isSystemProtected)
                } else {
                    allowed = rules.allowsFile(path: childPath, name: e.name, isHidden: e.isHidden, isSystem: e.isSystemProtected)
                }
                if let id = existing.removeValue(forKey: e.name) {
                    if !allowed { removed.append((id, childPath)); store.remove(id); continue }
                    let r = e.record(parent: item)
                    if store.fileSize(id) != r.size || store.dateModified(id) != r.dateModified || store.flags(id) != r.flags || store.inode(id) != r.inode {
                        store.update(id, size: r.size, dateModified: r.dateModified, dateCreated: r.dateCreated, dateAccessed: r.dateAccessed,
                                     dateChanged: r.dateChanged, flags: r.flags, inode: r.inode)
                        updated.append(id)
                    }
                } else if allowed {
                    let id = store.add(e.record(parent: item))
                    created.append(id)
                }
            }
            for (name, id) in existing { removed.append((id, Paths.join(folderPath, name))); store.remove(id) }
        }
        return (created, updated, removed)
    }
}
