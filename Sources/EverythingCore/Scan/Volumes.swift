import Foundation
import Darwin

/// A mounted volume as seen by the indexer.
public struct VolumeInfo: Equatable, Sendable {
    public var name: String
    public var mountPoint: String
    public var uuid: String
    public var fileSystem: String
    public var deviceID: Int32
    public var isRoot: Bool
    public var isRemovable: Bool
    public var isNetwork: Bool
    public var isBrowsable: Bool
    public var isReadOnly: Bool
    public var capacity: Int64
    public var available: Int64
    /// Additional device IDs that belong to the same logical volume (the APFS system/data volume group).
    public var companionDeviceIDs: [Int32]

    public init(name: String, mountPoint: String, uuid: String = "", fileSystem: String = "", deviceID: Int32 = 0,
                isRoot: Bool = false, isRemovable: Bool = false, isNetwork: Bool = false, isBrowsable: Bool = true,
                isReadOnly: Bool = false, capacity: Int64 = 0, available: Int64 = 0, companionDeviceIDs: [Int32] = []) {
        self.name = name; self.mountPoint = mountPoint; self.uuid = uuid; self.fileSystem = fileSystem
        self.deviceID = deviceID; self.isRoot = isRoot; self.isRemovable = isRemovable; self.isNetwork = isNetwork
        self.isBrowsable = isBrowsable; self.isReadOnly = isReadOnly; self.capacity = capacity; self.available = available
        self.companionDeviceIDs = companionDeviceIDs
    }

    public var allDeviceIDs: Set<Int32> { Set([deviceID] + companionDeviceIDs) }
}

public enum Volumes {
    /// Mount points that are never indexed as separate volumes (system-internal APFS volumes).
    public static let systemInternalMountPrefixes = ["/System/Volumes/VM", "/System/Volumes/Preboot", "/System/Volumes/Update",
                                                     "/System/Volumes/xarts", "/System/Volumes/iSCPreboot", "/System/Volumes/Hardware",
                                                     "/System/Volumes/Data", "/private/tmp/", "/dev"]

    public static func deviceID(of path: String) -> Int32? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return st.st_dev
    }

    public static func fileSystemType(of path: String) -> String {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return "" }
        return withUnsafePointer(to: &fs.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) } }
    }

    /// Enumerates mounted, user-visible volumes. The root volume includes the APFS Data volume device
    /// as a companion so firmlinked folders (`/Users`, `/Applications`…) are indexed under `/`.
    public static func mounted(includeNetwork: Bool = true) -> [VolumeInfo] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeUUIDStringKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey,
                                         .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey, .volumeIsReadOnlyKey,
                                         .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsInternalKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) else { return [] }
        var out: [VolumeInfo] = []
        let dataDev = deviceID(of: "/System/Volumes/Data")
        for url in urls {
            let path = url.path
            if systemInternalMountPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
            // "/Volumes/Macintosh HD" is a symlink to "/"; skip symlinked mount points.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path), attrs[.type] as? FileAttributeType == .typeSymbolicLink { continue }
            guard let v = try? url.resourceValues(forKeys: keys) else { continue }
            let isRoot = v.volumeIsRootFileSystem ?? (path == "/")
            let isNetwork = !(v.volumeIsLocal ?? true)
            if isNetwork && !includeNetwork { continue }
            guard v.volumeIsBrowsable ?? true else { continue }
            let dev = deviceID(of: path) ?? 0
            var companions: [Int32] = []
            if isRoot, let dd = dataDev, dd != dev { companions.append(dd) }
            out.append(VolumeInfo(name: v.volumeName ?? Paths.lastComponent(path), mountPoint: path, uuid: v.volumeUUIDString ?? "",
                                  fileSystem: fileSystemType(of: path), deviceID: dev, isRoot: isRoot,
                                  isRemovable: (v.volumeIsRemovable ?? false) || (v.volumeIsEjectable ?? false),
                                  isNetwork: isNetwork, isBrowsable: v.volumeIsBrowsable ?? true, isReadOnly: v.volumeIsReadOnly ?? false,
                                  capacity: Int64(v.volumeTotalCapacity ?? 0), available: Int64(v.volumeAvailableCapacity ?? 0),
                                  companionDeviceIDs: companions))
        }
        return out.sorted { $0.isRoot && !$1.isRoot || (!$1.isRoot && $0.mountPoint < $1.mountPoint) }
    }

    /// Applies Options → Volumes include/exclude settings.
    public static func selected(from all: [VolumeInfo], settings: Settings) -> [VolumeInfo] {
        let explicit = Set(settings.list("volumes"))
        let excluded = Set(settings.list("excluded_volumes"))
        let autoFixed = settings.bool("auto_include_fixed_volumes")
        let autoRemovable = settings.bool("auto_include_removable_volumes")
        let autoNetwork = settings.bool("auto_include_network_volumes")
        return all.filter { v in
            if excluded.contains(v.mountPoint) || excluded.contains(v.uuid) { return false }
            if explicit.contains(v.mountPoint) || explicit.contains(v.uuid) { return true }
            if v.isNetwork { return autoNetwork }
            if v.isRemovable { return autoRemovable }
            return autoFixed
        }
    }
}
