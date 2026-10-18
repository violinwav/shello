import ShelloFeatures
import SwiftUI

/// Composition root. Services are created here and passed to the screens through the SwiftUI environment.
@main
struct ShelloApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
