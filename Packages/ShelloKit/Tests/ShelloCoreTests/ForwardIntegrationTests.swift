import Foundation
import ShelloModel
import ShelloSSH
import ShelloStorage
import Testing

@testable import ShelloCore

/// A tab's port forwards against the test servers (TestServers/README.md): a local forward reaches
/// the host's own sshd, as the host sees it, directly and through a jump host, where the
/// destination is reached from the host, not the jump host; and a forward stops while the tab
/// reconnects after a network that broke (`FaultyProxy`), and listens again on the new connection.
///
/// A remote forward has the host's server listen, through a jump host too, where the jump host does
/// not: a connection to that port, which another connection of the test makes from the server, reaches
/// a listener this test runs on the Mac. One the server refuses fails alone, with its answer, and the
/// forward is requested again after a reconnect. Skipped when the servers are not running.
@MainActor
@Suite(.serialized, .enabled(TestServer.notRunning) { await TestServer.isRunning }, .timeLimit(.minutes(2)))
struct ForwardIntegrationTests {
    let test: TestConnector

    init() throws {
        test = try TestConnector()
    }

    /// The host's own sshd, as the host reaches it, through a local forward of a tab connected
    /// directly: a client of the forward reads its banner.
    @Test func localForwardReachesTheHostsOwnSSHD() async throws {
        let port = try await freeLoopbackPort()
        var host = try test.keyHost()
        host.portForwards = [Self.local(port, to: Self.ownSSHD(of: TestServer.port))]
        try await test.hosts.create(host)
        try await test.hostKeys.trust(TestServer.hostKeyA, of: host.server)
        let tabs = tabs()

        let tab = tabs.open(host)
        await waitUntil(timeout: .seconds(30)) {
            tab.forwards.forwards.first?.state == .listening(port: port, problem: nil)
        }

        let client = try await LoopbackClient.connect(port: port)
        #expect(try await client.read(until: "\r\n").hasPrefix("SSH-2.0-OpenSSH_"))
        client.close()
        await tabs.close(tab).value
        #expect(await LoopbackClient.isRefused(port: port))
    }

    /// Through a jump host, the forward runs on the last connection: its destination, `localhost`
    /// and the sshd's port, is reached from the host behind the jump host. In Docker that host is
    /// OpenSSH 9.6, whose banner says so, unlike the jump host's OpenSSH 10.3; this Mac's sshd, as in
    /// CI, is one machine, where the banners are the same.
    @Test func localForwardThroughAJumpHostReachesTheDestinationFromTheHost() async throws {
        let behindPort: UInt16 = TestServer.isThisMacsSSHD ? 2224 : 2223
        try #require(await TestServer.hasSSHBanner(port: behindPort), "The test server on \(behindPort) is not running")
        let port = try await freeLoopbackPort()
        var bastion = try test.keyHost()
        bastion.name = "bastion"
        var web = try test.keyHost()
        web.name = "web-01"
        let behind = TestServer.reachedFromAnother(port: behindPort)
        web.address = behind.address
        web.port = behind.port
        web.jumpHostIDs = [bastion.id]
        web.portForwards = [Self.local(port, to: Self.ownSSHD(of: behindPort))]
        try await test.hosts.create(bastion)
        try await test.hosts.create(web)
        try await test.hostKeys.trust(TestServer.hostKeyA, of: bastion.server)
        try await test.hostKeys.trust(TestServer.hostKeyA, of: web.server)
        let tabs = tabs()

        let tab = tabs.open(web)
        await waitUntil(timeout: .seconds(30)) {
            tab.forwards.forwards.first?.state == .listening(port: port, problem: nil)
        }

        #expect(tab.route?.hops.map(\.name) == ["bastion", "web-01"])
        let client = try await LoopbackClient.connect(port: port)
        let banner = try await client.read(until: "\r\n")
        #expect(banner.hasPrefix("SSH-2.0-OpenSSH_"))
        if !TestServer.isThisMacsSSHD {
            #expect(banner.hasPrefix("SSH-2.0-OpenSSH_9.6"), "\(banner)")
        }
        client.close()
        await tabs.close(tab).value
    }

    /// A network that drops stops the forward while the tab reconnects: nothing listens on its port.
    /// Once the tab has reconnected, the forward listens again on the same port, over the new
    /// connection.
    @Test func forwardListensAgainAfterAReconnect() async throws {
        let proxy = try await FaultyProxy(to: TestServer.port)
        let port = try await freeLoopbackPort()
        var host = try test.keyHost(port: proxy.port)
        host.address = "127.0.0.1"
        host.portForwards = [Self.local(port, to: Self.ownSSHD(of: TestServer.port))]
        try await test.hosts.create(host)
        try await test.hostKeys.trust(TestServer.hostKeyA, of: host.server)
        let tabs = tabs(policy: ReconnectPolicy(delays: Array(repeating: .milliseconds(200), count: 50)))
        let tab = tabs.open(host)
        await waitUntil(timeout: .seconds(30)) {
            tab.forwards.forwards.first?.state == .listening(port: port, problem: nil)
        }
        #expect(await LoopbackClient.canConnect(port: port))

        proxy.cut()
        await waitUntil(timeout: .seconds(30)) { tab.reconnecting?.failedAttempts ?? 0 >= 1 }

        #expect(tab.reconnecting != nil)
        #expect(tab.forwards.forwards.first?.state == .waiting)
        #expect(await LoopbackClient.isRefused(port: port))
        proxy.restore()
        await waitUntil(timeout: .seconds(30)) {
            tab.state == .active && tab.forwards.forwards.first?.state == .listening(port: port, problem: nil)
        }
        #expect(tab.connectionCount == 2)
        let client = try await LoopbackClient.connect(port: port)
        #expect(try await client.read(until: "\r\n").hasPrefix("SSH-2.0-OpenSSH_"))
        client.close()
        await tabs.close(tab).value
    }

    // MARK: - Remote forwards

    /// The server listens on its port for the tab's remote forward, and a connection to it from the
    /// server reaches the listener on the Mac; one on the privileged port 22, which the server
    /// refuses to the test user, fails alone, with what the server answered. Closing the tab cancels
    /// the forward: the server's port refuses connections.
    @Test func remoteForwardReachesAListenerOnTheMacAndARefusedOneFailsAlone() async throws {
        let destination = try await EchoServer(greeting: "hello from the Mac\n")
        let port = try await freeLoopbackPort()
        var host = try test.keyHost()
        host.portForwards = [Self.remote(22, to: destination.port), Self.remote(port, to: destination.port)]
        try await test.hosts.create(host)
        try await test.hostKeys.trust(TestServer.hostKeyA, of: host.server)
        let tabs = tabs()

        let tab = tabs.open(host)
        await waitUntil(timeout: .seconds(30)) {
            tab.state == .active && !tab.forwards.forwards.contains { $0.state == .starting || $0.state == .waiting }
        }

        #expect(
            tab.forwards.forwards.map(\.state) == [
                .failed(ForwardListenError.serverRefused(22).description), .listening(port: port, problem: nil),
            ])
        let reach = try await connection(to: TestServer.port)
        let tunnel = try await reach.openTunnel(to: "127.0.0.1", port: port)
        #expect(try await tunnel.read(until: "\n") == "hello from the Mac\n")
        await tunnel.close()
        await tabs.close(tab).value
        #expect(await Self.isRefusedOnTheServer(port, by: reach))
        await reach.close()
    }

    /// Through a jump host, the remote forward goes to the last connection: the host behind the jump
    /// host listens, and in Docker, where they are two machines, the jump host does not.
    @Test func remoteForwardThroughAJumpHostListensOnTheHost() async throws {
        let behindPort: UInt16 = TestServer.isThisMacsSSHD ? 2224 : 2223
        try #require(await TestServer.hasSSHBanner(port: behindPort), "The test server on \(behindPort) is not running")
        let destination = try await EchoServer(greeting: "behind the jump host\n")
        let port = try await freeLoopbackPort()
        var bastion = try test.keyHost()
        bastion.name = "bastion"
        var web = try test.keyHost()
        web.name = "web-01"
        let behind = TestServer.reachedFromAnother(port: behindPort)
        web.address = behind.address
        web.port = behind.port
        web.jumpHostIDs = [bastion.id]
        web.portForwards = [Self.remote(port, to: destination.port)]
        try await test.hosts.create(bastion)
        try await test.hosts.create(web)
        try await test.hostKeys.trust(TestServer.hostKeyA, of: bastion.server)
        try await test.hostKeys.trust(TestServer.hostKeyA, of: web.server)
        let tabs = tabs()

        let tab = tabs.open(web)
        await waitUntil(timeout: .seconds(30)) {
            tab.forwards.forwards.first?.state == .listening(port: port, problem: nil)
        }

        let direct = try await connection(to: behindPort)
        let tunnel = try await direct.openTunnel(to: "127.0.0.1", port: port)
        #expect(try await tunnel.read(until: "\n") == "behind the jump host\n")
        await tunnel.close()
        if !TestServer.isThisMacsSSHD {
            let jumpHost = try await connection(to: TestServer.port)
            await #expect(throws: SSHError.self) { try await jumpHost.openTunnel(to: "127.0.0.1", port: port) }
            await jumpHost.close()
        }
        await direct.close()
        await tabs.close(tab).value
    }

    /// A network that drops ends the connection, and the server's listening with it, once it sees
    /// the connection reset. Once the tab has reconnected, the remote forward is requested again, on
    /// the new connection, and reaches the listener on the Mac.
    @Test func remoteForwardIsRequestedAgainAfterAReconnect() async throws {
        let destination = try await EchoServer(greeting: "again\n")
        let proxy = try await FaultyProxy(to: TestServer.port)
        let port = try await freeLoopbackPort()
        var host = try test.keyHost(port: proxy.port)
        host.address = "127.0.0.1"
        host.portForwards = [Self.remote(port, to: destination.port)]
        try await test.hosts.create(host)
        try await test.hostKeys.trust(TestServer.hostKeyA, of: host.server)
        let tabs = tabs(policy: ReconnectPolicy(delays: Array(repeating: .milliseconds(200), count: 50)))
        let tab = tabs.open(host)
        await waitUntil(timeout: .seconds(30)) {
            tab.forwards.forwards.first?.state == .listening(port: port, problem: nil)
        }
        let reach = try await connection(to: TestServer.port)
        let before = try await reach.openTunnel(to: "127.0.0.1", port: port)
        #expect(try await before.read(until: "\n") == "again\n")
        await before.close()

        proxy.cut()
        await waitUntil(timeout: .seconds(30)) { tab.reconnecting?.failedAttempts ?? 0 >= 1 }

        #expect(tab.forwards.forwards.first?.state == .waiting)
        #expect(await Self.isRefusedOnTheServer(port, by: reach))
        proxy.restore()
        await waitUntil(timeout: .seconds(30)) {
            tab.state == .active && tab.forwards.forwards.first?.state == .listening(port: port, problem: nil)
        }
        #expect(tab.connectionCount == 2)
        let after = try await reach.openTunnel(to: "127.0.0.1", port: port)
        #expect(try await after.read(until: "\n") == "again\n")
        #expect(destination.acceptedCount == 2)
        await after.close()
        await reach.close()
        await tabs.close(tab).value
    }

    // MARK: - Helpers

    /// A connection of the test's own to the test server on `port` of this Mac, which reaches what
    /// that server reaches, as a program on it would.
    private func connection(to port: UInt16) async throws -> SSHConnection {
        let host = try test.keyHost(port: port)
        try await test.hostKeys.trust(TestServer.hostKeyA, of: host.server)
        return try await test.connector.connect(to: host) { _, _ in false }
    }

    /// Whether `port` of the server's loopback, as `connection`'s server reaches it, refuses
    /// connections within five seconds: the server lets go of a forward's port once it handled the
    /// cancel, or saw the connection end.
    private static func isRefusedOnTheServer(_ port: UInt16, by connection: SSHConnection) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            guard let tunnel = try? await connection.openTunnel(to: "127.0.0.1", port: port) else { return true }
            await tunnel.close()
            try? await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        return false
    }

    private func tabs(policy: ReconnectPolicy = .standard) -> TerminalTabs<FakeTerminal> {
        TerminalTabs(
            services: TabServices(
                connector: test.connector, hosts: test.hosts, network: FakeNetworkMonitor(), reconnectPolicy: policy),
            makeTerminal: { _ in FakeTerminal() })
    }

    /// The sshd of the test server on `port` of this Mac, as that server reaches it itself: in
    /// Docker, its own port 22; this Mac's sshd, its port on the loopback.
    private static func ownSSHD(of port: UInt16) -> ForwardDestination {
        TestServer.isThisMacsSSHD
            ? ForwardDestination(address: "127.0.0.1", port: port) : ForwardDestination(address: "localhost", port: 22)
    }

    private static func local(_ port: UInt16, to destination: ForwardDestination) -> PortForward {
        PortForward(port: port, kind: .local(destination: destination))
    }

    /// A remote forward from the server's `port`, on its loopback, to `destination` on this Mac's.
    private static func remote(_ port: UInt16, to destination: UInt16) -> PortForward {
        PortForward(
            port: port,
            kind: .remote(bindAddress: "", destination: ForwardDestination(address: "127.0.0.1", port: destination)))
    }
}
