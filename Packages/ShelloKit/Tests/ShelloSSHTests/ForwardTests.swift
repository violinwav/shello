import Darwin
import Foundation
import ShelloModel
import Testing

@testable import ShelloSSH

/// Local and dynamic forwards (README section 4) over a connection to the test server on port 2222
/// (TestServers/README.md), whose tunnels reach what the server reaches: its own sshd, whose banner
/// a client of the forward reads, by IP address and by a name the server resolves; a port nothing
/// listens on, which a SOCKS5 client hears refused; and fifty megabytes from the server through a
/// local forward, which arrive whole while the memory stays flat. Skipped when the server is not
/// running.
@Suite(.serialized, .enabled(TestServer.notRunning) { await TestServer.isRunning }, .timeLimit(.minutes(3)))
struct ForwardTests {
    /// A local forward to the server's own sshd, as the server reaches it: a client reads its banner.
    @Test func localForwardReachesTheServersOwnSSHD() async throws {
        let connection = try await TestServer.signedInConnection()
        let listener = Self.localForward(on: connection, to: TestServer.ownPort)
        let port = try await listener.start()

        let client = try await LoopbackClient.connect(port: port)

        #expect(try await client.read(until: "\r\n").hasPrefix("SSH-2.0-OpenSSH_"))
        client.close()
        listener.stop()
        await connection.close()
    }

    /// A SOCKS5 client connects through a dynamic forward to the server's own sshd by its IP address,
    /// and by a domain name, `localhost`, which the server resolves; each reads the banner.
    @Test(arguments: [true, false])
    func dynamicForwardConnectsByAddressAndByName(byName: Bool) async throws {
        let connection = try await TestServer.signedInConnection()
        let listener = PortForwardListener(port: 0, target: .socks, open: Self.opener(connection))
        let port = try await listener.start()
        let client = try await LoopbackClient.connect(port: port)
        let address = byName ? "localhost" : "127.0.0.1"

        let reply = try await client.socksConnect(to: address, port: TestServer.ownPort.port)

        #expect(reply == SOCKS5.Reply.succeeded.rawValue)
        #expect(try await client.read(until: "\r\n").hasPrefix("SSH-2.0-OpenSSH_"))
        client.close()
        listener.stop()
        await connection.close()
    }

    /// A port nothing listens on, as the server finds it, is refused with SOCKS5's reply for it.
    @Test func dynamicForwardSaysWhenTheServerIsRefused() async throws {
        let connection = try await TestServer.signedInConnection()
        let listener = PortForwardListener(port: 0, target: .socks, open: Self.opener(connection))
        let port = try await listener.start()
        let client = try await LoopbackClient.connect(port: port)

        #expect(try await client.socksConnect(to: "127.0.0.1", port: 9) == SOCKS5.Reply.connectionRefused.rawValue)
        #expect(try await client.readToEnd() == [])
        listener.stop()
        await connection.close()
    }

    /// Fifty megabytes (52,488,896 bytes) from the server, through a local forward to its own sshd:
    /// an SSH connection through the forward runs a command that counts from 1 to 6,700,000 in a
    /// shell, raw, and every line arrives in order, compared as it comes, without keeping it. The
    /// process's memory footprint is sampled every megabyte: it stays flat, as does what the
    /// forward holds for the connection. The figures are printed for the issue.
    @Test func fiftyMegabytesThroughALocalForwardArriveWholeWithFlatMemory() async throws {
        let connection = try await TestServer.signedInConnection()
        let listener = Self.localForward(on: connection, to: TestServer.ownPort)
        let port = try await listener.start()
        let inner = SSHConnection(
            server: Server(address: "127.0.0.1", port: port), username: TestServer.user,
            connectTimeout: TestServer.connectTimeout)
        #expect(try await inner.connect() == TestServer.hostKeyA)
        try await inner.authenticate(privateKey: TestSecret(TestServer.clientKey))
        let shell = try await inner.openShell(
            terminalType: "xterm-256color", size: TerminalSize(columns: 80, rows: 24))
        var output = shell.output.makeAsyncIterator()
        let last = 6_700_000
        // macOS's seq writes a million as 1e+06 unless told the format, which BusyBox's seq, on the
        // Docker servers, does not take.
        let count = TestServer.isThisMacsSSHD ? "seq -f %.0f 1 \(last)" : "seq 1 \(last)"
        // Raw, so that the terminal passes every byte on as it is; the markers are written in octal,
        // so that the echo of the command line is not taken for them.
        shell.send(Array("stty raw -echo; printf '\\102EGIN\\n'; \(count); printf '\\105ND\\n'\r".utf8))

        var pending: [UInt8] = []
        while !String(decoding: pending, as: UTF8.self).contains("BEGIN\n"), let chunk = try await output.next() {
            pending += chunk
        }
        let marker = try #require(pending.firstRange(of: Array("BEGIN\n".utf8)))
        pending.removeSubrange(..<marker.upperBound)
        let baseline = MemoryFootprint.current
        let start = ContinuousClock.now
        var expected = ExpectedLines(last: last)
        var received = 0
        var isInOrder = true
        var peak = baseline
        var nextSample = 0
        while !expected.isDone {
            if pending.isEmpty {
                guard let chunk = try await output.next() else { break }
                pending = chunk
            }
            let matched = expected.match(pending)
            isInOrder = isInOrder && matched.isMatch
            guard matched.isMatch else { break }
            received += matched.count
            pending.removeFirst(matched.count)
            if received >= nextSample {
                peak = max(peak, MemoryFootprint.current)
                nextSample += 1024 * 1024
            }
        }
        let elapsed = ContinuousClock.now - start
        let after = MemoryFootprint.current
        while !String(decoding: pending, as: UTF8.self).contains("END\n"), let chunk = try await output.next() {
            pending += chunk
        }

        #expect(isInOrder)
        #expect(received == 52_488_896)
        #expect(String(decoding: pending, as: UTF8.self).hasPrefix("END\n"))
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let mebibyte = 1024.0 * 1024
        print(
            "50 MB through a local forward: \(received) bytes in order in "
                + "\((seconds).formatted(.number.precision(.fractionLength(1)))) s, "
                + "\((Double(received) / mebibyte / seconds).formatted(.number.precision(.fractionLength(1)))) MiB/s; "
                + "memory footprint \((Double(baseline) / mebibyte).formatted(.number.precision(.fractionLength(1)))) MiB "
                + "before, peak \((Double(peak) / mebibyte).formatted(.number.precision(.fractionLength(1)))) MiB "
                + "(+\((Double(peak - baseline) / mebibyte).formatted(.number.precision(.fractionLength(1)))) MiB), "
                + "\((Double(after) / mebibyte).formatted(.number.precision(.fractionLength(1)))) MiB after; "
                + "the forward held at most \(listener.maximumHeldByteCount) bytes for the connection")
        // Flat: the 50 MB never pile up anywhere. What libssh, the channels' windows and the sockets
        // hold on the way is a few mebibytes.
        #expect(peak - baseline < 16 * 1024 * 1024)
        #expect(listener.maximumHeldByteCount <= PortForwardListener.chunkSize)
        await inner.close()
        listener.stop()
        await connection.close()
    }

    // MARK: - Helpers

    /// A local forward on any free port of the loopback, to `destination` as the connection's server
    /// reaches it.
    private static func localForward(on connection: SSHConnection, to destination: Server) -> PortForwardListener {
        PortForwardListener(
            port: 0, target: .destination(address: destination.address, port: destination.port),
            open: opener(connection))
    }

    private static func opener(_ connection: SSHConnection) -> ForwardTunnelOpener {
        { address, port in try await connection.openTunnel(to: address, port: port) }
    }
}

/// The lines `seq` prints counting from 1 to `last`, compared with what arrives, piece by piece, a
/// mebibyte of them made at a time.
struct ExpectedLines {
    let last: Int
    private var next = 1
    private var buffer: [UInt8] = []
    private var offset = 0

    init(last: Int) {
        self.last = last
    }

    var isDone: Bool { next > last && offset == buffer.count }

    /// How many of `bytes`, from the start, are the lines expected next, and whether all of them
    /// were, up to the last line.
    mutating func match(_ bytes: [UInt8]) -> (count: Int, isMatch: Bool) {
        var index = 0
        while index < bytes.count, !isDone {
            if offset == buffer.count { refill() }
            let length = min(buffer.count - offset, bytes.count - index)
            let isEqual = unsafe bytes.withUnsafeBytes { received in
                unsafe buffer.withUnsafeBytes { expected in
                    unsafe memcmp(received.baseAddress! + index, expected.baseAddress! + offset, length) == 0
                }
            }
            guard isEqual else { return (index, false) }
            index += length
            offset += length
        }
        return (index, true)
    }

    /// The next mebibyte of lines, or the rest.
    private mutating func refill() {
        buffer.removeAll(keepingCapacity: true)
        offset = 0
        var digits: [UInt8] = []
        while next <= last, buffer.count < 1024 * 1024 {
            digits.removeAll(keepingCapacity: true)
            var number = next
            repeat {
                digits.append(UInt8(ascii: "0") + UInt8(number % 10))
                number /= 10
            } while number > 0
            buffer.append(contentsOf: digits.reversed())
            buffer.append(UInt8(ascii: "\n"))
            next += 1
        }
    }
}

/// The process's memory footprint, as Xcode's memory gauge and Jetsam count it.
enum MemoryFootprint {
    static var current: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = unsafe withUnsafeMutablePointer(to: &info) { pointer in
            unsafe pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { integers in
                unsafe task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), integers, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
