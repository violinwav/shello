/// How long Shello may stay in the background before app lock re-engages and the unlock window
/// closes (README section 13): from immediately to 15 minutes, 1 minute unless the user changes it.
public enum AppLockTimeout: Int, CaseIterable, Identifiable, Sendable {
    // Raw values are seconds, as Shello stores the setting.
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    /// The timeout until the user chooses another.
    public static let standard = AppLockTimeout.oneMinute

    public var id: Self { self }

    public var duration: Duration { .seconds(rawValue) }
}
