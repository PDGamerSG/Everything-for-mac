import Foundation
import EverythingCore

/// Location of the Unix domain socket for an instance (sun_path is limited to 104 bytes on macOS).
public enum SocketPath {
    public static func path(instance: String = AppPaths.instanceName) -> String {
        path(supportDirectory: AppPaths.supportDirectory, instance: instance)
    }

    public static func path(supportDirectory: URL, instance: String = AppPaths.instanceName) -> String {
        let name = instance.isEmpty ? "everything.sock" : "everything-\(instance).sock"
        let preferred = supportDirectory.appendingPathComponent(name).path
        if preferred.utf8.count < 100 { return preferred }
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
        if tmp.utf8.count < 100 { return tmp }
        return "/tmp/everything-\(getuid())" + (instance.isEmpty ? "" : "-\(instance)") + ".sock"
    }
}

/// Minimal blocking frame I/O over a file descriptor.
enum FrameIO {
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            while offset < data.count {
                let n = write(fd, base + offset, data.count - offset)
                if n < 0 { if errno == EINTR { continue }; return false }
                if n == 0 { return false }
                offset += n
            }
            return true
        }
    }

    static func readExactly(_ fd: Int32, _ count: Int, timeoutMs: Int32 = -1) -> Data? {
        var out = Data(count: count)
        var offset = 0
        while offset < count {
            if timeoutMs >= 0 {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let r = poll(&p, 1, timeoutMs)
                if r <= 0 { return nil }
            }
            let n = out.withUnsafeMutableBytes { raw -> Int in
                read(fd, raw.baseAddress! + offset, count - offset)
            }
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { return nil }
            offset += n
        }
        return out
    }

    static func readFrame(_ fd: Int32, timeoutMs: Int32 = -1, maxBytes: Int = 1 << 30) -> Data? {
        guard let header = readExactly(fd, 4, timeoutMs: timeoutMs) else { return nil }
        let len = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard len <= maxBytes else { return nil }
        if len == 0 { return Data() }
        return readExactly(fd, len, timeoutMs: timeoutMs)
    }

    static func writeFrame(_ fd: Int32, _ payload: Data) -> Bool { writeAll(fd, IPCCodec.frame(payload)) }
}
