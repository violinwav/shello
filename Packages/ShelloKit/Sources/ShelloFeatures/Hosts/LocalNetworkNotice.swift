import Foundation
import Observation
import ShelloModel
import SwiftUI

/// Whether Shello has explained iOS's Local Network question (README section 3, TN3179). iOS asks the
/// question once, on the first connection to a server on the local network; Shello explains it just
/// before that connection, until the user continues once. Like the other settings of the device, it
/// stays out of the export.
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

    /// Whether connecting to `host` should first explain the question: its server looks local, and
    /// the user has not continued past the explanation yet.
    public func explainsBeforeConnecting(to host: Host) -> Bool {
        !isExplained && host.server.isOnLocalNetwork
    }

    /// The user read the explanation and continued: iOS asks its question now, and the explanation is
    /// not needed again.
    public func markExplained() {
        isExplained = true
        defaults.set(true, forKey: Self.key)
    }
}

/// The explanation of iOS's Local Network question, before the first connection to a server on the
/// local network (README section 3). Continue connects, which makes iOS ask; Not Now goes back.
struct LocalNetworkSheet: View {
    let host: Host
    let proceed: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        Text("\(host.address) is on your local network.")
                            .font(Typography.rowTitle)
                    } icon: {
                        Image(systemName: "network")
                            .foregroundStyle(Palette.accentInk)
                    }
                    .labelStyle(.row)
                    Text(
                        "To reach it, Shello needs access to your local network. iOS asks you for it once, as soon as "
                            + "you continue.")
                    Text(
                        "Choose Allow. If you don’t, Shello can’t reach servers on your local network until you turn on "
                            + "Local Network for Shello in Settings, under Privacy & Security.")
                } footer: {
                    FooterText("Shello connects only to the servers you add as hosts.")
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
}
