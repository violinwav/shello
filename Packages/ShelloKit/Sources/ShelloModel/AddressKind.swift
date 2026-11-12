/// The forms a host's address can take (README section 3).
///
/// Shello connects by name through the system resolver, so a hostname is only checked for its
/// syntax here, never looked up.
public enum AddressKind: Hashable, Sendable {
    case hostname
    case ipv4
    case ipv6

    /// The form `address` has, or nil if it has none of them. The address is checked as it is:
    /// without surrounding whitespace, a user, a port, or brackets around an IPv6 address.
    public init?(of address: String) {
        let address = Substring(address)
        if address.contains(":") {
            guard Self.isIPv6(address) else { return nil }
            self = .ipv6
        } else if address.utf8.allSatisfy({ $0 == .dot || $0.isDigit }) {
            // Digits and dots are always read as an IPv4 address, so that shorthands such as `10.1`
            // are refused rather than resolved as something the user did not mean.
            guard Self.isIPv4(address) else { return nil }
            self = .ipv4
        } else {
            guard Self.isHostname(address) else { return nil }
            self = .hostname
        }
    }

    /// Letters, digits and hyphens in labels of up to 63 characters, 253 characters in all
    /// (RFC 1123), plus the underscores that internal names use. A trailing dot names the root.
    private static func isHostname(_ address: Substring) -> Bool {
        let name = address.last == "." ? address.dropLast() : address
        guard !name.isEmpty, name.utf8.count <= 253 else { return false }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            (1...63).contains(label.utf8.count)
                && label.utf8.first != .hyphen && label.utf8.last != .hyphen
                && label.utf8.allSatisfy { $0.isLetterOrDigit || $0 == .hyphen || $0 == .underscore }
        }
    }

    /// Four decimal numbers from 0 to 255, without leading zeros, which some resolvers read as octal.
    private static func isIPv4(_ address: Substring) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4
            && parts.allSatisfy { part in
                (1...3).contains(part.utf8.count) && part.utf8.allSatisfy(\.isDigit)
                    && (part.utf8.count == 1 || part.utf8.first != .zero)
                    && Int(part).map { $0 <= 255 } ?? false
            }
    }

    /// The text forms of RFC 4291: eight groups of up to four hex digits, or fewer around one `::`;
    /// the last two groups may be written as an IPv4 address. A zone such as `%en0` may follow.
    private static func isIPv6(_ address: Substring) -> Bool {
        var address = address
        if let percent = address.firstIndex(of: "%") {
            let zone = address[address.index(after: percent)...]
            guard !zone.isEmpty,
                zone.utf8.allSatisfy({ $0.isLetterOrDigit || $0 == .dot || $0 == .hyphen || $0 == .underscore })
            else { return false }
            address = address[..<percent]
        }
        let halves = address.split(separator: "::", omittingEmptySubsequences: false)
        switch halves.count {
        case 1:
            return groupCount(halves[0], ipv4Allowed: true) == 8
        case 2:
            guard let head = groupCount(halves[0], ipv4Allowed: false),
                let tail = groupCount(halves[1], ipv4Allowed: true)
            else { return false }
            return head + tail <= 7
        default:
            return false
        }
    }

    /// How many 16-bit groups the colon-separated `groups` stand for, or nil if one is malformed.
    /// An IPv4 address, allowed only as the last group, stands for two.
    private static func groupCount(_ groups: Substring, ipv4Allowed: Bool) -> Int? {
        guard !groups.isEmpty else { return 0 }
        let parts = groups.split(separator: ":", omittingEmptySubsequences: false)
        let hexGroups = ipv4Allowed && parts.last?.contains(".") == true ? parts.dropLast() : parts[...]
        guard
            hexGroups.allSatisfy({ (1...4).contains($0.utf8.count) && $0.utf8.allSatisfy(\.isHexDigit) })
        else { return nil }
        guard hexGroups.count < parts.count else { return parts.count }
        return parts.last.map(isIPv4) == true ? parts.count + 1 : nil
    }
}

extension UInt8 {
    fileprivate static let dot = UInt8(ascii: ".")
    fileprivate static let hyphen = UInt8(ascii: "-")
    fileprivate static let underscore = UInt8(ascii: "_")
    fileprivate static let zero = UInt8(ascii: "0")

    fileprivate var isDigit: Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(self) }

    fileprivate var isLetterOrDigit: Bool {
        isDigit || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(self | 0x20)
    }

    fileprivate var isHexDigit: Bool {
        isDigit || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(self | 0x20)
    }
}
