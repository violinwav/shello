import SwiftUI

/// The screen the app shows instead of the host list when its database cannot be opened, for
/// example because the app is not signed with its App Group, or a newer Shello migrated the data.
public struct DatabaseUnavailableView: View {
    private let error: any Error

    public init(error: any Error) {
        self.error = error
    }

    public var body: some View {
        EmptyStateView(
            title: "Shello Can’t Open Its Database", systemImage: "externaldrive.badge.exclamationmark",
            description: String(describing: error)
        )
        .font(Typography.body)
        .background(Palette.ground)
    }
}
