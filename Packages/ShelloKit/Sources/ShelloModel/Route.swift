/// The hosts a connection to a host goes through to reach its server (GLOSSARY: Route), in order:
/// the route to its first jump host, then its other jump hosts, then the host itself, as OpenSSH's
/// `ProxyJump` goes (README section 3). Each host on the route is a hop: Shello reaches the first
/// from the device, and each of the others through a channel of the connection to the hop before.
/// A host without jump hosts has a route of one hop, itself, which Shello reaches directly.
///
/// The first jump host's own jump hosts count, as OpenSSH applies a first hop's own `ProxyJump`;
/// those of the other jump hosts do not, since the hops before them already lead there.
///
/// Shello refuses a route that reaches a host twice, which a host listing itself or a host that
/// jumps through it would make, a route with more than `maximumJumpHosts` jump hosts, a jump host
/// that is not an SSH host, and a jump host that is missing: a missing jump host never means
/// connecting directly.
public struct Route: Hashable, Sendable {
    /// The hosts, from the one Shello reaches from the device to the host the route leads to.
    public let hops: [Host]

    /// The most jump hosts a route may have. OpenSSH sets no limit; more hops than this would make
    /// every keystroke slow, and a route this long is more likely a mistake.
    public static let maximumJumpHosts = 8

    /// The route to `host`, through the jump hosts among `hosts`, the hosts Shello has saved, by
    /// identifier. `host` itself is taken as given, which may differ from the saved one, as in the
    /// host editor.
    /// - Throws: `RouteError` for a route Shello refuses.
    public init(to host: Host, hosts: [Host.ID: Host]) throws(RouteError) {
        hops = try Self.hops(to: host, hosts: hosts, outside: [])
    }

    /// The host the route leads to.
    public var host: Host { hops[hops.count - 1] }

    /// The hop Shello reaches from the device: the only one whose server can be on the device's
    /// local network (README section 3), and whose network the tab follows.
    public var firstHop: Host { hops[0] }

    /// The hosts before the host, in order.
    public var jumpHosts: ArraySlice<Host> { hops.dropLast() }

    /// The hops of the route to `host`, whose way already passes through the hosts `outside`.
    private static func hops(
        to host: Host, hosts: [Host.ID: Host], outside: [Host.ID]
    ) throws(RouteError) -> [Host] {
        // Reached again on the way to itself: its first jump host, or one of that one's, jumps
        // through it.
        guard !outside.contains(host.id) else { throw .repeatsHost(host.name) }
        guard let firstID = host.jumpHostIDs.first else { return [host] }
        // Each first jump host adds a hop, so a route this deep is too long already.
        guard outside.count < maximumJumpHosts else { throw .tooManyJumpHosts }
        var hops = try Self.hops(
            to: try jumpHost(firstID, of: host, among: hosts), hosts: hosts, outside: outside + [host.id])
        for id in host.jumpHostIDs.dropFirst() {
            hops.append(try jumpHost(id, of: host, among: hosts))
        }
        hops.append(host)
        var seen: Set<Host.ID> = []
        for hop in hops where !seen.insert(hop.id).inserted {
            throw .repeatsHost(hop.name)
        }
        guard hops.count - 1 <= maximumJumpHosts else { throw .tooManyJumpHosts }
        for hop in hops.dropLast() where hop.protocol != .ssh {
            throw .notSSH(hop.name)
        }
        return hops
    }

    /// The jump host `id` of `host`, among the saved `hosts`. A host that lists itself, saved or
    /// not yet, would reach itself twice.
    private static func jumpHost(_ id: Host.ID, of host: Host, among hosts: [Host.ID: Host]) throws(RouteError) -> Host
    {
        guard id != host.id else { throw .repeatsHost(host.name) }
        guard let jumpHost = hosts[id] else { throw .missingJumpHost(of: host.name) }
        return jumpHost
    }

    /// The hosts among `hosts` whose routes go through the host `id`: those that list it as a jump
    /// host, and those whose first jump host's route goes through it. Their routes would fail once
    /// it is deleted, which the confirmation says. In the order of `hosts`.
    public static func hosts(jumpingThrough id: Host.ID, among hosts: [Host]) -> [Host] {
        let byID = Dictionary(hosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func goesThrough(_ host: Host, outside: Set<Host.ID>) -> Bool {
            if host.jumpHostIDs.contains(id) { return true }
            guard let firstID = host.jumpHostIDs.first, !outside.contains(firstID), let first = byID[firstID] else {
                return false
            }
            return goesThrough(first, outside: outside.union([host.id]))
        }
        return hosts.filter { $0.id != id && goesThrough($0, outside: []) }
    }
}

/// Why Shello refuses a route (`Route`), and what to change, in a few words: the terminal's status
/// bar says it, where a long message would scroll at the largest text sizes.
public enum RouteError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The host named lists a jump host that Shello does not have: it was deleted, or was never in
    /// Shello, as when an import left it out.
    case missingJumpHost(of: String)
    /// The route reaches the host named twice.
    case repeatsHost(String)
    /// The route has more jump hosts than `Route.maximumJumpHosts`.
    case tooManyJumpHosts
    /// The host named is a jump host, but not an SSH host.
    case notSSH(String)

    public var description: String {
        switch self {
        case .missingJumpHost(let host):
            "One of \(host)’s jump hosts was deleted. Change them to connect."
        case .repeatsHost(let host):
            "The route goes through \(host) twice. Change the jump hosts."
        case .tooManyJumpHosts:
            "The route goes through more than \(Route.maximumJumpHosts) jump hosts. Use \(Route.maximumJumpHosts) or fewer."
        case .notSSH(let host):
            "\(host) isn’t an SSH host, so it can’t be a jump host. Change the jump hosts."
        }
    }
}
