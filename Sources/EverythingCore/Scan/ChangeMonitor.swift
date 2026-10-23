import Foundation
import CoreServices

/// A change applied to the index, reported to listeners (search sessions, UI).
public enum IndexChange: Equatable, Sendable {
    case created(ItemID)
    case removed(ItemID, path: String)
    case renamed(ItemID, oldPath: String)
    case moved(ItemID, oldPath: String)
    case modified(ItemID)

    public var id: ItemID {
        switch self {
        case .created(let i), .modified(let i): return i
        case .removed(let i, _), .renamed(let i, _), .moved(let i, _): return i
        }
    }
}

/// Keeps the index current using FSEvents (one stream per root) and applies changes through the journal.
public final class ChangeMonitor: @unchecked Sendable {
    public let index: Index
    public let journal: IndexJournal
    public var rules: ExcludeRules
    public var allowedDevices: [ItemID: Set<Int32>] = [:]
    public var latency: TimeInterval = 0.5
    public var onChanges: (([IndexChange]) -> Void)?
    public var onRootChanged: ((Root) -> Void)?
    public var log: ((String) -> Void)?
    public private(set) var paused = false
    public private(set) var isRunning = false
    private let queue = DispatchQueue(label: "everything.monitor", qos: .utility)
    private var streams: [ItemID: FSEventStreamRef] = [:]
    /// FSEvents reports canonical paths (e.g. `/private/var/...`); map them back to the indexed root path.
    private var realPaths: [(real: String, root: Root)] = []
    private var pendingWhilePaused: [(ItemID, [String], [FSEventStreamEventFlags])] = []
    private let lock = NSLock()
    public var statistics = Statistics()

    public struct Statistics: Equatable, Sendable {
        public var created = 0, removed = 0, renamed = 0, moved = 0, modified = 0, rescans = 0, events = 0
        public init() {}
    }

    public init(index: Index, journal: IndexJournal, rules: ExcludeRules = .none) {
        self.index = index
        self.journal = journal
        self.rules = rules
    }

    deinit { stopAll() }

    // MARK: lifecycle

    public func start(root: Root, sinceEventID: UInt64? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard streams[root.item] == nil else { return }
        guard root.kind == .volume || root.kind == .folder else { return }
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let paths = [root.path] as CFArray
        let since: FSEventStreamEventId = sinceEventID.map { FSEventStreamEventId($0) } ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        let flags: FSEventStreamCreateFlags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, { _, info, numEvents, eventPaths, eventFlags, _ in
            guard let info = info else { return }
            let monitor = Unmanaged<ChangeMonitor>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let flags = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))
            monitor.handle(paths: paths, flags: flags)
        }, &context, paths, since, latency, flags) else {
            log?("FSEventStreamCreate failed for \(root.path)")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        if !FSEventStreamStart(stream) {
            log?("FSEventStreamStart failed for \(root.path)")
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            return
        }
        streams[root.item] = stream
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let real = realpath(root.path, &buf).map { String(cString: $0) } ?? root.path
        realPaths.removeAll { $0.root.item == root.item }
        realPaths.append((Paths.normalize(real), root))
        realPaths.sort { $0.real.count > $1.real.count }
        isRunning = true
        log?("Monitoring \(root.path) since \(sinceEventID.map(String.init) ?? "now")")
    }

    public func stop(root: Root) {
        lock.lock(); defer { lock.unlock() }
        guard let s = streams.removeValue(forKey: root.item) else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        realPaths.removeAll { $0.root.item == root.item }
        isRunning = !streams.isEmpty
    }

    public func stopAll() {
        lock.lock(); defer { lock.unlock() }
        for (_, s) in streams { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
        streams.removeAll()
        isRunning = false
    }

    public func pause() { lock.lock(); paused = true; lock.unlock() }

    public func resume() {
        lock.lock()
        paused = false
        let pending = pendingWhilePaused
        pendingWhilePaused.removeAll()
        lock.unlock()
        for (root, paths, flags) in pending { queue.async { self.process(rootItem: root, paths: paths, flags: flags) } }
    }

    /// Flushes buffered events synchronously (tests).
    public func flush() {
        lock.lock(); let ss = Array(streams.values); lock.unlock()
        for s in ss { FSEventStreamFlushSync(s) }
        queue.sync {}
    }

    public static var currentEventID: UInt64 { UInt64(FSEventsGetCurrentEventId()) }

    // MARK: event handling

    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        statistics.events += paths.count
        // group by root
        var byRoot: [ItemID: ([String], [FSEventStreamEventFlags])] = [:]
        lock.lock(); let mapping = realPaths; lock.unlock()
        for (p, f) in zip(paths, flags) {
            var norm = ChangeMonitor.remapFirmlink(Paths.normalize(p))
            var rootItem: ItemID? = nil
            for (real, root) in mapping where norm == real || norm.hasPrefix(real.hasSuffix("/") ? real : real + "/") {
                if real != root.path { norm = Paths.normalize(Paths.join(root.path, String(norm.dropFirst(real.count)))) }
                rootItem = root.item
                break
            }
            if rootItem == nil { rootItem = index.read({ index.root(forPath: norm) })?.item }
            guard let r = rootItem else { continue }
            byRoot[r, default: ([], [])].0.append(norm)
            byRoot[r, default: ([], [])].1.append(f)
        }
        for (root, pf) in byRoot {
            lock.lock()
            if paused { pendingWhilePaused.append((root, pf.0, pf.1)); lock.unlock(); continue }
            lock.unlock()
            process(rootItem: root, paths: pf.0, flags: pf.1)
        }
        let eventID = ChangeMonitor.currentEventID
        index.write {
            for r in index.roots where byRoot[r.item] != nil { var rr = r; rr.lastEventID = eventID; index.updateRoot(rr) }
        }
    }

    /// FSEvents reports Data-volume paths through their mount point; the index stores them via firmlinks under `/`.
    static func remapFirmlink(_ p: String) -> String {
        if p.hasPrefix("/System/Volumes/Data/") { return String(p.dropFirst("/System/Volumes/Data".count)) }
        if p == "/System/Volumes/Data" { return "/" }
        return p
    }

    private func process(rootItem: ItemID, paths: [String], flags: [FSEventStreamEventFlags]) {
        var changes: [IndexChange] = []
        var removedByInode: [UInt64: (ItemID, String)] = [:]
        var rescanPaths: [String] = []
        let fileFlags = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified |
                               kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemChangeOwner | kFSEventStreamEventFlagItemXattrMod |
                               kFSEventStreamEventFlagItemFinderInfoMod | kFSEventStreamEventFlagItemCloned)
        // pass 1: disappearances (so renames can be matched by inode in pass 2)
        for (p, f) in zip(paths, flags) {
            if f & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
                if let r = index.read({ index.roots.first { $0.item == rootItem } }) { onRootChanged?(r) }
                continue
            }
            if f & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
                rescanPaths.append(p)
                continue
            }
            guard f & fileFlags != 0 else { continue }
            if DirectoryLister.entry(atPath: p) == nil, let id = index.read({ index.lookup(path: p) }) {
                let inode = index.store.inode(id)
                if f & UInt32(kFSEventStreamEventFlagItemRenamed) != 0, inode != 0 { removedByInode[inode] = (id, p) }
                else { changes.append(contentsOf: remove(id: id, path: p)) }
            }
        }
        // pass 2: existing paths
        for (p, f) in zip(paths, flags) {
            guard f & fileFlags != 0, f & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged) == 0 else { continue }
            guard let entry = DirectoryLister.entry(atPath: p) else { continue }
            let existing = index.read { index.lookup(path: p) }
            if let id = existing {
                // same path still exists: metadata or content change (or replaced by a different inode)
                changes.append(contentsOf: update(id: id, path: p, entry: entry))
                continue
            }
            // new path: rename/move target?
            if entry.fileID != 0, let (oldID, oldPath) = removedByInode.removeValue(forKey: entry.fileID), index.store.isAlive(oldID) {
                changes.append(contentsOf: relocate(id: oldID, oldPath: oldPath, newPath: p, entry: entry))
                continue
            }
            changes.append(contentsOf: create(path: p, entry: entry))
        }
        // unmatched renamed-away items are deletions
        for (_, (id, p)) in removedByInode where index.store.isAlive(id) { changes.append(contentsOf: remove(id: id, path: p)) }
        for p in rescanPaths { changes.append(contentsOf: rescan(path: p)) }
        if !changes.isEmpty { onChanges?(changes) }
    }

    // MARK: apply

    private func create(path: String, entry: DirEntry) -> [IndexChange] {
        let name = Paths.lastComponent(path)
        let parentPath = Paths.parent(path)
        let isDir = entry.kind == .directory
        if isDir {
            guard rules.allowsFolder(path: path, name: name, isHidden: entry.isHidden, isSystem: entry.isSystemProtected) else { return [] }
        } else {
            guard rules.allowsFile(path: path, name: name, isHidden: entry.isHidden, isSystem: entry.isSystemProtected) else { return [] }
        }
        var out: [IndexChange] = []
        let created: ItemID? = index.write {
            guard let parent = index.ensureFolder(path: parentPath) else { return nil }
            if let dup = index.store.childCaseInsensitive(of: parent, named: name) { return dup }
            return index.store.add(entry.record(parent: parent))
        }
        guard let id = created else { return [] }
        out.append(.created(id))
        statistics.created += 1
        journal.append(isDir ? .folderCreate : .fileCreate, name: name, path: parentPath, size: entry.size)
        if isDir {
            // new folder may already contain files (e.g. moved in from an unindexed location or created quickly)
            let scanner = VolumeScanner(index: index, rules: rules, allowedDevices: allowedDevices[index.store.root(of: id)] ?? [], maxConcurrency: 4)
            let stats = scanner.scan(rootPath: path, rootItem: id)
            if stats.files + stats.folders > 0 {
                index.read { index.store.forEachChild(of: id) { out.append(.created($0)) } }
            }
        }
        return out
    }

    private func remove(id: ItemID, path: String) -> [IndexChange] {
        let s = index.store
        let isDir = s.isFolder(id)
        let name = s.name(id)
        let parent = Paths.parent(path)
        var out: [IndexChange] = [.removed(id, path: path)]
        if isDir { index.read { collectDescendants(id, into: &out) } }
        index.write { s.remove(id) }
        statistics.removed += 1
        journal.append(isDir ? .folderDelete : .fileDelete, name: name, path: parent)
        return out
    }

    private func collectDescendants(_ id: ItemID, into out: inout [IndexChange]) {
        let s = index.store
        var stack: [ItemID] = [id]
        while let cur = stack.popLast() {
            s.forEachChild(of: cur) { c in
                out.append(.removed(c, path: s.fullPath(c)))
                if s.isFolder(c) { stack.append(c) }
            }
        }
    }

    private func update(id: ItemID, path: String, entry: DirEntry) -> [IndexChange] {
        let s = index.store
        let r = entry.record(parent: s.parent(id))
        let wasFolder = s.isFolder(id)
        if wasFolder != (entry.kind == .directory) {
            // replaced by a different kind of item
            var out = remove(id: id, path: path)
            out.append(contentsOf: create(path: path, entry: entry))
            return out
        }
        var changed = false
        index.write {
            if s.fileSize(id) != r.size || s.dateModified(id) != r.dateModified || s.flags(id) != r.flags || s.inode(id) != r.inode || s.dateChanged(id) != r.dateChanged {
                s.update(id, size: r.size, dateModified: r.dateModified, dateCreated: r.dateCreated, dateAccessed: r.dateAccessed, dateChanged: r.dateChanged, flags: r.flags, inode: r.inode)
                changed = true
            }
        }
        guard changed else { return [] }
        statistics.modified += 1
        journal.append(wasFolder ? .folderModify : .fileModify, name: s.name(id), path: Paths.parent(path), size: r.size)
        return [.modified(id)]
    }

    private func relocate(id: ItemID, oldPath: String, newPath: String, entry: DirEntry) -> [IndexChange] {
        let s = index.store
        let newName = Paths.lastComponent(newPath)
        let newParentPath = Paths.parent(newPath)
        let oldParentPath = Paths.parent(oldPath)
        let isDir = s.isFolder(id)
        let allowed = isDir ? rules.allowsFolder(path: newPath, name: newName, isHidden: entry.isHidden, isSystem: entry.isSystemProtected)
                            : rules.allowsFile(path: newPath, name: newName, isHidden: entry.isHidden, isSystem: entry.isSystemProtected)
        guard allowed else { return remove(id: id, path: oldPath) }
        let oldName = s.name(id)
        var out: [IndexChange] = []
        let ok: Bool = index.write {
            guard let newParent = index.ensureFolder(path: newParentPath) else { return false }
            if s.parent(id) != newParent { s.move(id, toParent: newParent) }
            if oldName != newName { s.rename(id, to: newName) }
            s.update(id, size: entry.kind == .file ? entry.size : nil, dateModified: entry.dateModified, dateChanged: entry.dateChanged, flags: entry.itemFlags())
            return true
        }
        guard ok else { return remove(id: id, path: oldPath) }
        if oldParentPath == newParentPath {
            statistics.renamed += 1
            journal.append(isDir ? .folderRename : .fileRename, name: oldName, path: oldParentPath, newName: newName, newPath: newParentPath, size: entry.size)
            out.append(.renamed(id, oldPath: oldPath))
        } else {
            statistics.moved += 1
            journal.append(isDir ? .folderMove : .fileMove, name: oldName, path: oldParentPath, newName: newName, newPath: newParentPath, size: entry.size)
            out.append(.moved(id, oldPath: oldPath))
        }
        if isDir { index.read { var desc: [IndexChange] = []; collectDescendantsModified(id, into: &desc); out.append(contentsOf: desc) } }
        return out
    }

    private func collectDescendantsModified(_ id: ItemID, into out: inout [IndexChange]) {
        let s = index.store
        var stack: [ItemID] = [id]
        while let cur = stack.popLast() { s.forEachChild(of: cur) { c in out.append(.modified(c)); if s.isFolder(c) { stack.append(c) } } }
    }

    /// Reconciles a subtree with disk (used for MustScanSubDirs and explicit rescans).
    public func rescan(path: String) -> [IndexChange] {
        statistics.rescans += 1
        guard let id = index.read({ index.lookup(path: path) }) else {
            if let e = DirectoryLister.entry(atPath: path) { return create(path: path, entry: e) }
            return []
        }
        guard index.store.isFolder(id) else {
            if let e = DirectoryLister.entry(atPath: path) { return update(id: id, path: path, entry: e) }
            return remove(id: id, path: path)
        }
        let scanner = VolumeScanner(index: index, rules: rules, allowedDevices: allowedDevices[index.store.root(of: id)] ?? [], maxConcurrency: 4)
        var out: [IndexChange] = []
        var stack: [(String, ItemID)] = [(path, id)]
        while let (p, folder) = stack.popLast() {
            let r = scanner.reconcile(folderPath: p, item: folder)
            for c in r.created {
                out.append(.created(c))
                let s = index.store
                journal.append(s.isFolder(c) ? .folderCreate : .fileCreate, name: s.name(c), path: p, size: s.fileSize(c))
                if s.isFolder(c) { stack.append((Paths.join(p, s.name(c)), c)) }
            }
            for u in r.updated { out.append(.modified(u)) }
            for (rid, rp) in r.removed { out.append(.removed(rid, path: rp)); journal.append(.fileDelete, name: Paths.lastComponent(rp), path: Paths.parent(rp)) }
            index.read { index.store.forEachChild(of: folder) { c in if index.store.isFolder(c) && !r.created.contains(c) { stack.append((Paths.join(p, index.store.name(c)), c)) } } }
            if stack.count > 100_000 { break }
        }
        return out
    }
}

/// Fast and full rescans of roots.
public enum Rescan {
    /// Fast rescan: only folders whose modification date differs from the index are reconciled.
    public static func fast(root: Root, index: Index, rules: ExcludeRules, allowedDevices: Set<Int32>, journal: IndexJournal?) -> [IndexChange] {
        let scanner = VolumeScanner(index: index, rules: rules, allowedDevices: allowedDevices, maxConcurrency: 4)
        var out: [IndexChange] = []
        let s = index.store
        // (path, folder, indexed mtime, indexed ctime) captured before any reconcile touches the folder
        var stack: [(String, ItemID, Int64, Int64)] = [(root.path, root.item, -1, -1)]
        while let (p, folder, indexedM, indexedC) = stack.popLast() {
            guard let e = DirectoryLister.entry(atPath: p) else {
                if folder != root.item { out.append(.removed(folder, path: p)); index.write { s.remove(folder) } }
                continue
            }
            let dirty = e.dateModified != indexedM || e.dateChanged != indexedC || folder == root.item
            index.read { s.forEachChild(of: folder) { c in if s.isFolder(c) { stack.append((Paths.join(p, s.name(c)), c, s.dateModified(c), s.dateChanged(c))) } } }
            if dirty {
                let r = scanner.reconcile(folderPath: p, item: folder)
                index.write { s.update(folder, dateModified: e.dateModified, dateChanged: e.dateChanged) }
                for c in r.created { out.append(.created(c)); journal?.append(s.isFolder(c) ? .folderCreate : .fileCreate, name: s.name(c), path: p, size: s.fileSize(c)) }
                for u in r.updated { out.append(.modified(u)) }
                for (rid, rp) in r.removed { out.append(.removed(rid, path: rp)); journal?.append(.fileDelete, name: Paths.lastComponent(rp), path: Paths.parent(rp)) }
                for c in r.created where s.isFolder(c) { stack.append((Paths.join(p, s.name(c)), c, -1, -1)) }
                stack.removeAll { entry in r.removed.contains { $0.0 == entry.1 } }
            }
        }
        return out
    }

    /// Full rescan: drop and rebuild everything under the root.
    @discardableResult
    public static func full(root: Root, index: Index, rules: ExcludeRules, allowedDevices: Set<Int32>, progress: ((Int) -> Void)? = nil, cancel: @escaping () -> Bool = { false }) -> ScanStats {
        let scanner = VolumeScanner(index: index, rules: rules, allowedDevices: allowedDevices)
        let stats = scanner.scan(rootPath: root.path, rootItem: root.item, progress: progress, cancel: cancel)
        index.write {
            var r = root
            r.scanDate = Timestamps.now()
            r.lastEventID = ChangeMonitor.currentEventID
            index.updateRoot(r)
        }
        return stats
    }
}
