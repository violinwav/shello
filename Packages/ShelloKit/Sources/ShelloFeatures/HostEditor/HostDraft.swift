import Foundation
import ShelloModel

/// The host editor's fields as the user edits them (README section 3). Text stays as typed until
/// the host is saved, so that a half-typed port is kept as it is.
struct HostDraft: Equatable {
    /// The fields that can have a problem.
    enum Field: Hashable, CaseIterable {
        case name
        case address
        case port
        case terminalType
    }

    /// Changing the protocol moves the port along while it is still the old protocol's default.
    var `protocol`: HostProtocol {
        didSet {
            if port == String(oldValue.defaultPort) {
                port = String(`protocol`.defaultPort)
            }
        }
    }
    var name: String
    var address: String
    var port: String
    var username: String
    var authMethod: AuthMethod
    /// The SSH key to sign in with, which may not be on this device (README section 15).
    var sshKeyID: UUID?
    var groupID: HostGroup.ID?
    var tagIDs: Set<Tag.ID>
    var notes: String
    var startupCommand: String
    var terminalType: String
    var keepaliveInterval: Duration
    var connectTimeout: Duration
    var isFavorite: Bool

    init(_ host: Host) {
        `protocol` = host.protocol
        name = host.name
        address = host.address
        port = String(host.port)
        username = host.username
        authMethod = host.authMethod
        sshKeyID = host.sshKeyID
        groupID = host.groupID
        tagIDs = host.tagIDs
        notes = host.notes
        startupCommand = host.startupCommand
        terminalType = host.terminalType
        keepaliveInterval = host.keepaliveInterval
        connectTimeout = host.connectTimeout
        isFavorite = host.isFavorite
    }

    /// A draft for a new host, with a new host's defaults.
    static var new: HostDraft {
        HostDraft(Host(name: "", address: "", username: ""))
    }

    /// The keepalive interval in whole seconds, for a stepper.
    var keepaliveSeconds: Int {
        get { Int(keepaliveInterval.components.seconds) }
        set { keepaliveInterval = .seconds(newValue) }
    }

    /// The connect timeout in whole seconds, for a stepper.
    var connectTimeoutSeconds: Int {
        get { Int(connectTimeout.components.seconds) }
        set { connectTimeout = .seconds(newValue) }
    }

    /// What is wrong with the draft, by field, as a sentence that says how to fix it. A draft
    /// without problems can be saved.
    var problems: [Field: String] {
        var problems: [Field: String] = [:]
        if name.trimmed.isEmpty {
            problems[.name] = "Enter a name."
        }
        let address = address.trimmed
        if address.isEmpty {
            problems[.address] = "Enter an address."
        } else if address.contains("@") {
            problems[.address] = "Enter the user in the User field."
        } else if AddressKind(of: address) == nil {
            problems[.address] = "Enter a hostname, an IPv4 address or an IPv6 address."
        }
        if port.trimmed.isEmpty {
            problems[.port] = "Enter a port."
        } else if portNumber == nil {
            problems[.port] = "Enter a port from 1 to 65535."
        }
        let terminalType = terminalType.trimmed
        if terminalType.isEmpty {
            problems[.terminalType] = "Enter a terminal type, such as xterm-256color."
        } else if terminalType.contains(where: \.isWhitespace) {
            problems[.terminalType] = "Enter the terminal type without spaces."
        }
        return problems
    }

    /// `base` with every field the user changed since `original` set to the draft's value. Text is
    /// saved without surrounding whitespace, except in the notes, where it may be deliberate.
    /// Fields the draft does not hold, such as when Shello last connected, keep `base`'s values.
    ///
    /// Pass the host as it is stored now as `base`: then saving never undoes a change made since
    /// the draft was taken. Call it on a draft without problems.
    func applied(to base: Host, comparedTo original: HostDraft) -> Host {
        var host = base
        if `protocol` != original.protocol { host.protocol = `protocol` }
        if name != original.name { host.name = name.trimmed }
        if address != original.address { host.address = address.trimmed }
        if port != original.port, let portNumber { host.port = portNumber }
        if username != original.username { host.username = username.trimmed }
        if authMethod != original.authMethod { host.authMethod = authMethod }
        if sshKeyID != original.sshKeyID { host.sshKeyID = sshKeyID }
        if groupID != original.groupID { host.groupID = groupID }
        if tagIDs != original.tagIDs { host.tagIDs = tagIDs }
        if notes != original.notes { host.notes = notes }
        if startupCommand != original.startupCommand { host.startupCommand = startupCommand.trimmed }
        if terminalType != original.terminalType { host.terminalType = terminalType.trimmed }
        if keepaliveInterval != original.keepaliveInterval { host.keepaliveInterval = keepaliveInterval }
        if connectTimeout != original.connectTimeout { host.connectTimeout = connectTimeout }
        if isFavorite != original.isFavorite { host.isFavorite = isFavorite }
        return host
    }

    /// The port, if it is written in ASCII digits and lies from 1 to 65535.
    private var portNumber: UInt16? {
        let text = port.trimmed
        guard text.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
            let number = UInt16(text), Host.validPorts.contains(number)
        else { return nil }
        return number
    }
}

extension String {
    fileprivate var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
