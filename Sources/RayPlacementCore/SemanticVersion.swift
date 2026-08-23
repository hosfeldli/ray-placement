import Foundation

public struct SemanticVersion: Comparable, Equatable, Sendable {
    public let components: [Int]

    public init?(_ rawValue: String) {
        let clean = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = clean.lowercased().hasPrefix("v") ? String(clean.dropFirst()) : clean
        let numeric = withoutPrefix.split(separator: "-", maxSplits: 1).first.map(String.init) ?? withoutPrefix
        let parts = numeric.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var parsed: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            parsed.append(value)
        }
        components = parsed
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
