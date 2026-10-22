import Foundation
import Observation
import ShelloCore
import ShelloModel
import ShelloSSH
import ShelloSecurity
import ShelloTerminalUI
import os

/// A host's terminal and the connection behind it (README sections 3 to 5): connects when the screen
/// appears, asks the user to trust a new host key, blocks a changed one until the user replaces it,
/// signs in, asking the server's keyboard-interactive questions, and attaches the terminal to the
/// login shell. It keeps the key exchange the connection negotiated (README section 14). One
/// terminal at a time, until tabs come (#28): when the connection ends, the terminal says so and keeps
/// what it shows.
@Observable
final class HostTerminalModel {
    let host: Host
    let controller: TerminalController
    private(set) var phase = Phase.connecting
    /// The host key the trust sheet asks about, while it waits for the user.
    private(set) var trustQuestion: TrustQuestion?
    /// The keyboard-interactive questions the sign-in sheet asks, while it waits for the user.
    private(set) var signInQuestion: SignInQuestion?
    /// Whether the server is asking keyboard-interactive questions: the sign-in sheet stays up from
    /// the first round of questions until signing in ends, and waits for the server between rounds.
    private(set) var isSigningIn = false
    /// The changed host key the block sheet shows.
    private(set) var hostKeyChange: HostKeyChange?
    /// Whether the trusted host key is being replaced: the user is asked to authenticate.
    private(set) var isReplacingHostKey = false
    /// Why the trusted host key was not replaced, for the block sheet.
    private(set) var replacementProblem: String?
    /// The key exchange the connection negotiated, once it is signed in: the Connection button shows
    /// it, post-quantum or classical (README section 14).
    private(set) var keyExchange: KeyExchange?

    @ObservationIgnored private let connector: HostConnector?
    @ObservationIgnored private var connection: SSHConnection?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var trustAnswer: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var signInAnswer: CheckedContinuation<[Secret]?, Never>?

    enum Phase: Equatable {
        case connecting
        /// The terminal is attached to the shell; its stream says when that ends.
        case attached
        /// Connecting failed, for the reason given.
        case failed(String)
        /// The user did not trust the host key, cancelled signing in, or closed the changed host
        /// key's sheet: the screen closes.
        case stopped
    }

    /// What the screen shows of the connection: nothing while the terminal works.
    enum Status: Equatable {
        case connecting
        case connected
        /// The shell ended, or the server closed the connection.
        case ended
        case failed(String)
    }

    struct TrustQuestion: Identifiable, Equatable {
        let id = UUID()
        let server: Server
        let key: HostKey
    }

    /// A round of the server's keyboard-interactive questions.
    struct SignInQuestion: Identifiable, Equatable {
        let id = UUID()
        let server: Server
        let challenge: KeyboardInteractiveChallenge
    }

    /// What the sheet over the terminal asks the user while connecting: to trust a new host key, or
    /// the server's questions, round after round, in one sheet.
    enum Prompt: Identifiable, Equatable {
        case trust(TrustQuestion)
        case signIn

        var id: String {
            switch self {
            case .trust(let question): "trust-\(question.id)"
            case .signIn: "sign-in"
            }
        }
    }

    var prompt: Prompt? {
        if let trustQuestion { return .trust(trustQuestion) }
        return isSigningIn ? .signIn : nil
    }

    /// The user dismissed the prompt: no trust, or no answers. Between rounds of questions, while
    /// the server checks the last answers, nothing waits for an answer: signing in stops all the
    /// same, and the screen closes.
    func dismissPrompt() {
        if trustQuestion != nil {
            answerTrust(false)
        } else if isSigningIn {
            isSigningIn = false
            if signInAnswer != nil {
                answerSignIn(nil)
            } else {
                task?.cancel()
                phase = .stopped
            }
        }
    }

    struct HostKeyChange: Identifiable, Equatable {
        let id = UUID()
        let server: Server
        let trusted: TrustedHostKey
        let presented: HostKey
    }

    init(host: Host, connector: HostConnector?, controller: TerminalController) {
        self.host = host
        self.connector = connector
        self.controller = controller
    }

    isolated deinit {
        task?.cancel()
        trustAnswer?.resume(returning: false)
        signInAnswer?.resume(returning: nil)
        if let connection {
            Task { await connection.close() }
        }
    }

    var status: Status {
        switch phase {
        case .connecting, .stopped: .connecting
        case .failed(let message): .failed(message)
        case .attached:
            switch controller.streamState {
            case .detached, .attached: .connected
            case .ended: .ended
            case .failed(let reason): .failed(reason)
            }
        }
    }

    /// Connects, once. VoiceOver hears the screen open; a connection that takes a while says so.
    func start() {
        guard task == nil else { return }
        connectAgain()
    }

    private func connectAgain() {
        phase = .connecting
        task = Task { await connect() }
        Task { [weak self] in
            try? await Task.sleep(for: Self.connectingAnnouncementDelay)
            guard let self, self.task?.isCancelled == false, self.phase == .connecting, self.trustQuestion == nil,
                !self.isSigningIn
            else { return }
            announce("Connecting to \(self.host.name)", priority: .low)
        }
    }

    private static let connectingAnnouncementDelay = Duration.seconds(2)

    private func connect() async {
        guard let connector else {
            phase = .failed("Shello can’t connect without its database.")
            return
        }
        // The sign-in sheet goes once signing in ends, whichever way.
        defer { isSigningIn = false }
        do {
            let connection = try await connector.connect(
                to: host,
                askToTrust: { [weak self] server, key in await self?.askToTrust(server, key) ?? false },
                answer: { [weak self] challenge in await self?.askToSignIn(challenge) })
            isSigningIn = false
            self.connection = connection
            keyExchange = await connection.keyExchange
            let shell = try await connection.openShell(terminalType: host.terminalType, size: controller.size)
            try Task.checkCancellation()
            controller.attach(shell)
            phase = .attached
            announce("Connected to \(host.name)")
        } catch ConnectError.hostKeyChanged(let server, let trusted, let presented) {
            replacementProblem = nil
            hostKeyChange = HostKeyChange(server: server, trusted: trusted, presented: presented)
            phase = .failed("The server’s host key changed.")
        } catch ConnectError.hostKeyNotTrusted, ConnectError.signInCancelled {
            phase = .stopped
        } catch is CancellationError {
            await connection?.close()
        } catch {
            // Closing the screen cancels connecting, and can make the step under way fail: nobody
            // is there to be told.
            guard !Task.isCancelled else { return }
            Self.logger.error("Could not connect to a host: \(String(describing: error))")
            phase = .failed(String(describing: error))
            announce(String(describing: error))
        }
    }

    // MARK: - Questions

    /// Shows the trust sheet and waits for the user's answer.
    private func askToTrust(_ server: Server, _ key: HostKey) async -> Bool {
        await withCheckedContinuation { continuation in
            trustAnswer = continuation
            trustQuestion = TrustQuestion(server: server, key: key)
        }
    }

    /// The user's answer to the trust sheet.
    func answerTrust(_ trusts: Bool) {
        trustQuestion = nil
        trustAnswer?.resume(returning: trusts)
        trustAnswer = nil
    }

    /// Shows the sign-in sheet with the server's questions and waits for the user's answers, or nil
    /// if they cancel.
    private func askToSignIn(_ challenge: KeyboardInteractiveChallenge) async -> [Secret]? {
        // A round that arrives after the user cancelled gets no sheet.
        guard !Task.isCancelled, phase != .stopped else { return nil }
        return await withCheckedContinuation { continuation in
            signInAnswer = continuation
            signInQuestion = SignInQuestion(server: host.server, challenge: challenge)
            isSigningIn = true
        }
    }

    /// The user's answers to the sign-in sheet, one for each question, or nil if they cancelled.
    func answerSignIn(_ answers: [Secret]?) {
        signInQuestion = nil
        signInAnswer?.resume(returning: answers)
        signInAnswer = nil
    }

    // MARK: - A changed host key

    /// Replaces the trusted host key with the one the server presented, once the user confirmed it
    /// on the block sheet and then authenticates (README section 3), and connects again.
    func replaceTrustedHostKey() {
        guard let change = hostKeyChange, let connector, !isReplacingHostKey else { return }
        isReplacingHostKey = true
        replacementProblem = nil
        Task {
            defer { isReplacingHostKey = false }
            do {
                try await connector.replaceTrustedKey(change.trusted, with: change.presented, of: change.server)
                announce("Replaced the trusted host key")
                hostKeyChange = nil
                connectAgain()
            } catch UnlockError.cancelled {
                // The user changed their mind at the prompt: the sheet stays, and says nothing.
            } catch let error as UnlockError {
                replacementProblem = error.replacementProblem
                announce(error.replacementProblem)
            } catch {
                replacementProblem = String(describing: error)
                announce(String(describing: error))
            }
        }
    }

    /// The block sheet went away. Unless the trusted key was replaced, which connects again, the
    /// screen closes with it.
    func hostKeyChangeDismissed() {
        guard hostKeyChange != nil else { return }
        hostKeyChange = nil
        phase = .stopped
    }

    // MARK: - The end

    /// The terminal's stream ended: the connection is no longer needed, and its end is said aloud.
    func streamChanged() {
        switch controller.streamState {
        case .ended:
            announce("Connection closed")
        case .failed(let reason):
            announce(reason)
        case .detached, .attached:
            return
        }
        closeConnection()
    }

    /// Ends everything: the connection, a question still open, and the terminal's attachment.
    func close() {
        task?.cancel()
        answerTrust(false)
        answerSignIn(nil)
        controller.detach()
        closeConnection()
    }

    private func closeConnection() {
        guard let connection else { return }
        self.connection = nil
        Task { await connection.close() }
    }

    private static let logger = Logger(subsystem: "ch.shello.Shello", category: "Connect")
}

extension UnlockError {
    /// Why the trusted host key stays, when the user did not authenticate.
    var replacementProblem: String {
        switch self {
        case .failed: "Shello couldn’t confirm that it’s you. The trusted host key stays."
        case .passcodeNotSet: "Shello can’t ask for your passcode. The trusted host key stays."
        case .cancelled: "Replacing the host key was cancelled."
        case .other(let code): "Shello couldn’t ask you to confirm (error \(code)). The trusted host key stays."
        }
    }
}
