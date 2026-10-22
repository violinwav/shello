import Foundation
import Observation
import ShelloCore
import ShelloModel
import ShelloSSH
import ShelloSecurity
import ShelloTerminalUI
import os

/// A host's terminal and the connection behind it (README sections 3 to 5): connects when the screen
/// appears, asks the user to trust a new host key, blocks a changed one, signs in, and attaches the
/// terminal to the login shell. It keeps the key exchange the connection negotiated (README section
/// 14). One terminal at a time, until tabs come (#28): when the connection ends, the terminal says
/// so and keeps what it shows.
@Observable
final class HostTerminalModel {
    let host: Host
    let controller: TerminalController
    private(set) var phase = Phase.connecting
    /// The host key the trust sheet asks about, while it waits for the user.
    private(set) var trustQuestion: TrustQuestion?
    /// The changed host key the block sheet shows.
    var hostKeyChange: HostKeyChange?
    /// The key exchange the connection negotiated, once it is signed in: the Connection button shows
    /// it, post-quantum or classical (README section 14).
    private(set) var keyExchange: KeyExchange?

    @ObservationIgnored private let connector: HostConnector?
    @ObservationIgnored private var connection: SSHConnection?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var trustAnswer: CheckedContinuation<Bool, Never>?

    enum Phase: Equatable {
        case connecting
        /// The terminal is attached to the shell; its stream says when that ends.
        case attached
        /// Connecting failed, for the reason given.
        case failed(String)
        /// The user did not trust the host key, or the key changed: the screen closes.
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
        task = Task { await connect() }
        Task { [weak self] in
            try? await Task.sleep(for: Self.connectingAnnouncementDelay)
            guard let self, self.task?.isCancelled == false, self.phase == .connecting, self.trustQuestion == nil
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
        do {
            let connection = try await connector.connect(to: host) { [weak self] server, key in
                await self?.askToTrust(server, key) ?? false
            }
            self.connection = connection
            keyExchange = await connection.keyExchange
            let shell = try await connection.openShell(terminalType: host.terminalType, size: controller.size)
            try Task.checkCancellation()
            controller.attach(shell)
            phase = .attached
            announce("Connected to \(host.name)")
        } catch ConnectError.hostKeyChanged(let server, let trusted, let presented) {
            hostKeyChange = HostKeyChange(server: server, trusted: trusted, presented: presented)
            phase = .failed("The server’s host key changed.")
        } catch ConnectError.hostKeyNotTrusted {
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
