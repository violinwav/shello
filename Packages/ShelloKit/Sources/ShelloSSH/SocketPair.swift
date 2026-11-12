import Foundation

/// The two ends of the socketpair between libssh and the bridge (ADR 0002, STACK section 7.1).
/// libssh reads and writes one end as if it were the server; the bridge moves bytes between the other
/// end and Network.framework. Neither end ever blocks: the connection's queue runs libssh and the
/// bridge both, so a blocking read or write would wait for itself.
struct SocketPair {
    /// The end libssh gets through `SSH_OPTIONS_FD`.
    let libssh: Int32
    /// The end the bridge reads libssh's output from and writes the server's bytes to.
    let bridge: Int32

    /// How many bytes each end holds before a write to the other end takes only part of what it is
    /// given: room for several of Network.framework's reads, so that the bridge seldom waits for
    /// libssh to catch up.
    static let bufferSize: Int32 = 512 * 1024

    /// A connected pair of Unix stream sockets, both non-blocking, that never raise SIGPIPE: on Apple
    /// platforms libssh cannot pass `MSG_NOSIGNAL`, and a write to a closed peer would end the app.
    static func make() throws(SSHError) -> SocketPair {
        var ends: [Int32] = [-1, -1]
        guard unsafe socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0 else {
            throw .system("Could not create the socket pair", errno)
        }
        for end in ends {
            guard setOption(end, SO_NOSIGPIPE, 1), setOption(end, SO_SNDBUF, bufferSize),
                setOption(end, SO_RCVBUF, bufferSize), setNonBlocking(end)
            else {
                let code = errno
                for end in ends { close(end) }
                throw .system("Could not set up the socket pair", code)
            }
        }
        return SocketPair(libssh: ends[0], bridge: ends[1])
    }

    /// Makes `socket` non-blocking. libssh makes its socket blocking once it counts as connected
    /// (`ssh_socket_pollcallback`), so the connection makes it non-blocking again then. libssh
    /// handles the short writes this allows: it only writes after `poll` reported room.
    @discardableResult
    static func setNonBlocking(_ socket: Int32) -> Bool {
        let flags = fcntl(socket, F_GETFL)
        return flags >= 0 && fcntl(socket, F_SETFL, flags | O_NONBLOCK) == 0
    }

    /// How many bytes wait to be read from `socket`.
    static func unreadByteCount(_ socket: Int32) -> Int {
        var count: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard unsafe getsockopt(socket, SOL_SOCKET, SO_NREAD, &count, &length) == 0 else { return 0 }
        return Int(count)
    }

    private static func setOption(_ socket: Int32, _ option: Int32, _ value: Int32) -> Bool {
        var value = value
        return unsafe setsockopt(socket, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<Int32>.size)) == 0
    }
}
