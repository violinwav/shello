import Foundation
import ShelloModel
import ShelloSSH

/// Where a tab is in its lifecycle (README section 4): connect, verify the host key, sign in, run the
/// startup command, active; and what happens after a connection drops.
public enum TabState: Equatable, Sendable {
    /// The tab's first connection is being made, at this step.
    case connecting(ConnectStep)
    /// The terminal is attached to the shell, and the keepalive checks the connection.
    case active
    /// The connection dropped, and the tab is getting a new one: trying, or waiting before the next
    /// try. The terminal keeps what it shows.
    case reconnecting(Reconnecting)
    /// Shello closed the connection in the background (README section 4). The tab reconnects once it
    /// is on screen again.
    case suspended
    /// The shell ended, as after `exit`: nothing reconnects until the user asks.
    case ended
    /// The tab has no connection, for the reason given, and does not try again by itself: connecting
    /// failed in a way that trying again would not change, or the tab gave up reconnecting.
    case disconnected(String)
    /// The tab was closed.
    case closed

    /// Whether the tab is making a connection, or waiting to try again.
    public var isConnecting: Bool {
        switch self {
        case .connecting, .reconnecting: true
        case .active, .suspended, .ended, .disconnected, .closed: false
        }
    }
}

/// The steps of making a connection, in their order.
public enum ConnectStep: Int, Comparable, Sendable {
    /// Opening the network connection and running SSH's key exchange.
    case connecting
    /// Checking the server's host key against the trusted one, or asking the user to trust it.
    case verifyingHostKey
    /// Signing in: a password, an SSH key, or the server's questions.
    case signingIn
    /// Starting the login shell and running the host's startup command.
    case startingSession

    public static func < (lhs: ConnectStep, rhs: ConnectStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A tab getting a new connection after its last one dropped.
public struct Reconnecting: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// A try is under way, at this step.
        case trying(ConnectStep)
        /// The tab waits this long before its next try: the waits grow with each failed try
        /// (`ReconnectPolicy`).
        case waiting(Duration)
        /// The device has no network: the tab tries again as soon as it has one.
        case waitingForNetwork
        /// Shello is in the background, or locked: the tab tries again once it is unlocked and on
        /// screen.
        case waitingForUnlock
    }

    public var phase: Phase
    /// The tries that failed since the connection dropped.
    public var failedAttempts: Int
    /// Why the connection dropped, or why the last try failed.
    public var reason: String

    public init(phase: Phase, failedAttempts: Int, reason: String) {
        self.phase = phase
        self.failedAttempts = failedAttempts
        self.reason = reason
    }
}

/// When a tab tries to reconnect after its connection dropped (README section 4): the first try
/// goes at once, then each failed try waits longer before the next, until the tab gives up. While
/// the device has no network, the tab waits for it instead, and tries again at once when it is back.
public struct ReconnectPolicy: Hashable, Sendable {
    /// The waits after the first failed try, the second, and so on. The tab gives up after the
    /// last one's try fails too.
    public var delays: [Duration]

    public init(delays: [Duration]) {
        self.delays = delays
    }

    /// Waits that double from one second up to half a minute: seven tries in about a minute.
    public static let standard = ReconnectPolicy(delays: [1, 2, 4, 8, 16, 30].map { Duration.seconds($0) })

    /// How long to wait after `failedAttempts` failed tries, or nil once the tab gives up.
    public func delay(afterFailedAttempts failedAttempts: Int) -> Duration? {
        guard failedAttempts >= 1, failedAttempts <= delays.count else { return nil }
        return delays[failedAttempts - 1]
    }
}

/// A server's host key that the user is asked to trust, on the first connection to the server.
public struct TrustQuestion: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let server: Server
    public let key: HostKey
}

/// A round of the server's keyboard-interactive questions.
public struct SignInQuestion: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let server: Server
    public let challenge: KeyboardInteractiveChallenge
}

/// A host key that differs from the one the user trusted: the connection is blocked until the user
/// replaces the trusted key (README section 3).
public struct HostKeyChange: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let server: Server
    public let trusted: TrustedHostKey
    public let presented: HostKey
}
