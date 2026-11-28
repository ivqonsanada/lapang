import Foundation

/// Names a script makes once per run: one prefix and a random ending, the way
/// mktemp and Node's fs.mkdtemp name things (checkout.kbMU, e2e-run-381UXa).
/// Many siblings that share a prefix and differ only in that ending are what a
/// script leaves behind when it never removes its copies.
public enum Families {
    /// A name split before its random-looking ending.
    public struct Parts: Sendable, Equatable {
        /// Everything before the ending, the separator kept: "checkout.".
        public let key: String
        /// The ending: "kbMU".
        public let tail: String
        /// True when the ending holds a digit or an uppercase letter, as most
        /// random endings do and words such as "final" or "draft" do not.
        public let looksRandom: Bool
    }

    /// The name's last run of 4 to 12 letters and digits, after a `.`, `-`
    /// or `_`, with something before the separator. Nil otherwise
    /// ("vendor", "claude-501", "notes").
    public static func split(_ name: String) -> Parts? {
        let scalars = Array(name.unicodeScalars)
        var start = scalars.count
        while start > 0, isAlphanumeric(scalars[start - 1]) { start -= 1 }
        let length = scalars.count - start
        guard (4...12).contains(length), start >= 2, separators.contains(scalars[start - 1]) else { return nil }
        let key = String(String.UnicodeScalarView(scalars[..<start]))
        guard key.unicodeScalars.contains(where: isLetter) else { return nil }
        let tail = scalars[start...]
        let looksRandom = tail.contains { ("0"..."9").contains($0) || ("A"..."Z").contains($0) }
        return Parts(key: key, tail: String(String.UnicodeScalarView(tail)), looksRandom: looksRandom)
    }

    /// Groups names into families: three or more names with the same key and
    /// endings of the same length, most of which look random. Names that look
    /// like an app's own (reverse DNS, com.apple.…) are left out.
    /// Returns each family's key and its names, sorted.
    public static func group(_ names: [String], minimum: Int = 3) -> [String: [String]] {
        struct Bucket { var names: [String] = []; var random = 0 }
        var buckets: [String: [Int: Bucket]] = [:]
        for name in names where !looksLikeAnAppsOwn(name) {
            guard let parts = split(name) else { continue }
            var bucket = buckets[parts.key, default: [:]][parts.tail.count, default: Bucket()]
            bucket.names.append(name)
            if parts.looksRandom { bucket.random += 1 }
            buckets[parts.key, default: [:]][parts.tail.count] = bucket
        }
        var families: [String: [String]] = [:]
        for (key, byLength) in buckets {
            let members = byLength.values
                .filter { $0.names.count >= minimum && $0.random * 2 > $0.names.count }
                .flatMap(\.names)
            if !members.isEmpty { families[key] = members.sorted() }
        }
        return families
    }

    /// How a family is shown: "checkout.*".
    public static func display(_ key: String) -> String { key + "*" }

    /// com.apple.…, org.mozilla.…: a temp folder an app names after itself
    /// and looks after.
    static func looksLikeAnAppsOwn(_ name: String) -> Bool {
        let parts = name.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, (2...6).contains(parts[0].count), !parts[1].isEmpty else { return false }
        return parts[0].unicodeScalars.allSatisfy { ("a"..."z").contains($0) }
    }

    private static let separators: Set<Unicode.Scalar> = [".", "-", "_"]

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        isLetter(scalar) || ("0"..."9").contains(scalar)
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }
}
