import SwiftUI

/// The app's first screen. The host list (README section 3) replaces it.
public struct RootView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "apple.terminal")
                .font(.largeTitle)
                .accessibilityHidden(true)
            Text("Shello")
                .font(.title.bold())
            Text("Development build. Nothing to connect to yet.")
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

#Preview {
    RootView()
}
