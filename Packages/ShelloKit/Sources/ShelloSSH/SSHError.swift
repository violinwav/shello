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
    /// The connection ended without Shello closing it: the server closed it, or the network dropped
    /// it.
    case connectionLost(String)
    /// Shello closed the connection.
    case closed
    /// The server did not accept the password or the key.
    case authenticationFailed
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
        case .connectionLost(let reason): "The connection ended: \(reason)."
        case .closed: "The connection is closed."
        case .authenticationFailed: "The server didn’t accept the credentials."
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
