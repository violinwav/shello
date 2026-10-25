import ShelloModel

// How hosts and their fields read on screen and to VoiceOver.

extension HostProtocol {
    var displayName: String {
        switch self {
        case .ssh: "SSH"
        case .mosh: "Mosh"
        case .vnc: "VNC"
        }
    }

    /// The protocol on a host's badge.
    var badgeTitle: String {
        switch self {
        case .ssh: "SSH"
        case .mosh: "MOSH"
        case .vnc: "VNC"
        }
    }

    /// What the protocol offers and what it needs, under the protocol picker.
    var summary: String {
        switch self {
        case .ssh: "Plain SSH-2. Works with any SSH server, with nothing to set up on it."
        case .mosh: "Stays connected through Wi-Fi to cellular switches and sleep. Needs mosh-server on the server."
        case .vnc: "Remote desktop with trackpad and direct-touch input. Needs a VNC server running on the server."
        }
    }
}

extension AuthMethod {
    var displayName: String {
        switch self {
        case .sshKey: "SSH Key"
        case .password: "Password"
        case .keyboardInteractive: "Keyboard-Interactive"
        }
    }
}

extension Host {
    /// The user and the address, as `ssh` takes them, with the port when it is not the protocol's
    /// default: `deploy@10.0.4.21`, `nas.lan:2222`, `[2001:db8::21]:2222`.
    var connectionSummary: String {
        let user = username.isEmpty ? "" : "\(username)@"
        guard port != `protocol`.defaultPort else { return user + address }
        let address = address.contains(":") ? "[\(address)]" : address
        return "\(user)\(address):\(port)"
    }

    /// `connectionSummary` as VoiceOver reads it: "deploy at 10.0.4.21, port 2222".
    var spokenConnectionSummary: String {
        let user = username.isEmpty ? "" : "\(username) at "
        let port = port == `protocol`.defaultPort ? "" : ", port \(port)"
        return user + address + port
    }
}
