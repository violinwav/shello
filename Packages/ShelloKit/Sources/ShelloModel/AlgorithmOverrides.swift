/// A host's own algorithm lists, which replace those of the algorithm policy (GLOSSARY) for
/// connections to its server: the preference order can change per host (README section 14), and v1
/// enables a legacy algorithm for one host only this way (README section 4).
///
/// Each list names algorithms as SSH does, most preferred first. A list that is nil, or empty, keeps
/// the policy's. Shello has no screen for them yet, and does not store them: both come with v1.
public struct AlgorithmOverrides: Hashable, Sendable {
    /// The key exchanges to offer.
    public var keyExchanges: [String]?
    /// The ciphers to offer, in both directions.
    public var ciphers: [String]?
    /// The MACs to offer, in both directions.
    public var macs: [String]?
    /// The algorithms of the host keys the server may identify itself with.
    public var hostKeyAlgorithms: [String]?
    /// The signature algorithms an SSH key may sign in with.
    public var sshKeyAlgorithms: [String]?

    public init(
        keyExchanges: [String]? = nil, ciphers: [String]? = nil, macs: [String]? = nil,
        hostKeyAlgorithms: [String]? = nil, sshKeyAlgorithms: [String]? = nil
    ) {
        self.keyExchanges = keyExchanges
        self.ciphers = ciphers
        self.macs = macs
        self.hostKeyAlgorithms = hostKeyAlgorithms
        self.sshKeyAlgorithms = sshKeyAlgorithms
    }

    /// No overrides: the algorithm policy as it ships.
    public static let none = AlgorithmOverrides()
}
