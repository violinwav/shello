import Foundation
import ShelloCore
import ShelloModel

/// How the import from OpenSSH's files (README section 3) reads on screen and to VoiceOver: what it
/// adds, what Shello has already, and what it leaves out.
enum OpenSSHImportDisplay {
    /// "1 host", "2 host keys".
    static func count(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// What the import would do, in a sentence or two, for the top of the preview: what it adds,
    /// then how many lines it leaves out.
    static func overview(_ plan: OpenSSHImportPlan) -> String {
        let adds = [(plan.hosts.count, "host"), (plan.keys.count, "host key")]
            .filter { count, _ in count > 0 }
        var sentences: [String] = []
        if adds.isEmpty {
            sentences.append("There’s nothing new to import.")
        } else {
            let parts = adds.map { count, noun in self.count(count, noun) }
            let verb = plan.hosts.isEmpty ? "trusts" : "adds"
            var sentence = "Import \(verb) \(parts[0])"
            if parts.count == 2 {
                sentence += " and trusts \(parts[1])"
            }
            sentences.append(sentence + ".")
        }
        if !plan.conflicts.isEmpty {
            let keys = count(plan.conflicts.count, "host key")
            sentences.append(
                "\(keys) differ\(plan.conflicts.count == 1 ? "s" : "") from what Shello trusts, which it keeps.")
        }
        if !plan.notImported.isEmpty {
            let lines = count(plan.notImported.count, "line")
            sentences.append("\(lines) \(plan.notImported.count == 1 ? "isn’t" : "aren’t") imported, as listed below.")
        }
        return sentences.joined(separator: " ")
    }

    // MARK: - Hosts

    /// Where a host signs in: "deploy@10.0.1.21:22", or "10.0.1.21:22, no user".
    static func signIn(_ host: Host) -> String {
        let server = host.server.description
        return host.username.isEmpty ? "\(server), no user" : "\(host.username)@\(server)"
    }

    /// `signIn` as VoiceOver reads it: "deploy at 10.0.1.21, port 22".
    static func spokenSignIn(_ host: Host) -> String {
        let server = "\(host.address), port \(host.port)"
        return host.username.isEmpty ? "\(server), no user" : "\(host.username) at \(server)"
    }

    /// The jump hosts, as the screen shows them: "Through bastion → gate (in Shello)".
    static func jumpHosts(_ jumpHosts: [OpenSSHImportPlan.JumpHost]) -> String {
        "Through " + JumpHostDisplay.shown(jumpHosts.map { $0.isSaved ? "\($0.name) (in Shello)" : $0.name })
    }

    /// The jump hosts as VoiceOver reads them: "Through bastion, then gate, already in Shello".
    static func spokenJumpHosts(_ jumpHosts: [OpenSSHImportPlan.JumpHost]) -> String {
        "Through " + JumpHostDisplay.spoken(jumpHosts.map { $0.isSaved ? "\($0.name), already in Shello" : $0.name })
    }

    /// The SSH key a new host signs in with.
    static func sshKey(_ choice: OpenSSHImportPlan.SSHKeyChoice) -> String {
        switch choice {
        case .key(_, let name): "SSH key: \(name)"
        case .toChoose(let file?): "SSH key to choose: import “\(file)” first"
        case .toChoose(nil): "SSH key to choose"
        }
    }

    /// Where a new host comes from in the config file.
    static func origin(_ host: OpenSSHImportPlan.NewHost) -> String {
        switch host.origin {
        case .alias(let line): "Line \(line)"
        case .jumpHost(let of, let line): "Jump host of \(of), line \(line)"
        }
    }

    /// One line under a new host's name.
    struct Detail: Hashable {
        let text: String
        /// Whether it says what the user still has to do before the host connects, which the row
        /// marks.
        var needsAttention = false
    }

    /// What a new host still needs before it connects: "a user", "an SSH key".
    static func needs(_ host: OpenSSHImportPlan.NewHost) -> [String] {
        var needs: [String] = []
        if host.host.username.isEmpty {
            needs.append("a user")
        }
        if case .toChoose = host.sshKey {
            needs.append("an SSH key")
        }
        return needs
    }

    /// The lines under a new host's name, in order, as the screen shows them: where it signs in, its
    /// jump hosts, its forwards, its SSH key, and its line; and, marked, what it still needs.
    static func details(_ host: OpenSSHImportPlan.NewHost) -> [Detail] {
        var lines = [Detail(text: signIn(host.host))]
        if !host.jumpHosts.isEmpty {
            lines.append(Detail(text: jumpHosts(host.jumpHosts)))
        }
        lines += host.host.portForwards.map { Detail(text: PortForwardDisplay.summary($0)) }
        if case .key = host.sshKey {
            lines.append(Detail(text: sshKey(host.sshKey)))
        } else {
            lines.append(Detail(text: sshKey(host.sshKey), needsAttention: true))
        }
        if host.host.username.isEmpty {
            lines.append(Detail(text: "Enter a user before connecting", needsAttention: true))
        }
        lines.append(Detail(text: origin(host)))
        return lines
    }

    /// `details` as VoiceOver reads them, in one value, with what the host still needs first, so that
    /// it is not lost after its forwards: "Needs a user and an SSH key. 10.0.1.21, port 22, no user.
    /// …".
    static func spokenDetails(_ host: OpenSSHImportPlan.NewHost) -> String {
        var parts: [String] = []
        let needs = needs(host)
        if !needs.isEmpty {
            parts.append("Needs \(needs.formatted(.list(type: .and)))")
        }
        parts.append(spokenSignIn(host.host))
        if !host.jumpHosts.isEmpty {
            parts.append(spokenJumpHosts(host.jumpHosts))
        }
        parts += host.host.portForwards.map(PortForwardDisplay.spokenSummary)
        parts.append(sshKey(host.sshKey))
        parts.append(origin(host))
        return parts.joined(separator: ". ")
    }

    // MARK: - Host keys

    /// A server as VoiceOver reads it: "localhost, port 2222".
    static func spokenServer(_ server: Server) -> String {
        "\(server.address), port \(server.port)"
    }

    /// The key's type and the line it is on: "ED25519, line 3".
    static func key(_ key: HostKey, line: Int) -> String {
        "\(key.typeName), line \(line)"
    }

    /// What a key that differs from the trusted one means, under it.
    static let conflictDetail =
        "Shello keeps the key it trusts. If the server’s key did change, connecting to it shows the change, "
        + "where you can replace the trusted key."

    // MARK: - Lines left out

    /// Which file and line: "config, line 12".
    static func place(_ item: OpenSSHImportPlan.NotImported) -> String {
        "\(fileName(item.file)), line \(item.line)"
    }

    static func fileName(_ file: OpenSSHImportPlan.File) -> String {
        switch file {
        case .config: "config"
        case .knownHosts: "known_hosts"
        }
    }

    /// The line's text as the row shows it, cut short after 160 characters: a key's base64 runs
    /// much longer.
    static func shownText(_ text: String) -> String {
        text.count > 160 ? text.prefix(160) + "…" : text
    }
}
