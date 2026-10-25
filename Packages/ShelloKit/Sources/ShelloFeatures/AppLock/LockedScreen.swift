import ShelloSecurity
import SwiftUI

/// What Shello shows while app lock is engaged: the logo, that Shello is locked, and Unlock. Why the
/// last unlock failed, if it did, shows under the title.
struct LockedScreen: View {
    let appLock: AppLock
    @ScaledMetric(relativeTo: .title) private var logoSize = 72

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 20) {
                    ShelloLogo()
                        .frame(width: logoSize, height: logoSize)
                        .accessibilityHidden(true)
                    Text("Shello Is Locked")
                        .font(Typography.title)
                        .foregroundStyle(Palette.textPrimary)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    if let problem = appLock.problem {
                        ProblemText(problem: problem)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("Unlock with \(appLock.biometry.inSentence) to see your hosts.")
                            .font(Typography.body)
                            .foregroundStyle(Palette.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    // A short title, which stays on one line at every text size: a longer one wraps
                    // into the capsule's rounded ends.
                    Button {
                        Task { await appLock.unlock() }
                    } label: {
                        Label("Unlock", systemImage: appLock.biometry.symbolName)
                            .font(Typography.rowTitle)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accentFill()
                    // The sentence that names it gives way to a problem.
                    .accessibilityHint("Asks for \(appLock.biometry.inSentence).")
                    .keyboardShortcut(.defaultAction)
                    .disabled(appLock.isUnlocking)
                    .padding(.top, 8)
                }
                .padding(24)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Palette.ground)
        // The problem replaces the sentence while VoiceOver is back on the title or Unlock.
        .onChange(of: appLock.problem) { _, problem in
            if let problem { announce(problem) }
        }
    }
}

/// What the app switcher shows of Shello whenever its scene is not active: the logo on the ground,
/// and nothing of the screens or sheets below (README section 13).
public struct PrivacyCover: View {
    @ScaledMetric(relativeTo: .title) private var logoSize = 72

    public init() {}

    public var body: some View {
        ShelloLogo()
            .frame(width: logoSize, height: logoSize)
            .accessibilityElement()
            .accessibilityLabel("Shello")
            .accessibilityAddTraits(.isImage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.ground)
    }
}

extension Biometry {
    /// The SF Symbol of what the device asks for.
    var symbolName: String {
        switch self {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        case .none: "lock.open"
        }
    }
}
