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

    /// `title` as VoiceOver reads it: a destination's port said as a port, "db.internal, port 5432",
    /// rather than run into the address.
    static func spokenTitle(_ forward: PortForward) -> String {
        let name = forward.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty, let destination = forward.destination else { return title(forward) }
        return "\(destination.address), port \(destination.port)"
    }

    /// What the forward does, under its title: "8080 → db.internal:5432", or "SOCKS5 on 1080".
    static func summary(_ forward: PortForward) -> String {
        guard let destination = forward.destination else { return "SOCKS5 on \(forward.localPort)" }
        return "\(forward.localPort) → \(destination)"
    }

    /// `summary` as VoiceOver reads it: "Local forward, port 8080 to db.internal, port 5432", or
    /// "Dynamic forward, SOCKS5 on port 1080".
    static func spokenSummary(_ forward: PortForward) -> String {
        guard let destination = forward.destination else {
            return "Dynamic forward, SOCKS5 on port \(forward.localPort)"
        }
        return "Local forward, port \(forward.localPort) to \(destination.address), port \(destination.port)"
    }

    /// How a tab's forward stands, for the Connection sheet.
    static func state(_ state: ForwardState) -> String {
        switch state {
        case .off: "Off"
        case .waiting: "Listens once the tab is connected"
        case .starting: "Starting…"
        case .listening(let port, _): "Listening on 127.0.0.1:\(port)"
        case .failed(let reason): "Not listening. \(reason)"
        }
    }

    /// `state` as VoiceOver reads it, the address's dots as dots rather than a number.
    static func spokenState(_ state: ForwardState) -> String {
        switch state {
        case .listening(let port, _): "Listening on 127.0.0.1, port \(port)"
        default: Self.state(state)
        }
    }

    /// What the host editor and the Connection sheet say under the forwards: where they listen, and
    /// for how long (README section 4).
    static let lifetimeNote =
        "Forwards listen on 127.0.0.1 of this device, only while Shello is open and the host’s tab is "
        + "connected. Other apps on this device can reach them meanwhile."
}
