import Foundation
import Synchronization
import os

/// Shello's SSH agent (GLOSSARY, STACK section 7.3): it offers SSH keys of the key store and signs
/// with them on request, speaking the agent protocol written in-house (`SSHAgentProtocol.swift`).
/// libssh signs in through it (`ssh_userauth_agent`), so that one path signs for every key, the
/// Secure Enclave's included, which never hands libssh a private key.
///
/// An agent offers the keys it was made with, and nothing else: for a sign-in, the one key the host
/// signs in with. It refuses every request to add, remove or lock keys, and every extension. Each
/// signature goes through `SSHKeyStore.sign(_:with:flags:reason:)`, so a key signs as its signing
/// policy says: inside the unlock window, or after Face ID, Touch ID or the passcode on every use.
///
/// `listen()` serves one client on a socket; `answer(_:)` is the protocol itself.
public final class SSHAgent: Sendable {
    private let keys: SSHKeyStore
    private let identities: [SSHKey]
    private let reason: String?
    private let state = Mutex(State())

    private struct State {
        var failure: (any Error)?
        var listener: SSHAgentListener?
    }

    /// An agent that offers `identities`, keys of `keys`, in their order. A key that signs on every
    /// use asks the user with `reason`, such as the host it signs in to.
    public init(keys: SSHKeyStore, identities: [SSHKey], reason: String? = nil) {
        self.keys = keys
        self.identities = identities
        self.reason = reason
    }

    deinit {
        state.withLock { $0.listener?.close() }
    }

    /// Why the agent last failed to sign, if it did: the key store's error, such as
    /// `UnlockWindowClosed` or `UnlockError.cancelled`. libssh only hears that the agent refused.
    public var signingFailure: (any Error)? {
        state.withLock { $0.failure }
    }

    // MARK: - The socket

    /// Starts answering requests on one end of a new pair of connected Unix stream sockets, and
    /// returns the other end, for the client: `SSHConnection.authenticate(agentSocket:)` hands it to
    /// libssh, which then owns it. The agent answers on a queue of its own, one request after the
    /// other, until the client closes its end or `close()` is called. Listening again replaces the
    /// previous socket.
    /// - Throws: `SSHAgentError.socket` if the sockets cannot be made.
    public func listen() throws -> Int32 {
        let (agentEnd, clientEnd) = try SSHAgentListener.socketPair()
        let listener = SSHAgentListener(socket: agentEnd) { [weak self] message in
            guard let self else { return SSHAgentReply.failure.message }
            return await self.answer(message)
        }
        let previous = state.withLock { state in
            defer { state.listener = listener }
            return state.listener
        }
        previous?.close()
        listener.start()
        return clientEnd
    }

    /// Stops answering, and closes the agent's end of the socket: the client reads the end of it.
    public func close() {
        let listener = state.withLock { state in
            defer { state.listener = nil }
            return state.listener
        }
        listener?.close()
    }

    // MARK: - The protocol

    /// The reply to `message`, the contents of one request: the keys, a signature, or a failure.
    /// A message the agent cannot read gets a failure too.
    func answer(_ message: [UInt8]) async -> [UInt8] {
        let request: SSHAgentRequest
        do {
            request = try SSHAgentRequest(message: message)
        } catch {
            Self.logger.notice("Refused a request it could not read: \(String(describing: error), privacy: .public)")
            return SSHAgentReply.failure.message
        }
        return await answer(request).message
    }

    private func answer(_ request: SSHAgentRequest) async -> SSHAgentReply {
        switch request {
        case .requestIdentities:
            return .identities(
                identities.map {
                    SSHAgentIdentity(keyBlob: Array($0.publicKey.wireRepresentation), comment: $0.comment)
                })
        case .sign(let keyBlob, let data, let flags):
            guard let key = identities.first(where: { Array($0.publicKey.wireRepresentation) == keyBlob }) else {
                Self.logger.notice("Refused to sign with a key it does not offer")
                return .failure
            }
            do {
                let signature = try await keys.sign(
                    Data(data), with: key.id, flags: SSHSignatureFlags(rawValue: flags), reason: reason)
                state.withLock { $0.failure = nil }
                return .signature(Array(signature))
            } catch {
                Self.logger.notice("Could not sign: \(String(describing: error), privacy: .public)")
                state.withLock { $0.failure = error }
                return .failure
            }
        case .extension:
            return .failure
        case .unsupported(let type):
            Self.logger.notice("Refused request \(type, privacy: .public)")
            return .failure
        }
    }

    private static let logger = Logger(subsystem: "ch.shello.Shello", category: "SSHAgent")
}

/// Why the SSH agent could not start.
public enum SSHAgentError: Error, Equatable, CustomStringConvertible {
    /// A system call failed, with its `errno`.
    case socket(Int32)

    public var description: String {
        switch self {
        case .socket(let code): "Shello’s SSH agent couldn’t start (error \(code))."
        }
    }
}
