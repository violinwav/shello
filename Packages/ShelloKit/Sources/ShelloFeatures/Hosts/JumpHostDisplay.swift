import Foundation
import ShelloModel

// How jump hosts and routes (README section 3) read on screen and to VoiceOver.

enum JumpHostDisplay {
    /// A jump host that Shello does not have, as a list of jump hosts names it: one that was
    /// deleted, or that an import left out.
    static let missingName = "Missing host"

    /// What a missing jump host's row says under its name.
    static let missingDetail = "Deleted, or not in Shello"

    /// The names of the hosts `ids`, among `hosts`, a missing one as `missingName`.
    static func names(of ids: [Host.ID], among hosts: [Host.ID: Host]) -> [String] {
        ids.map { hosts[$0]?.name ?? missingName }
    }

    /// Names in their order, as the screen shows them: "bastion → inner".
    static func shown(_ names: [String]) -> String {
        names.joined(separator: " → ")
    }

    /// Names in their order, as VoiceOver reads them: "bastion, then inner", where it would read the
    /// arrow as "right arrow".
    static func spoken(_ names: [String]) -> String {
        names.joined(separator: ", then ")
    }

    /// The host named `name` with the jump hosts it is reached through, as the texts about a whole
    /// route name it: "web-01 through bastion, then inner". Without jump hosts, its name alone.
    static func host(_ name: String, through jumpHosts: [String]) -> String {
        jumpHosts.isEmpty ? name : "\(name) through \(spoken(jumpHosts))"
    }

    /// The most hosts that a deletion's confirmation names: more would make a long message to read,
    /// and to scroll at large text sizes.
    static let namedUsersLimit = 3

    /// The confirmation's message for deleting a host that `users` connect through: they keep it as
    /// a missing jump host, and do not connect until their jump hosts change, rather than connect
    /// directly. What happens comes first; beyond `namedUsersLimit` hosts, it counts the rest.
    static func deletionMessage(users: [Host]) -> String {
        let removes = "This removes the host from Shello."
        guard let first = users.first else { return removes }
        if users.count == 1 {
            return "\(removes) \(first.name) connects through it, and keeps it as a missing jump host: \(first.name) "
                + "doesn’t connect until you change its jump hosts."
        }
        let consequence =
            "connect through it, and keep it as a missing jump host: they don’t connect until you change "
            + "their jump hosts."
        guard users.count > namedUsersLimit else {
            return "\(removes) \(users.map(\.name).formatted(.list(type: .and))) \(consequence)"
        }
        let others = users.count - namedUsersLimit
        let named = users.prefix(namedUsersLimit).map(\.name) + ["\(others) other\(others == 1 ? "" : "s")"]
        return "\(removes) \(users.count) hosts \(consequence) They are \(named.formatted(.list(type: .and)))."
    }
}

extension RouteError {
    /// Whether the host editor refuses to save the jump hosts for it. A missing jump host only says
    /// so: the list keeps it, as the deletion's confirmation said, and undoing the deletion brings it
    /// back.
    var blocksSaving: Bool {
        if case .missingJumpHost = self { false } else { true }
    }

    /// The problem as the host editor says it under the jump hosts of the host it edits, named
    /// `hostName`, in a sentence that says what to change.
    func editorProblem(editing hostName: String) -> String {
        switch self {
        case .missingJumpHost(let host) where host == hostName:
            "One of these jump hosts was deleted. Remove it: until then, Shello doesn’t connect to this host."
        case .missingJumpHost(let host):
            "One of \(host)’s jump hosts was deleted. Change \(host)’s jump hosts: until then, Shello doesn’t connect "
                + "to this host."
        case .repeatsHost(let host):
            "The route goes through \(host) twice. Choose jump hosts that reach each host once."
        case .tooManyJumpHosts:
            "The route goes through more than \(Route.maximumJumpHosts) jump hosts. Remove some, here or from the "
                + "first jump host’s."
        case .notSSH(let host):
            "\(host) isn’t an SSH host, so it can’t be a jump host. Remove it, or make it an SSH host."
        }
    }

    /// The problem as a host's details say it under its route, for the host named `hostName`.
    func detailProblem(of hostName: String) -> String {
        switch self {
        case .missingJumpHost(let host) where host == hostName:
            "One of its jump hosts was deleted. Shello doesn’t connect to this host until you change its jump hosts."
        case .missingJumpHost(let host):
            "One of \(host)’s jump hosts was deleted. Shello doesn’t connect to this host until you change \(host)’s "
                + "jump hosts."
        case .repeatsHost, .tooManyJumpHosts, .notSSH:
            description
        }
    }
}
