import Foundation
import EverythingIPC

public let EVERYTHING_REQUEST_FILE_NAME: UInt32 = 0x00000001
public let EVERYTHING_REQUEST_PATH: UInt32 = 0x00000002
public let EVERYTHING_REQUEST_FULL_PATH_AND_FILE_NAME: UInt32 = 0x00000004
public let EVERYTHING_REQUEST_EXTENSION: UInt32 = 0x00000008
public let EVERYTHING_REQUEST_SIZE: UInt32 = 0x00000010
public let EVERYTHING_REQUEST_DATE_CREATED: UInt32 = 0x00000020
public let EVERYTHING_REQUEST_DATE_MODIFIED: UInt32 = 0x00000040
public let EVERYTHING_REQUEST_DATE_ACCESSED: UInt32 = 0x00000080
public let EVERYTHING_REQUEST_ATTRIBUTES: UInt32 = 0x00000100
public let EVERYTHING_REQUEST_FILE_LIST_FILE_NAME: UInt32 = 0x00000200
public let EVERYTHING_REQUEST_RUN_COUNT: UInt32 = 0x00000400
public let EVERYTHING_REQUEST_DATE_RUN: UInt32 = 0x00000800
public let EVERYTHING_REQUEST_DATE_RECENTLY_CHANGED: UInt32 = 0x00001000
public let EVERYTHING_REQUEST_HIGHLIGHTED_NAME: UInt32 = 0x00002000
public let EVERYTHING_REQUEST_HIGHLIGHTED_PATH: UInt32 = 0x00004000

public enum EverythingSDKSort: UInt32 { case name = 1, path = 2, size = 3, `extension` = 4, dateCreated = 5, dateModified = 6, dateAccessed = 7, runCount = 8, dateRun = 9 }

private final class SDKState: @unchecked Sendable {
    let lock = NSLock()
    var search = ""
    var flags = EVERYTHING_REQUEST_FULL_PATH_AND_FILE_NAME
    var sort: String?
    var ascending = true
    var offset = 0
    var max = 0
    var results: [IPCItem] = []
    var totalFiles = 0
    var totalFolders = 0
    var lastError: UInt32 = 0
}
private let sdk = SDKState()

private func setError(_ error: UInt32) { sdk.lock.lock(); sdk.lastError = error; sdk.lock.unlock() }
private func getString(_ pointer: UnsafePointer<CChar>?) -> String? { guard let pointer else { return nil }; return String(cString: pointer) }
private func getWideString(_ pointer: UnsafePointer<UInt16>?) -> String? {
    guard let pointer else { return nil }
    var values: [UInt16] = []; var i = 0
    while pointer[i] != 0 { values.append(pointer[i]); i += 1 }
    return String(decoding: values, as: UTF16.self)
}
private func requestedColumns(_ flags: UInt32) -> [String] {
    var columns: [String] = []
    if flags & EVERYTHING_REQUEST_FILE_NAME != 0 { columns.append("name") }
    if flags & EVERYTHING_REQUEST_PATH != 0 { columns.append("path") }
    if flags & EVERYTHING_REQUEST_FULL_PATH_AND_FILE_NAME != 0 { columns.append("fullpath") }
    if flags & EVERYTHING_REQUEST_EXTENSION != 0 { columns.append("extension") }
    if flags & EVERYTHING_REQUEST_SIZE != 0 { columns.append("size") }
    if flags & EVERYTHING_REQUEST_DATE_CREATED != 0 { columns.append("datecreated") }
    if flags & EVERYTHING_REQUEST_DATE_MODIFIED != 0 { columns.append("datemodified") }
    if flags & EVERYTHING_REQUEST_DATE_ACCESSED != 0 { columns.append("dateaccessed") }
    if flags & EVERYTHING_REQUEST_ATTRIBUTES != 0 { columns.append("attributes") }
    if flags & EVERYTHING_REQUEST_FILE_LIST_FILE_NAME != 0 { columns.append("filelistfilename") }
    if flags & EVERYTHING_REQUEST_RUN_COUNT != 0 { columns.append("runcount") }
    if flags & EVERYTHING_REQUEST_DATE_RUN != 0 { columns.append("daterun") }
    if flags & EVERYTHING_REQUEST_DATE_RECENTLY_CHANGED != 0 { columns.append("daterecentlychanged") }
    return columns.isEmpty ? ["fullpath"] : columns
}
private func withState<T>(_ body: (SDKState) -> T) -> T { sdk.lock.lock(); defer { sdk.lock.unlock() }; return body(sdk) }

public func Everything_SetSearchUTF8(_ search: String) -> Int32 { withState { $0.search = search; $0.lastError = 0; return 1 } }
@_cdecl("Everything_SetSearchA") public func Everything_SetSearchA(_ search: UnsafePointer<CChar>?) -> Int32 { Everything_SetSearchUTF8(getString(search) ?? "") }
@_cdecl("Everything_SetSearchW") public func Everything_SetSearchW(_ search: UnsafePointer<UInt16>?) -> Int32 { Everything_SetSearchUTF8(getWideString(search) ?? "") }

@_cdecl("Everything_SetRequestFlags") public func Everything_SetRequestFlags(_ flags: UInt32) -> Int32 { withState { $0.flags = flags; return 1 } }
@_cdecl("Everything_SetMax") public func Everything_SetMax(_ max: UInt32) -> Int32 { withState { $0.max = Int(max); return 1 } }
@_cdecl("Everything_SetOffset") public func Everything_SetOffset(_ offset: UInt32) -> Int32 { withState { $0.offset = Int(offset); return 1 } }
@_cdecl("Everything_SetSort") public func Everything_SetSort(_ sort: UInt32) -> Int32 {
    guard let key = EverythingSDKSort(rawValue: sort) else { setError(2); return 0 }
    return withState { $0.sort = String(describing: key).lowercased(); return 1 }
}
@_cdecl("Everything_SetSortDescending") public func Everything_SetSortDescending() -> Int32 { withState { $0.ascending = false; return 1 } }
@_cdecl("Everything_SetSortAscending") public func Everything_SetSortAscending() -> Int32 { withState { $0.ascending = true; return 1 } }

@_cdecl("Everything_Query") public func Everything_Query(_ wait: Int32) -> Int32 {
    let (search, flags, sort, ascending, max) = withState { ($0.search, $0.flags, $0.sort, $0.ascending, $0.max) }
    let offset = withState { $0.offset }
    var params = IPCQueryParams(search: search); params.columns = requestedColumns(flags); params.sort = sort; params.ascending = ascending; params.offset = offset; params.count = max
    do {
        let result = try IPCClient().query(params)
        withState { $0.results = result.items; $0.totalFiles = result.totalFiles; $0.totalFolders = result.totalFolders; $0.lastError = 0 }
        return 1
    } catch {
        withState { $0.results = []; $0.totalFiles = 0; $0.totalFolders = 0; $0.lastError = 1 }
        return 0
    }
}
@_cdecl("Everything_IsDBLoaded") public func Everything_IsDBLoaded() -> Int32 {
    guard let response = try? IPCClient().send(IPCRequest(kind: .isDBLoaded)), response.ok, response.bool == true else { return 0 }
    return 1
}
@_cdecl("Everything_Reset") public func Everything_Reset() { withState { $0.search = ""; $0.results = []; $0.lastError = 0; $0.max = 0; $0.offset = 0; $0.sort = nil; $0.ascending = true } }
@_cdecl("Everything_GetLastError") public func Everything_GetLastError() -> UInt32 { withState { $0.lastError } }
@_cdecl("Everything_GetNumResults") public func Everything_GetNumResults() -> UInt32 { withState { UInt32($0.results.count) } }
@_cdecl("Everything_GetNumFileResults") public func Everything_GetNumFileResults() -> UInt32 { withState { UInt32($0.totalFiles) } }
@_cdecl("Everything_GetNumFolderResults") public func Everything_GetNumFolderResults() -> UInt32 { withState { UInt32($0.totalFolders) } }

private func item(_ index: UInt32) -> IPCItem? { withState { index < $0.results.count ? $0.results[Int(index)] : nil } }
private func copyUTF8(_ value: String, into buffer: UnsafeMutablePointer<CChar>?, length: UInt32) -> UInt32 {
    let bytes = Array(value.utf8); let required = UInt32(bytes.count)
    guard let buffer, length > 0 else { return required }
    let copyCount = min(bytes.count, Int(length - 1)); for i in 0..<copyCount { buffer[i] = CChar(bitPattern: bytes[i]) }; buffer[copyCount] = 0
    return required
}
private func copyWide(_ value: String, into buffer: UnsafeMutablePointer<UInt16>?, length: UInt32) -> UInt32 {
    let values = Array(value.utf16); let required = UInt32(values.count)
    guard let buffer, length > 0 else { return required }
    let copyCount = min(values.count, Int(length - 1)); for i in 0..<copyCount { buffer[i] = values[i] }; buffer[copyCount] = 0
    return required
}
@_cdecl("Everything_GetResultFullPathNameA") public func Everything_GetResultFullPathNameA(_ index: UInt32, _ buffer: UnsafeMutablePointer<CChar>?, _ length: UInt32) -> UInt32 { copyUTF8(item(index)?.fullPath ?? "", into: buffer, length: length) }
@_cdecl("Everything_GetResultFullPathNameW") public func Everything_GetResultFullPathNameW(_ index: UInt32, _ buffer: UnsafeMutablePointer<UInt16>?, _ length: UInt32) -> UInt32 { copyWide(item(index)?.fullPath ?? "", into: buffer, length: length) }
public func Everything_GetResultFullPathNameUTF8(_ index: UInt32, _ buffer: UnsafeMutablePointer<CChar>?, _ length: UInt32) -> UInt32 { Everything_GetResultFullPathNameA(index, buffer, length) }
@_cdecl("Everything_GetResultFileNameA") public func Everything_GetResultFileNameA(_ index: UInt32, _ buffer: UnsafeMutablePointer<CChar>?, _ length: UInt32) -> UInt32 { copyUTF8(item(index)?.name ?? "", into: buffer, length: length) }
@_cdecl("Everything_GetResultFileNameW") public func Everything_GetResultFileNameW(_ index: UInt32, _ buffer: UnsafeMutablePointer<UInt16>?, _ length: UInt32) -> UInt32 { copyWide(item(index)?.name ?? "", into: buffer, length: length) }
@_cdecl("Everything_GetResultSize") public func Everything_GetResultSize(_ index: UInt32) -> UInt64 { item(index)?.size ?? 0 }
@_cdecl("Everything_GetResultDateModified") public func Everything_GetResultDateModified(_ index: UInt32) -> Int64 { item(index)?.dateModified ?? 0 }
@_cdecl("Everything_GetResultDateCreated") public func Everything_GetResultDateCreated(_ index: UInt32) -> Int64 { item(index)?.dateCreated ?? 0 }
@_cdecl("Everything_GetResultDateAccessed") public func Everything_GetResultDateAccessed(_ index: UInt32) -> Int64 { item(index)?.dateAccessed ?? 0 }
@_cdecl("Everything_GetResultAttributes") public func Everything_GetResultAttributes(_ index: UInt32) -> UInt32 { item(index)?.attributesValue ?? 0 }
