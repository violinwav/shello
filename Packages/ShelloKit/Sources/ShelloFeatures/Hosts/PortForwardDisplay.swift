import ShelloCore
import ShelloModel

/// How the host editor and the Connection sheet name a port forward (README section 4), and how it
/// stands, in words for the screen and for VoiceOver, which reads "to" for the arrow.
enum PortForwardDisplay {
    /// What the forward's row says first: its name, or else its destination, or that it is a SOCKS
    /// proxy.
    static func title(_ forward: PortForward) -> String {
        let name = forward.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty else { return name }
        return forward.destination.map(\.description) ?? "SOCKS Proxy"
    }

    /// What an announcement calls the forward before its title: "remote forward" for a remote one,
    /// whose destination, titled alone, could be taken for the server's, and "port forward" for the
    /// others.
    static func spokenKind(_ forward: PortForward) -> String {
        forward.isRemote ? "remote forward" : "port forward"
    }

    /// `title` as VoiceOver reads it: a destination's port said as a port, "db.internal, port 5432",
    /// rather than run into the address.
    static func spokenTitle(_ forward: PortForward) -> String {
        let name = forward.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty, let destination = forward.destination else { return title(forward) }
        return "\(destination.address), port \(destination.port)"
    }

    /// What the forward does, under its title: "8080 → db.internal:5432", "SOCKS5 on 1080", or for a
    /// remote forward "Server port 8080 → localhost:3000", with the server's address when it has one,
    /// "Server 0.0.0.0:8080 → localhost:3000".
    static func summary(_ forward: PortForward) -> String {
        switch forward.kind {
        case .local(let destination):
            return "\(forward.port) → \(destination)"
        case .dynamic:
            return "SOCKS5 on \(forward.port)"
        case .remote(let bindAddress, let destination):
            guard !bindAddress.isEmpty else { return "Server port \(forward.port) → \(destination)" }
            let address = bindAddress.contains(":") ? "[\(bindAddress)]" : bindAddress
            return "Server \(address):\(forward.port) → \(destination)"
        }
    }

    /// `summary` as VoiceOver reads it: "Local forward, port 8080 to db.internal, port 5432",
    /// "Dynamic forward, SOCKS5 on port 1080", or "Remote forward, the server's port 8080 to
    /// localhost, port 3000", with "on all of the server's addresses" or "on 0.0.0.0" for a bind
    /// address.
    static func spokenSummary(_ forward: PortForward) -> String {
        switch forward.kind {
        case .local(let destination):
            return "Local forward, port \(forward.port) to \(destination.address), port \(destination.port)"
        case .dynamic:
            return "Dynamic forward, SOCKS5 on port \(forward.port)"
        case .remote(let bindAddress, let destination):
            let on =
                switch bindAddress {
                case "": ""
                case PortForward.allAddresses: " on all of the server’s addresses,"
                default: " on \(bindAddress),"
                }
            return "Remote forward, the server’s port \(forward.port)\(on) to \(destination.address), port "
                + "\(destination.port)"
        }
    }

    /// How a tab's forward stands, for the Connection sheet.
    static func state(_ state: ForwardState, of forward: PortForward) -> String {
        switch state {
        case .off: "Off"
        case .waiting: "Listens once the tab is connected"
        case .starting: "Starting…"
        case .listening(let port, _):
            forward.isRemote ? "Listening on the server’s port \(port)" : "Listening on 127.0.0.1:\(port)"
        case .failed(let reason): "Not listening. \(reason)"
        }
    }

    /// `state` as VoiceOver reads it, the address's dots as dots rather than a number.
    static func spokenState(_ state: ForwardState, of forward: PortForward) -> String {
        switch state {
        case .listening(let port, _) where !forward.isRemote: "Listening on 127.0.0.1, port \(port)"
        default: Self.state(state, of: forward)
        }
    }

    /// What the host editor and the Connection sheet say under the forwards: where they listen, and
    /// for how long (README section 4). `hasRemote` and `hasOnDevice` say whether the host has
    /// remote forwards, and local or dynamic ones; a host with none hears about the latter.
    static func lifetimeNote(hasRemote: Bool, hasOnDevice: Bool) -> String {
        guard hasRemote else { return deviceNote("Forwards") }
        let remote =
            "Remote forwards have the server listen, as long as the host’s tab is connected; the server’s "
            + "GatewayPorts setting decides who can reach them there."
        return hasOnDevice ? deviceNote("Local and dynamic forwards") + " " + remote : remote
    }

    /// `lifetimeNote(hasRemote:hasOnDevice:)` for `forwards`.
    static func lifetimeNote(_ forwards: [PortForward]) -> String {
        lifetimeNote(hasRemote: forwards.contains(where: \.isRemote), hasOnDevice: forwards.contains { !$0.isRemote })
    }

    private static func deviceNote(_ forwards: String) -> String {
        "\(forwards) listen on 127.0.0.1 of this device, only while Shello is open and the host’s tab is "
            + "connected. Other apps on this device can reach them meanwhile."
    }
}
