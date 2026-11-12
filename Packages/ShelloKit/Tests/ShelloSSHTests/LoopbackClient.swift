import Foundation
import Network
import Synchronization
import Testing

@testable import ShelloSSH

/// A TCP client of a port forward, as another app on the device would be: it connects to an address
/// of this device, sends, and reads what comes back, and speaks SOCKS5 to a dynamic forward.
final class LoopbackClient: Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ch.shello.tests.client")
    private let hasEnded = Mutex(false)

    private init(connection: NWConnection) {
        self.connection = connection
    }

    deinit {
        connection.forceCancel()
    }

    /// Why a connection was not made.
    struct Refused: Error, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    /// A client connected to `port` of `address`, 127.0.0.1 by default.
    /// - Throws: `Refused` when nothing listens there, or nothing answers within five seconds.
    static func connect(to address: String = "127.0.0.1", port: UInt16) async throws -> LoopbackClient {
        let connection = NWConnection(
            host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let client = LoopbackClient(connection: connection)
        let result: Result<Void, Refused> = await withCheckedContinuation { continuation in
            let once = Mutex(false)
            let finish: @Sendable (Result<Void, Refused>) -> Void = { result in
                let isFirst = once.withLock { done in
                    defer { done = true }
                    return !done
                }
                if isFirst { continuation.resume(returning: result) }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(()))
                case .waiting(let error), .failed(let error): finish(.failure(Refused(reason: "\(error)")))
                case .cancelled: finish(.failure(Refused(reason: "cancelled")))
                default: break
                }
            }
            connection.start(queue: client.queue)
            client.queue.asyncAfter(deadline: .now() + 5) { finish(.failure(Refused(reason: "timed out"))) }
        }
        try result.get()
        return client
    }

    /// Whether a client can connect to `port` of `address`.
    static func canConnect(to address: String = "127.0.0.1", port: UInt16) async -> Bool {
        guard let client = try? await connect(to: address, port: port) else { return false }
        client.close()
        return true
    }

    func send(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: Data(bytes),
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
    }

    /// Ends what the client sends: the forward passes the end on, and the far end may still send.
    func finish() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
    }

    /// The next bytes, up to `maximum`, or nil once the far side ended its side.
    func receive(maximum: Int = 64 * 1024) async throws -> [UInt8]? {
        // The end can come with the last bytes; the connection then has nothing more to receive.
        guard !hasEnded.withLock({ $0 }) else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) {
                [self] content, _, isComplete, error in
                if isComplete { hasEnded.withLock { $0 = true } }
                if let error {
                    continuation.resume(throwing: error)
                } else if let content, !content.isEmpty {
                    continuation.resume(returning: Array(content))
                } else {
                    continuation.resume(returning: isComplete ? nil : [])
                }
            }
        }
    }

    /// Exactly `count` bytes, or fewer if the far side ends first.
    func read(count: Int) async throws -> [UInt8] {
        var bytes: [UInt8] = []
        while bytes.count < count, let chunk = try await receive(maximum: count - bytes.count) {
            bytes += chunk
        }
        return bytes
    }

    /// What arrives until it contains `text`, or the far side ends.
    func read(until text: String) async throws -> String {
        var received = ""
        while !received.contains(text), let chunk = try await receive() {
            received += String(decoding: chunk, as: UTF8.self)
        }
        return received
    }

    /// Everything until the far side ends.
    func readToEnd() async throws -> [UInt8] {
        var bytes: [UInt8] = []
        while let chunk = try await receive() {
            bytes += chunk
        }
        return bytes
    }

    func close() {
        connection.cancel()
    }

    // MARK: - SOCKS5

    /// Asks a dynamic forward, through SOCKS5 without authentication, to connect to `address`, an IPv4
    /// address or a domain name, and `port`. Returns the reply's code: 0 once connected.
    func socksConnect(to address: String, port: UInt16) async throws -> UInt8 {
        try await send([5, 1, 0])
        #expect(try await read(count: 2) == [5, 0])
        let parts = address.split(separator: ".")
        let isIPv4 = parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
        let addressBytes: [UInt8] =
            isIPv4 ? [1] + parts.map { UInt8($0)! } : [3, UInt8(address.utf8.count)] + Array(address.utf8)
        try await send([5, 1, 0] + addressBytes + [UInt8(port >> 8), UInt8(port & 0xFF)])
        let reply = try await read(count: 10)
        #expect(reply.count == 10)
        #expect(reply.first == 5)
        return reply.count > 1 ? reply[1] : 0xFF
    }
}

/// This device's addresses other than the loopback's and link-local ones, IPv4 and IPv6, as text: the
/// addresses on which another device on the network would reach a listener.
func networkAddresses() -> [String] {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard unsafe getifaddrs(&list) == 0 else { return [] }
    defer { unsafe freeifaddrs(list) }
    var addresses: [String] = []
    var entry = unsafe list
    while let current = unsafe entry {
        unsafe entry = current.pointee.ifa_next
        guard let address = unsafe current.pointee.ifa_addr else { continue }
        let family = Int32(unsafe address.pointee.sa_family)
        guard family == AF_INET || family == AF_INET6 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(unsafe address.pointee.sa_len)
        guard unsafe getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
            continue
        }
        let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if text.hasPrefix("127.") || text == "::1" || text.lowercased().hasPrefix("fe80") || text.contains("%") {
            continue
        }
        addresses.append(text)
    }
    return addresses
}

/// A port of the loopback that nothing listens on as this is called, which the system chose.
func freeLoopbackPort() async throws -> UInt16 {
    let listener = PortForwardListener(port: 0, target: .socks, open: { _, _ in throw CancellationError() })
    let port = try await listener.start()
    listener.stop()
    await listener.stopped()
    return port
}
