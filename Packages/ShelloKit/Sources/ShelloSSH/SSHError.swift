import Foundation
import Network

/// Why an SSH connection, or something on it, failed. Each case says it in a sentence the app can
/// show; none ever holds a secret.
public enum SSHError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The server could not be reached: the name does not resolve, there is no route, or nothing
    /// listens on the port.
    case unreachable(String)
    /// The server did not complete the connection and the key exchange within the connect timeout.
    case timedOut
    /// iOS did not let Shello reach the server, which is on the local network: the user has not
    /// allowed Local Network access, or has not answered the system's question yet (TN3179).
    case localNetworkDenied
    /// The connection ended without Shello closing it: the server closed it, or the network dropped
    /// it.
    case connectionLost(String)
    /// Shello closed the connection.
    case closed
    /// The server did not accept the password, the key or the answers.
    case authenticationFailed
    /// The server accepted the sign-in, but needs one of these methods as well, as a server with
    /// two-factor sign-in does.
    case partiallyAuthenticated(SSHAuthenticationMethods)
    /// The SSH agent did not sign the sign-in with the SSH key.
    case signingFailed
    /// The private key could not be read: it is not a key libssh knows, or the passphrase is wrong.
    case invalidKey
    /// The server refused to open a channel, or a request on one.
    case channelRefused(String)
    /// Something else went wrong in SSH itself, as libssh reported it.
    case protocolError(String)
    /// A system call failed, with its `errno`.
    case system(String, Int32)

    public var description: String {
        switch self {
        case .unreachable(let reason): "The server can’t be reached: \(reason)."
        case .timedOut: "The server didn’t answer in time."
        case .localNetworkDenied:
            "Shello isn’t allowed to reach devices on your local network. Turn on Local Network for Shello in "
                + "Settings, under Privacy & Security, then connect again."
        case .connectionLost(let reason): "The connection ended: \(reason)."
        case .closed: "The connection is closed."
        case .authenticationFailed: "The server didn’t accept the credentials."
        case .partiallyAuthenticated(let methods):
            "The server needs a further sign-in: \(methods.names.joined(separator: ", "))."
        case .signingFailed: "The SSH key didn’t sign the sign-in."
        case .invalidKey: "The SSH key can’t be read. Check that it’s a private key and that its passphrase is right."
        case .channelRefused(let reason): "The server refused the request: \(reason)."
        case .protocolError(let reason): "SSH failed: \(reason)."
        case .system(let action, let code): "\(action): \(Self.message(forErrno: code))."
        }
    }

    /// The error for a connection that Network.framework could not open, or that it lost.
    static func network(_ error: NWError, ready: Bool) -> SSHError {
        let reason: String
        switch error {
        case .posix(let code): reason = message(forErrno: code.rawValue).lowercased()
        case .dns: reason = "its name could not be found"
        default: reason = error.localizedDescription
        }
        return ready ? .connectionLost(reason) : .unreachable(reason)
    }

    /// What the system says `errno` means, such as "Connection refused".
    static func message(forErrno code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        guard unsafe strerror_r(code, &buffer, buffer.count) == 0 else { return "error \(code)" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// The sentence of `description` wherever the error is shown through `localizedDescription`, as a
/// terminal shows why its stream failed.
extension SSHError: LocalizedError {
    public var errorDescription: String? { description }
}
