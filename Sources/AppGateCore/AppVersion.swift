import Foundation

/// A dotted-numeric app version (`2`, `2.1`, `2.10.0`), compared numerically
/// per component. `2.10.0` is newer than `2.9.0`, which a plain string compare
/// gets backwards. One side is the running build's marketing version. The
/// other is a remote threshold, either a configured floor or the App Store's
/// current version.
///
/// Parsing is strict. Every dot-separated component must be ASCII digits, and
/// there must be at least one. Anything else, such as `"2.x"`, `""`,
/// `"1.2.3-beta"`, `"2."`, `"2..0"` or `"+1"`, yields `nil`. Every caller
/// reads `nil` as "cannot compare", which means no gate.
public struct AppVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ string: String) {
        // Keep empty components, so a leading, trailing or doubled dot fails
        // to parse.
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        var parsed: [Int] = []
        parsed.reserveCapacity(parts.count)
        for part in parts {
            // `Int(_:)` alone is not enough. `Int("+1")` is 1 and `Int("-0")` is
            // 0, so without the digit guard `"1.+2"` would parse.
            guard part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part) else {
                return nil
            }
            parsed.append(value)
        }
        guard !parsed.isEmpty else { return nil }
        components = parsed
    }

    /// The dotted form, which a dismissal persists and a diagnostics screen
    /// prints.
    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool { compare(lhs, rhs) < 0 }

    /// Custom equality, so it stays consistent with `<`. Trailing zeros do not
    /// matter, so `2.1` equals `2.1.0`. Synthesized equality would make the
    /// two neither `<` nor `==`, which breaks `Comparable`'s total order.
    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { compare(lhs, rhs) == 0 }

    /// Returns -1, 0 or +1. Compares per component and pads the shorter side
    /// with zeros.
    private static func compare(_ lhs: AppVersion, _ rhs: AppVersion) -> Int {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }
}
