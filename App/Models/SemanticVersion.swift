/* SemVer 2 precedence without integer overflow. GPL-3.0-or-later. */
import Foundation

struct SemanticVersion: Sendable {
    let rawValue: String
    let components: [String]
    let prerelease: [String]

    init?(_ text: String) {
        guard !text.isEmpty, text.utf8.count <= 256 else { return nil }
        let buildParts = text.split(separator: "+", omittingEmptySubsequences: false)
        guard buildParts.count <= 2 else { return nil }
        if buildParts.count == 2, !Self.validIdentifiers(String(buildParts[1]), numericLeadingZeros: true) { return nil }
        let versionParts = buildParts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = versionParts[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard core.count == 3, core.allSatisfy(Self.validNumber) else { return nil }
        var identifiers: [String] = []
        if versionParts.count == 2 {
            guard Self.validIdentifiers(String(versionParts[1]), numericLeadingZeros: false) else { return nil }
            identifiers = versionParts[1].split(separator: ".").map(String.init)
        }
        rawValue = text; components = core; prerelease = identifiers
    }

    func compare(to other: Self) -> ComparisonResult {
        for (left, right) in zip(components, other.components) {
            let result = Self.compareNumbers(left, right)
            if result != .orderedSame { return result }
        }
        if prerelease.isEmpty != other.prerelease.isEmpty { return prerelease.isEmpty ? .orderedDescending : .orderedAscending }
        for (left, right) in zip(prerelease, other.prerelease) where left != right {
            let leftNumeric = Self.digits(left), rightNumeric = Self.digits(right)
            if leftNumeric && rightNumeric { return Self.compareNumbers(left, right) }
            if leftNumeric != rightNumeric { return leftNumeric ? .orderedAscending : .orderedDescending }
            return left < right ? .orderedAscending : .orderedDescending
        }
        if prerelease.count == other.prerelease.count { return .orderedSame }
        return prerelease.count < other.prerelease.count ? .orderedAscending : .orderedDescending
    }

    private static func digits(_ text: String) -> Bool { !text.isEmpty && text.utf8.allSatisfy { (48...57).contains($0) } }
    private static func validNumber(_ text: String) -> Bool { digits(text) && (text == "0" || !text.hasPrefix("0")) }
    private static func validIdentifiers(_ text: String, numericLeadingZeros: Bool) -> Bool {
        text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { byte in (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 }
                && (numericLeadingZeros || !digits(String(part)) || validNumber(String(part)))
        }
    }
    private static func compareNumbers(_ left: String, _ right: String) -> ComparisonResult {
        if left.count != right.count { return left.count < right.count ? .orderedAscending : .orderedDescending }
        if left == right { return .orderedSame }
        return left < right ? .orderedAscending : .orderedDescending
    }
}
