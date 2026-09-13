import Foundation

public enum Version {
    /// "v1.2.0" → "1.2.0"
    public static func normalize(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// Dotted-integer comparison, so "1.10.0" is newer than "1.9.0" and "1.0" equals "1.0.0".
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = normalize(a).split(separator: ".").map { Int($0) ?? 0 }
        let y = normalize(b).split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
