extension Server {
    /// Whether the server is probably on the local network, so that connecting to it needs iOS's
    /// Local Network access, which iOS asks the user for on the first such connection (README section
    /// 3, TN3179). Shello explains that question just before it appears.
    ///
    /// iOS counts an address as local when it is on a network of the device's Wi-Fi or Ethernet,
    /// reached without a router, which only the network knows. So this is a guess from the address
    /// alone, which errs towards local:
    /// - IPv4: the private ranges (10/8, 172.16/12, 192.168/16), link-local (169.254/16), multicast
    ///   and broadcast.
    /// - IPv6: link-local (fe80::/10), unique local (fc00::/7) and multicast, and IPv4 addresses
    ///   mapped into IPv6 as for IPv4.
    /// - Host names: Bonjour's `.local`, the suffixes home and office networks use, such as `.lan`
    ///   and `.home.arpa`, and names of one label, such as `nas`, which the network's own name server
    ///   resolves.
    ///
    /// The loopback is not the local network: `localhost`, 127/8 and ::1 are not. A public name that
    /// a name server resolves to a local address is missed, and iOS then asks without Shello's
    /// explanation.
    public var isOnLocalNetwork: Bool {
        switch AddressKind(of: address) {
        case .ipv4: Self.isLocal(ipv4: address)
        case .ipv6: Self.isLocal(ipv6: address)
        case .hostname: Self.isLocal(hostname: address)
        case nil: false
        }
    }

    private static func isLocal(ipv4 address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (224...239, _): return true
        default: return octets.allSatisfy { $0 == 255 }
        }
    }

    private static func isLocal(ipv6 address: String) -> Bool {
        let address = address.prefix { $0 != "%" }
        // An IPv4 address mapped into IPv6, ::ffff:192.168.1.2.
        if let lastColon = address.lastIndex(of: ":"), address[address.index(after: lastColon)...].contains(".") {
            let prefix = address[..<lastColon]
            return prefix == "::ffff" && isLocal(ipv4: String(address[address.index(after: lastColon)...]))
        }
        let first = address.prefix { $0 != ":" }
        guard let group = UInt16(first, radix: 16) else { return false }
        return group & 0xffc0 == 0xfe80 || group & 0xfe00 == 0xfc00 || group & 0xff00 == 0xff00
    }

    private static func isLocal(hostname address: String) -> Bool {
        let name = address.hasSuffix(".") ? String(address.dropLast()) : address
        guard name != "localhost", !name.hasSuffix(".localhost") else { return false }
        guard name.contains(".") else { return true }
        return localSuffixes.contains { name.hasSuffix($0) }
    }

    /// The name suffixes that only home and office networks resolve: Bonjour's, RFC 8375's for
    /// homes, ICANN's reserved one for private networks, and those routers commonly give.
    private static let localSuffixes = [".local", ".home.arpa", ".internal", ".lan", ".home", ".localdomain"]
}
