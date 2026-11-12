import Foundation
import Observation
import ShelloModel
import SwiftUI

/// Whether Shello has explained iOS's Local Network question (README section 3, TN3179). iOS asks the
/// question once, on the first connection to a server on the local network; Shello explains it just
/// before that connection, until the user continues once. Like the other settings of the device, it
/// stays out of the export.
///
/// A remote forward's destination is reached from this device too, as each connection the server
/// forwards comes in (README section 4): one on the local network brings the question then, so the
/// tab that will forward to it explains it before it connects.
@MainActor
@Observable
public final class LocalNetworkNotice {
    /// Whether the user has read the explanation and continued.
    public private(set) var isExplained: Bool

    private let defaults: UserDefaults
    private static let key = "localNetworkExplained"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isExplained = defaults.bool(forKey: Self.key)
    }

    /// What connecting along `route` should explain first, until the user has continued past the
    /// explanation: the route's first host, the only one Shello connects to from the device, when it
    /// looks local; or else a remote forward of the route's host, one that is on, whose destination
    /// looks local. A host behind a jump host is reached from the jump host's network, so its own
    /// address never counts, whatever it is (README section 3); a remote forward's destination is
    /// reached from this device, through jump hosts too.
    public func reason(connectingAlong route: Route) -> LocalNetworkReason? {
        guard !isExplained else { return nil }
        if route.firstHop.server.isOnLocalNetwork { return .server(route.firstHop) }
        return Self.localRemoteForward(of: route.host).map(LocalNetworkReason.remoteForward)
    }

    /// Whether connecting along `route` should first explain the question
    /// (`reason(connectingAlong:)`).
    public func explainsBeforeConnecting(along route: Route) -> Bool {
        reason(connectingAlong: route) != nil
    }

    /// Whether connecting to `host` should first explain the question: its server looks local and it
    /// is reached directly, or one of its remote forwards that is on goes to a destination that looks
    /// local, and the user has not continued past the explanation yet. For a host with jump hosts,
    /// `explainsBeforeConnecting(along:)` asks about its route's first host.
    public func explainsBeforeConnecting(to host: Host) -> Bool {
        !isExplained
            && ((host.jumpHostIDs.isEmpty && host.server.isOnLocalNetwork) || Self.localRemoteForward(of: host) != nil)
    }

    /// The user read the explanation and continued: iOS asks its question now, and the explanation is
    /// not needed again.
    public func markExplained() {
        isExplained = true
        defaults.set(true, forKey: Self.key)
    }

    /// The first of `host`'s remote forwards that is on and goes to a destination that looks local.
    private static func localRemoteForward(of host: Host) -> PortForward? {
        host.portForwards.first { forward in
            forward.isEnabled && forward.isRemote && forward.destination?.isOnLocalNetwork == true
        }
    }
}

/// Why connecting to a host brings iOS's Local Network question, which the Local Network sheet
/// explains first.
public enum LocalNetworkReason: Hashable, Sendable {
    /// The route's first host, which Shello connects to from the device, is on the local network: the
    /// host itself, or its first jump host.
    case server(Host)
    /// This remote forward of the host goes to a destination on the local network, which Shello
    /// connects to from the device for each connection the server forwards (README section 4).
    case remoteForward(PortForward)
}

/// The explanation of iOS's Local Network question, before the first connection to a server on the
/// local network (README section 3). Continue connects, which makes iOS ask; Not Now goes back. On a
/// route through jump hosts, the server is the first jump host's, which the sheet names, on the way
/// to the host that was connected to. For a remote forward, it is the forward's destination, which
/// iOS asks about once the first connection the server forwards comes in.
struct LocalNetworkSheet: View {
    let reason: LocalNetworkReason
    /// The host the connection is for.
    let host: Host
    let proceed: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        Text("\(address) is on your local network.")
                            .font(Typography.rowTitle)
                    } icon: {
                        Image(systemName: "network")
                            .foregroundStyle(Palette.accentInk)
                    }
                    .labelStyle(.row)
                    switch reason {
                    case .server(let firstHop):
                        if firstHop.id != host.id {
                            Text(
                                "It’s the jump host \(firstHop.name), which Shello connects to first, on the way to "
                                    + "\(host.name).")
                        }
                        Text(
                            "To reach it, Shello needs access to your local network. iOS asks you for it once, as soon "
                                + "as you continue.")
                    case .remoteForward(let forward):
                        Text(
                            "It’s where \(host.name)’s remote forward from the server’s port \(forward.port) goes: Shello "
                                + "connects to it for each connection the server forwards.")
                        Text(
                            "To reach it, Shello needs access to your local network. iOS asks you for it once, when the "
                                + "server forwards the first connection.")
                    }
                    Text(
                        "Choose Allow. If you don’t, Shello can’t reach servers on your local network until you turn "
                            + "on Local Network for Shello in Settings, under Privacy & Security.")
                } footer: {
                    FooterText(footer)
                }
                .listRowBackground(Palette.cell)
            }
            .font(Typography.body)
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            .navigationTitle("Local Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now", systemImage: "xmark", role: .cancel, action: cancel)
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue", systemImage: "arrow.right", role: .confirm, action: proceed)
                        .prominentToolbarButton()
                }
            }
        }
    }

    /// The address on the local network.
    private var address: String {
        switch reason {
        case .server(let firstHop): firstHop.address
        case .remoteForward(let forward): forward.destination?.address ?? ""
        }
    }

    private var footer: String {
        switch reason {
        case .server: "Shello connects only to the servers you add as hosts."
        case .remoteForward:
            "Shello connects only to the servers you add as hosts, and to their forwards’ destinations."
        }
    }
}
