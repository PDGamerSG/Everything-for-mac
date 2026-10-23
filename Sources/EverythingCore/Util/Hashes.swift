import Foundation
import CommonCrypto
import zlib

public enum HashAlgorithm: String, CaseIterable, Sendable { case crc32, crc64, md5, sha1, sha256, sha512 }

public enum Hashes {
    /// Streaming hash of a file; returns lowercase hex. `limit` caps bytes read (0 = whole file).
    public static func hex(_ algo: HashAlgorithm, path: String, limit: Int = 0) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var remaining = limit > 0 ? limit : Int.max
        switch algo {
        case .crc32:
            var crc: uLong = crc32(0, nil, 0)
            while remaining > 0, let d = try? fh.read(upToCount: min(1 << 20, remaining)), !d.isEmpty {
                d.withUnsafeBytes { crc = crc32(crc, $0.bindMemory(to: UInt8.self).baseAddress, uInt(d.count)) }
                remaining -= d.count
            }
            return String(format: "%08x", UInt32(crc))
        case .crc64:
            var crc: UInt64 = 0
            while remaining > 0, let d = try? fh.read(upToCount: min(1 << 20, remaining)), !d.isEmpty {
                crc = crc64Update(crc, d)
                remaining -= d.count
            }
            return String(format: "%016llx", crc)
        case .md5:
            var c = CC_MD5_CTX(); CC_MD5_Init(&c)
            while remaining > 0, let d = try? fh.read(upToCount: min(1 << 20, remaining)), !d.isEmpty { d.withUnsafeBytes { _ = CC_MD5_Update(&c, $0.baseAddress, CC_LONG(d.count)) }; remaining -= d.count }
            var out = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH)); CC_MD5_Final(&out, &c)
            return out.map { String(format: "%02x", $0) }.joined()
        case .sha1:
            var c = CC_SHA1_CTX(); CC_SHA1_Init(&c)
            while remaining > 0, let d = try? fh.read(upToCount: min(1 << 20, remaining)), !d.isEmpty { d.withUnsafeBytes { _ = CC_SHA1_Update(&c, $0.baseAddress, CC_LONG(d.count)) }; remaining -= d.count }
            var out = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH)); CC_SHA1_Final(&out, &c)
            return out.map { String(format: "%02x", $0) }.joined()
        case .sha256:
            var c = CC_SHA256_CTX(); CC_SHA256_Init(&c)
            while remaining > 0, let d = try? fh.read(upToCount: min(1 << 20, remaining)), !d.isEmpty { d.withUnsafeBytes { _ = CC_SHA256_Update(&c, $0.baseAddress, CC_LONG(d.count)) }; remaining -= d.count }
            var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH)); CC_SHA256_Final(&out, &c)
            return out.map { String(format: "%02x", $0) }.joined()
        case .sha512:
            var c = CC_SHA512_CTX(); CC_SHA512_Init(&c)
            while remaining > 0, let d = try? fh.read(upToCount: min(1 << 20, remaining)), !d.isEmpty { d.withUnsafeBytes { _ = CC_SHA512_Update(&c, $0.baseAddress, CC_LONG(d.count)) }; remaining -= d.count }
            var out = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH)); CC_SHA512_Final(&out, &c)
            return out.map { String(format: "%02x", $0) }.joined()
        }
    }

    public static func hex(_ algo: HashAlgorithm, data: Data) -> String {
        switch algo {
        case .crc32:
            let c = data.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(data.count)) }
            return String(format: "%08x", UInt32(c))
        case .crc64: return String(format: "%016llx", crc64Update(0, data))
        case .md5:
            var out = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
            data.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(data.count), &out) }
            return out.map { String(format: "%02x", $0) }.joined()
        case .sha1:
            var out = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            data.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &out) }
            return out.map { String(format: "%02x", $0) }.joined()
        case .sha256:
            var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &out) }
            return out.map { String(format: "%02x", $0) }.joined()
        case .sha512:
            var out = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
            data.withUnsafeBytes { _ = CC_SHA512($0.baseAddress, CC_LONG(data.count), &out) }
            return out.map { String(format: "%02x", $0) }.joined()
        }
    }

    // CRC-64/XZ (ECMA-182 polynomial, reflected), as used by 7-Zip and Everything.
    private static let crc64Table: [UInt64] = {
        var t = [UInt64](repeating: 0, count: 256)
        let poly: UInt64 = 0xC96C5795D7870F42
        for i in 0..<256 {
            var c = UInt64(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ poly : c >> 1 }
            t[i] = c
        }
        return t
    }()

    static func crc64Update(_ crc: UInt64, _ data: Data) -> UInt64 {
        var c = ~crc
        for b in data { c = crc64Table[Int((c ^ UInt64(b)) & 0xFF)] ^ (c >> 8) }
        return ~c
    }

    /// HMAC-SHA256 for network index authentication.
    public static func hmacSHA256(key: Data, message: Data) -> Data {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { k in
            message.withUnsafeBytes { m in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), k.baseAddress, key.count, m.baseAddress, message.count, &out)
            }
        }
        return Data(out)
    }
}
