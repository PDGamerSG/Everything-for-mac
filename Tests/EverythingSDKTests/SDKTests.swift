import Foundation
import Testing
import EverythingCore
import EverythingIPC
@testable import EverythingSDK

private final class SDKService: IPCService {
    func handle(_ request: IPCRequest, completion: @escaping (IPCResponse) -> Void) {
        if request.kind == .query {
            let item = IPCItem(type: "file", name: "hello.txt", path: "/Docs", fullPath: "/Docs/hello.txt", itemID: 1)
            var result = IPCQueryResult(totalFiles: 1, totalFolders: 0, totalResults: 1, items: [item], generation: 2, seconds: 0, errors: [])
            result.items[0].size = 42
            var response = IPCResponse(); response.query = result; completion(response)
        } else { completion(.value(true)) }
    }
}

@Suite(.serialized) struct SDKTests {
    @Test func queryAndResultAccessors() throws {
        let support = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("everything-sdk-\(UUID().uuidString)")
        setenv("EVERYTHING_APP_SUPPORT", support.path, 1)
        let socket = SocketPath.path()
        let server = IPCServer(path: socket, service: SDKService())
        try server.start(); defer { server.stop(); unsetenv("EVERYTHING_APP_SUPPORT") }

        #expect(Everything_SetSearchUTF8("hello") == 1)
        #expect(Everything_SetRequestFlags(EVERYTHING_REQUEST_FILE_NAME | EVERYTHING_REQUEST_FULL_PATH_AND_FILE_NAME | EVERYTHING_REQUEST_SIZE) == 1)
        #expect(Everything_SetMax(1) == 1)
        #expect(Everything_Query(1) == 1)
        #expect(Everything_GetNumResults() == 1)

        var path = [CChar](repeating: 0, count: 128)
        #expect(Everything_GetResultFullPathNameUTF8(0, &path, UInt32(path.count)) == UInt32("/Docs/hello.txt".utf8.count))
        #expect(String(cString: path) == "/Docs/hello.txt")
        #expect(Everything_GetResultSize(0) == 42)
    }

    @Test func reportsNotRunningError() {
        setenv("EVERYTHING_APP_SUPPORT", "/tmp/everything-sdk-missing-\(UUID().uuidString)", 1)
        defer { unsetenv("EVERYTHING_APP_SUPPORT") }
        Everything_Reset()
        #expect(Everything_Query(0) == 0)
        #expect(Everything_GetLastError() != 0)
    }
}
