import Foundation
import ShelloModel
import ShelloSSH
import Testing

@testable import ShelloCore

/// A tab's port forwards (README section 4) on the fake server, whose tunnels send back what they
/// are sent: they listen on 127.0.0.1 once the tab is active, each that is on, and only while it is,
/// and while Shello is in the foreground; they stop when the connection drops or closes, or Shello
/// leaves the foreground, and listen again after a reconnect or on its return; a port another tab
/// or app has fails that forward only, and says so. Remote forwards are requested from the server
/// once the tab is active, go on in the background, are cancelled as the tab closes, before its
/// connection does, and are requested again after a reconnect; one the server refuses fails alone.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct TabForwardsTests {
    let test = TabTest()

    /// Each forward that is on listens once the tab is active, and carries a connection through the
    /// tab's connection to its destination; the one that is off stays off.
    @Test func forwardsListenOnceTheTabIsActive() async throws {
        let (local, dynamic) = (try await freeLoopbackPort(), try await freeLoopbackPort())
        let host = try Self.host(
            Self.local(local, to: "db.internal", 5432), PortForward(port: dynamic, kind: .dynamic),
            PortForward(port: 1, kind: .dynamic, isEnabled: false))

        let tab = try await test.openActiveTab(host)
        await waitUntil { !tab.forwards.forwards.contains { $0.state == .starting } }

        #expect(
            tab.forwards.forwards.map(\.state) == [
                .listening(port: local, problem: nil), .listening(port: dynamic, problem: nil), .off,
            ])
        let client = try await LoopbackClient.connect(port: local)
        try await client.send(Array("ping".utf8))
        #expect(try await client.read(until: "ping") == "ping")
        #expect(test.server.lastConnection?.forwardDestinations == ["db.internal:5432"])
        client.close()
        await test.tabs.close(tab).value
    }

    /// The forwards wait while the tab connects, stop when its connection drops, and listen again
    /// on the same ports once it has reconnected.
    @Test func forwardsStopWhenTheConnectionDropsAndListenAgainAfterTheReconnect() async throws {
        let port = try await freeLoopbackPort()
        let tab = try await test.openActiveTab(try Self.host(Self.local(port, to: "localhost", 22)))
        await waitUntil { tab.forwards.forwards.first?.state == .listening(port: port, problem: nil) }
        #expect(await LoopbackClient.canConnect(port: port))

        // Without a network, the tab waits to reconnect.
        test.network.set(available: false)
        await waitUntil { !test.tabs.isNetworkAvailable }
        test.server.lastConnection?.lose()
        await waitUntil { tab.state != .active }

        #expect(tab.forwards.forwards.first?.state == .waiting)
        #expect(await LoopbackClient.isRefused(port: port))
        test.network.set(available: true)
        await waitUntil { tab.state == .active }
        await waitUntil { tab.forwards.forwards.first?.state == .listening(port: port, problem: nil) }
        #expect(tab.connectionCount == 2)
        #expect(tab.forwards.forwards.first?.state == .listening(port: port, problem: nil))
        #expect(await LoopbackClient.canConnect(port: port))
        await test.tabs.close(tab).value
    }

    /// Closing the tab stops its forwards.
    @Test func closingTheTabStopsItsForwards() async throws {
        let port = try await freeLoopbackPort()
        let tab = try await test.openActiveTab(try Self.host(Self.local(port, to: "localhost", 22)))
        await waitUntil { tab.forwards.isActive && tab.forwards.forwards.first?.state != .starting }

        await test.tabs.close(tab).value

        #expect(tab.forwards.forwards.first?.state == .waiting)
        #expect(await LoopbackClient.isRefused(port: port))
    }

    /// As Shello leaves the foreground, the forwards stop at once, while the connection stays for
    /// the background time; back in the foreground, they listen again on that connection.
    @Test func leavingTheForegroundStopsTheForwardsAndComingBackListensAgain() async throws {
        let port = try await freeLoopbackPort()
        let tab = try await test.openActiveTab(try Self.host(Self.local(port, to: "localhost", 22)))
        await waitUntil { tab.forwards.forwards.first?.state == .listening(port: port, problem: nil) }

        test.tabs.isInForeground = false

        #expect(tab.state == .active)
        #expect(tab.forwards.forwards.first?.state == .waiting)
        #expect(await LoopbackClient.isRefused(port: port))
        test.tabs.isInForeground = true
        await waitUntil { tab.forwards.forwards.first?.state == .listening(port: port, problem: nil) }
        #expect(await LoopbackClient.canConnect(port: port))
        #expect(test.server.connections.count == 1)
        await test.tabs.close(tab).value
    }

    /// A tab that connects while Shello is in the background waits to listen until it is back.
    @Test func tabThatConnectsInTheBackgroundListensOnceShelloIsBack() async throws {
        let port = try await freeLoopbackPort()
        test.tabs.isInForeground = false

        let tab = try await test.openActiveTab(try Self.host(Self.local(port, to: "localhost", 22)))

        #expect(tab.forwards.forwards.first?.state == .waiting)
        test.tabs.isInForeground = true
        await waitUntil { tab.forwards.forwards.first?.state == .listening(port: port, problem: nil) }
        #expect(tab.forwards.forwards.first?.state == .listening(port: port, problem: nil))
        await test.tabs.close(tab).value
    }

    /// A port another tab already listens on, here a second tab of the same host, fails that forward
    /// only, with the reason; the tab's other forward listens.
    @Test func portAnotherTabHasFailsThatForwardOnly() async throws {
        let (shared, other) = (try await freeLoopbackPort(), try await freeLoopbackPort())
        let first = try await test.openActiveTab(try Self.host(Self.local(shared, to: "localhost", 22)))
        await waitUntil { first.forwards.forwards.first?.state == .listening(port: shared, problem: nil) }

        let second = try await test.openActiveTab(
            try Self.host(Self.local(shared, to: "localhost", 22), PortForward(port: other, kind: .dynamic)))
        await waitUntil { !second.forwards.forwards.contains { $0.state == .starting } }

        #expect(
            second.forwards.forwards.map(\.state) == [
                .failed("Port \(shared) is in use by another tab or app."), .listening(port: other, problem: nil),
            ])
        #expect(second.state == .active)
        #expect(first.forwards.forwards.first?.state == .listening(port: shared, problem: nil))
        await test.tabs.close(second).value
        await test.tabs.close(first).value
    }

    /// A connection whose destination the server cannot reach shows why under the forward, which
    /// keeps listening.
    @Test func destinationTheServerCannotReachShowsWhy() async throws {
        let port = try await freeLoopbackPort()
        let tab = try await test.openActiveTab(try Self.host(Self.local(port, to: "db.internal", 5432)))
        await waitUntil { tab.forwards.forwards.first?.state == .listening(port: port, problem: nil) }
        test.server.lastConnection?.refuseForwardTunnels()

        let client = try await LoopbackClient.connect(port: port)
        await waitUntil { tab.forwards.forwards.first?.state != .listening(port: port, problem: nil) }

        #expect(
            tab.forwards.forwards.first?.state
                == .listening(
                    port: port, problem: "The server couldn’t connect to db.internal:5432: Connection refused."))
        client.close()
        await test.tabs.close(tab).value
    }

    /// A reconnect takes the host's forwards as they are stored then; without storage, as they were.
    @Test func forwardsAreTheHostsAsItConnects() async throws {
        let port = try await freeLoopbackPort()
        let tab = try await test.openActiveTab(try Self.host(Self.local(port, to: "localhost", 22)))

        #expect(tab.forwards.forwards.map(\.forward) == tab.host.portForwards)
        await test.tabs.close(tab).value
    }

    // MARK: - Remote forwards

    /// Each remote forward that is on is requested from the server once the tab is active, on its
    /// loopback unless it says otherwise, and listens on the server's port; the one that is off is
    /// not requested.
    @Test func remoteForwardsAreRequestedOnceTheTabIsActive() async throws {
        let host = try Self.host(
            Self.remote(8080, to: "localhost", 3000), Self.remote(9000, bindAddress: "*", to: "localhost", 3001),
            PortForward(
                port: 9001, kind: .remote(bindAddress: "", destination: ForwardDestination(address: "x", port: 1)),
                isEnabled: false))

        let tab = try await test.openActiveTab(host)
        await waitUntil { !tab.forwards.forwards.contains { $0.state == .starting } }

        #expect(
            tab.forwards.forwards.map(\.state) == [
                .listening(port: 8080, problem: nil), .listening(port: 9000, problem: nil), .off,
            ])
        let connection = try #require(test.server.lastConnection)
        #expect(Set(connection.remoteForwardRequests) == ["localhost:8080", ":9000"])
        await test.tabs.close(tab).value
    }

    /// A port the server refuses fails that forward only, with what the server answered; the tab's
    /// other forwards listen, on the device and on the server.
    @Test func remoteForwardTheServerRefusesFailsThatForwardOnly() async throws {
        let local = try await freeLoopbackPort()
        test.server.onConnect { connection in connection.refuseRemoteForward(on: 22) }
        let host = try Self.host(
            Self.remote(22, to: "localhost", 3000), Self.remote(8080, to: "localhost", 3000),
            Self.local(local, to: "localhost", 22))

        let tab = try await test.openActiveTab(host)
        await waitUntil { !tab.forwards.forwards.contains { $0.state == .starting } }

        #expect(
            tab.forwards.forwards.map(\.state) == [
                .failed(
                    "The server refused to listen on its port 22. It may not allow remote forwards, or the port may "
                        + "be in use or reserved."),
                .listening(port: 8080, problem: nil), .listening(port: local, problem: nil),
            ])
        #expect(tab.state == .active)
        await test.tabs.close(tab).value
    }

    /// Leaving the foreground stops the local forwards at once, and leaves the remote ones, which
    /// nothing on the device can reach, to go on with the connection; back in the foreground, they
    /// are not requested again.
    @Test func remoteForwardsGoOnInTheBackground() async throws {
        let local = try await freeLoopbackPort()
        let tab = try await test.openActiveTab(
            try Self.host(Self.remote(8080, to: "localhost", 3000), Self.local(local, to: "localhost", 22)))
        await waitUntil { !tab.forwards.forwards.contains { $0.state == .starting } }

        test.tabs.isInForeground = false

        #expect(tab.forwards.forwards.map(\.state) == [.listening(port: 8080, problem: nil), .waiting])
        let connection = try #require(test.server.lastConnection)
        #expect(connection.remoteForwardCancels.isEmpty)
        test.tabs.isInForeground = true
        await waitUntil { tab.forwards.forwards[1].state == .listening(port: local, problem: nil) }
        #expect(connection.remoteForwardRequests == ["localhost:8080"])
        #expect(tab.forwards.forwards[0].state == .listening(port: 8080, problem: nil))
        await test.tabs.close(tab).value
    }

    /// A tab that connects while Shello is in the background requests its remote forwards at once.
    @Test func tabThatConnectsInTheBackgroundRequestsItsRemoteForwards() async throws {
        test.tabs.isInForeground = false

        let tab = try await test.openActiveTab(try Self.host(Self.remote(8080, to: "localhost", 3000)))
        await waitUntil { tab.forwards.forwards.first?.state != .starting }

        #expect(tab.forwards.forwards.first?.state == .listening(port: 8080, problem: nil))
        test.tabs.isInForeground = true
        await test.tabs.close(tab).value
    }

    /// Closing the tab cancels its remote forwards on the server before the connection closes.
    @Test func closingTheTabCancelsTheRemoteForwardsFirst() async throws {
        let tab = try await test.openActiveTab(try Self.host(Self.remote(8080, to: "localhost", 3000)))
        await waitUntil { tab.forwards.forwards.first?.state == .listening(port: 8080, problem: nil) }
        let connection = try #require(test.server.lastConnection)

        await test.tabs.close(tab).value

        #expect(connection.remoteForwardCancels == ["localhost:8080"])
        #expect(connection.cancelsBeforeClose == ["localhost:8080"])
        #expect(connection.isClosed)
        #expect(tab.forwards.forwards.first?.state == .waiting)
    }

    /// A dropped connection ends the server's listening with it; once the tab has reconnected, its
    /// remote forwards are requested again, on the new connection.
    @Test func remoteForwardsAreRequestedAgainAfterAReconnect() async throws {
        let tab = try await test.openActiveTab(try Self.host(Self.remote(8080, to: "localhost", 3000)))
        await waitUntil { tab.forwards.forwards.first?.state == .listening(port: 8080, problem: nil) }
        let first = try #require(test.server.lastConnection)

        first.lose()
        await waitUntil { tab.connectionCount == 2 && tab.state == .active }
        await waitUntil { tab.forwards.forwards.first?.state == .listening(port: 8080, problem: nil) }

        let second = try #require(test.server.lastConnection)
        #expect(second !== first)
        #expect(second.remoteForwardRequests == ["localhost:8080"])
        #expect(second.remoteForwardPorts == [8080])
        await test.tabs.close(tab).value
    }

    /// A connection the server forwards to a destination that does not answer is closed, and the
    /// forward says why, while it keeps listening.
    @Test func destinationThatDoesNotAnswerShowsWhy() async throws {
        let nothing = try await freeLoopbackPort()
        let tab = try await test.openActiveTab(try Self.host(Self.remote(8080, to: "127.0.0.1", nothing)))
        await waitUntil { tab.forwards.forwards.first?.state == .listening(port: 8080, problem: nil) }
        let channel = EchoTunnel()

        #expect(try #require(test.server.lastConnection).forwardConnection(to: 8080, through: channel))
        await waitUntil { tab.forwards.forwards.first?.state != .listening(port: 8080, problem: nil) }

        #expect(
            tab.forwards.forwards.first?.state
                == .listening(
                    port: 8080, problem: "Shello couldn’t connect to 127.0.0.1:\(nothing): Connection refused."))
        #expect(channel.isClosed)
        await test.tabs.close(tab).value
    }

    // MARK: - Helpers

    private static func host(_ forwards: PortForward...) throws -> Host {
        var host = TabTest.host()
        host.portForwards = forwards
        return host
    }

    private static func remote(
        _ port: UInt16, bindAddress: String = "", to address: String, _ destinationPort: UInt16
    ) -> PortForward {
        PortForward(
            port: port,
            kind: .remote(
                bindAddress: bindAddress, destination: ForwardDestination(address: address, port: destinationPort)))
    }

    private static func local(_ port: UInt16, to address: String, _ destinationPort: UInt16) -> PortForward {
        PortForward(
            port: port, kind: .local(destination: ForwardDestination(address: address, port: destinationPort)))
    }
}
