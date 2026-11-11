import Foundation
import ShelloModel

/// A port forward as the host editor's Port Forward screen edits it (README section 4). Text stays as
/// typed until the host is saved, as in `HostDraft`, and a local forward's destination stays while
/// the kind is dynamic, so that switching back finds it.
struct PortForwardDraft: Identifiable, Equatable {
    /// What the forward does with each connection: the kinds of `PortForward.Kind`, without their
    /// values.
    enum Kind: Hashable, CaseIterable {
        case local
        case dynamic
    }

    /// The fields that can have a problem, in the screen's order.
    enum Field: Hashable, CaseIterable {
        case localPort
        case destinationAddress
        case destinationPort
    }

    let id: UUID
    var kind: Kind
    var name: String
    var localPort: String
    var destinationAddress: String
    var destinationPort: String
    var isEnabled: Bool

    init(_ forward: PortForward) {
        id = forward.id
        name = forward.name
        localPort = String(forward.localPort)
        isEnabled = forward.isEnabled
        switch forward.kind {
        case .local(let destination):
            kind = .local
            destinationAddress = destination.address
            destinationPort = String(destination.port)
        case .dynamic:
            kind = .dynamic
            destinationAddress = ""
            destinationPort = ""
        }
    }

    /// A new local forward, on, with its fields empty.
    static var new: PortForwardDraft {
        var draft = PortForwardDraft(
            PortForward(localPort: 1, kind: .local(destination: ForwardDestination(address: "", port: 1))))
        draft.localPort = ""
        draft.destinationPort = ""
        return draft
    }

    /// What is wrong with the draft, by field, as a sentence that says how to fix it. The
    /// destination counts for a local forward only.
    var problems: [Field: String] {
        var problems: [Field: String] = [:]
        if localPort.trimmed.isEmpty {
            problems[.localPort] = "Enter the port to listen on."
        } else if Self.port(localPort) == nil {
            problems[.localPort] = "Enter a port from 1 to 65535."
        }
        guard kind == .local else { return problems }
        let address = Self.address(destinationAddress)
        if address.isEmpty {
            problems[.destinationAddress] = "Enter the address the server connects to, such as localhost."
        } else if AddressKind(of: address) == nil {
            problems[.destinationAddress] = "Enter a hostname, an IPv4 address or an IPv6 address."
        }
        if destinationPort.trimmed.isEmpty {
            problems[.destinationPort] = "Enter the port the server connects to."
        } else if Self.port(destinationPort) == nil {
            problems[.destinationPort] = "Enter a port from 1 to 65535."
        }
        return problems
    }

    /// The port it listens on, once it is one.
    var listeningPort: UInt16? { Self.port(localPort) }

    /// The forward the draft describes, without surrounding whitespace; nil while it has a problem.
    var forward: PortForward? {
        guard problems.isEmpty, let listening = Self.port(localPort) else { return nil }
        let kind: PortForward.Kind
        switch self.kind {
        case .local:
            guard let port = Self.port(destinationPort) else { return nil }
            kind = .local(destination: ForwardDestination(address: Self.address(destinationAddress), port: port))
        case .dynamic:
            kind = .dynamic
        }
        return PortForward(id: id, name: name.trimmed, localPort: listening, kind: kind, isEnabled: isEnabled)
    }

    /// The port in `text`, if it is written in ASCII digits and lies from 1 to 65535.
    private static func port(_ text: String) -> UInt16? {
        let text = text.trimmed
        guard text.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
            let number = UInt16(text), PortForward.validPorts.contains(number)
        else { return nil }
        return number
    }

    /// The address as typed, without surrounding whitespace, and without the brackets an IPv6
    /// address is written in beside a port, as in `[fd00::5]`.
    private static func address(_ text: String) -> String {
        let address = text.trimmed
        guard address.hasPrefix("["), address.hasSuffix("]"), address.count > 2 else { return address }
        return String(address.dropFirst().dropLast())
    }
}

extension String {
    fileprivate var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
