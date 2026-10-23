import Foundation

/// Pinyin transliteration of Chinese characters via CoreFoundation transforms.
public enum Pinyin {
    private static let cache = NSCache<NSString, NSString>()

    public static func containsChinese(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    /// Full pinyin ("QuanPin") without tone marks, e.g. "中文" → "zhongwen". Non-Chinese characters pass through lowercased.
    public static func quan(_ s: String) -> String {
        if let c = cache.object(forKey: ("q" + s) as NSString) { return c as String }
        let m = NSMutableString(string: s)
        CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
        let out = (m as String).replacingOccurrences(of: " ", with: "").lowercased()
        cache.setObject(out as NSString, forKey: ("q" + s) as NSString)
        return out
    }

    /// Initial letters ("JianPin"), e.g. "中文" → "zw". Non-Chinese runs pass through unchanged.
    public static func jian(_ s: String) -> String {
        if let c = cache.object(forKey: ("j" + s) as NSString) { return c as String }
        var out = ""
        for scalar in s.unicodeScalars {
            let ch = String(scalar)
            if containsChinese(ch) {
                let q = quan(ch)
                if let f = q.first { out.append(f) }
            } else {
                out.append(ch.lowercased())
            }
        }
        cache.setObject(out as NSString, forKey: ("j" + s) as NSString)
        return out
    }
}
