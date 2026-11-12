import Foundation
import ShelloSecurity
import Testing

@testable import ShelloFeatures

/// App lock (README section 13): at launch, and after app lock's timeout in the background, and not
/// before it.
@Suite(.timeLimit(.minutes(1)))
struct AppLockTests {
    let authentication = TestAuthentication()
    let time = TestTime()
    let settings = TestDefaults()
    let window: UnlockWindow

    init() {
        let time = time
        window = UnlockWindow(authentication: authentication, now: { time.now })
    }

    private func makeAppLock(isEnabled: Bool = true) -> AppLock {
        AppLock(window: window, defaults: settings.defaults, isEnabled: isEnabled)
    }

    /// Launches and unlocks, as the user does when Shello opens.
    private func unlockedAppLock() async -> AppLock {
        let appLock = makeAppLock()
        appLock.appDidBecomeActive()
        await waitUntil { !appLock.isLocked }
        return appLock
    }

    // MARK: - At launch

    @Test func isLockedAtLaunch() {
        let appLock = makeAppLock()

        #expect(appLock.isLocked)
        #expect(!window.isOpen)
        #expect(authentication.promptCount == 0)
    }

    @Test func asksAsSoonAsTheAppIsActiveAndUnlocks() async {
        let appLock = makeAppLock()

        appLock.appDidBecomeActive()
        await waitUntil { !appLock.isLocked }

        #expect(window.isOpen)
        #expect(authentication.promptCount == 1)
        #expect(appLock.problem == nil)
    }

    /// The prompt makes the app inactive, and active again once it closes: that must not ask again.
    @Test func asksOncePerLaunchNotEachTimeThePromptCloses() async {
        authentication.answer(.failure(.cancelled))
        let appLock = makeAppLock()

        appLock.appDidBecomeActive()
        await waitUntil { !appLock.isUnlocking && authentication.promptCount == 1 }
        appLock.appDidBecomeActive()
        appLock.appDidBecomeActive()

        #expect(appLock.isLocked)
        #expect(authentication.promptCount == 1)
    }

    @Test func cancelledUnlockStaysLockedWithoutAProblem() async {
        authentication.answer(.failure(.cancelled))
        let appLock = makeAppLock()

        await appLock.unlock()

        #expect(appLock.isLocked)
        #expect(appLock.problem == nil)
        #expect(!window.isOpen)
    }

    @Test func failedUnlockSaysWhyAndCanBeTriedAgain() async {
        authentication.answer(.failure(.failed))
        let appLock = makeAppLock()

        await appLock.unlock()
        #expect(appLock.isLocked)
        #expect(appLock.problem == "Shello couldn’t confirm that it’s you. Try again.")

        authentication.answer(.success(()))
        await appLock.unlock()
        #expect(!appLock.isLocked)
        #expect(appLock.problem == nil)
    }

    @Test func otherFailuresGiveLocalAuthenticationsCode() async {
        authentication.answer(.failure(.other(code: -1004)))
        let appLock = makeAppLock()

        await appLock.unlock()

        #expect(appLock.problem == "Shello couldn’t ask you to unlock (error -1004). Try again.")
    }

    // MARK: - After time in the background

    @Test func staysUnlockedWhenTheAppReturnsBeforeTheTimeout() async {
        let appLock = await unlockedAppLock()

        appLock.appDidEnterBackground()
        time.advance(by: .seconds(59))
        appLock.appDidBecomeActive()

        #expect(!appLock.isLocked)
        #expect(window.isOpen)
        #expect(authentication.promptCount == 1)
    }

    /// The default timeout is one minute.
    @Test func locksAndAsksWhenTheAppReturnsAfterTheTimeout() async {
        let appLock = await unlockedAppLock()

        appLock.appDidEnterBackground()
        time.advance(by: .seconds(60))
        appLock.appDidBecomeActive()

        // At once, before the first frame: the screens never show.
        #expect(appLock.isLocked)
        #expect(!window.isOpen)
        await waitUntil { !appLock.isLocked }
        #expect(authentication.promptCount == 2)
    }

    @Test(arguments: [AppLockTimeout.fiveMinutes, .fifteenMinutes])
    func locksOnlyOnceTheChosenTimeoutHasPassed(timeout: AppLockTimeout) async {
        let appLock = await unlockedAppLock()
        appLock.timeout = timeout

        appLock.appDidEnterBackground()
        time.advance(by: timeout.duration - .seconds(1))
        appLock.appDidBecomeActive()
        #expect(!appLock.isLocked)

        appLock.appDidEnterBackground()
        time.advance(by: timeout.duration)
        appLock.appDidBecomeActive()
        #expect(appLock.isLocked)
    }

    /// "Immediately" locks as the app leaves, so that the locked screen is up when the user comes back.
    @Test func immediatelyLocksAsTheAppGoesToTheBackground() async {
        let appLock = await unlockedAppLock()
        appLock.timeout = .immediately

        appLock.appDidEnterBackground()

        #expect(appLock.isLocked)
        #expect(!window.isOpen)
    }

    /// Returning to a locked app asks again, even if the user cancelled the last prompt.
    @Test func returningToALockedAppAsksAgain() async {
        authentication.answer(.failure(.cancelled))
        let appLock = makeAppLock()
        appLock.appDidBecomeActive()
        await waitUntil { !appLock.isUnlocking && authentication.promptCount == 1 }

        authentication.answer(.success(()))
        appLock.appDidEnterBackground()
        appLock.appDidBecomeActive()

        await waitUntil { !appLock.isLocked }
        #expect(authentication.promptCount == 2)
    }

    // MARK: - The setting

    @Test func timeoutIsOneMinuteUntilTheUserChoosesAnother() {
        #expect(makeAppLock().timeout == .oneMinute)
    }

    @Test func chosenTimeoutIsKept() {
        makeAppLock().timeout = .fiveMinutes

        #expect(makeAppLock().timeout == .fiveMinutes)
    }

    @Test func timeoutsGoFromImmediatelyToFifteenMinutes() {
        #expect(
            AppLockTimeout.allCases.map(\.displayName) == [
                "Immediately", "After 1 Minute", "After 5 Minutes", "After 15 Minutes",
            ])
        #expect(AppLockTimeout.allCases.map(\.duration) == [.zero, .seconds(60), .seconds(300), .seconds(900)])
    }

    // MARK: - Without anyone to ask

    @Test func deviceWithoutAPasscodeLetsTheUserIn() {
        authentication.setCapability(.passcodeNotSet)

        let appLock = makeAppLock()
        appLock.appDidBecomeActive()

        #expect(!appLock.isLocked)
        #expect(!appLock.canAsk)
        #expect(window.isOpen)
        #expect(authentication.promptCount == 0)
    }

    @Test func deviceWithoutAPasscodeStaysUnlockedAfterTheTimeout() {
        authentication.setCapability(.passcodeNotSet)
        let appLock = makeAppLock()

        appLock.appDidEnterBackground()
        time.advance(by: .seconds(3600))
        appLock.appDidBecomeActive()

        #expect(!appLock.isLocked)
        #expect(window.isOpen)
    }

    @Test func passcodeTurnedOffWhileLockedLetsTheUserIn() async {
        let appLock = makeAppLock()
        authentication.setCapability(.passcodeNotSet)

        await appLock.unlock()

        #expect(!appLock.isLocked)
        #expect(window.isOpen)
        #expect(authentication.promptCount == 0)
    }

    /// UI tests that are not about app lock turn it off.
    @Test func disabledAppLockNeverAsks() {
        let appLock = makeAppLock(isEnabled: false)

        appLock.appDidBecomeActive()
        appLock.appDidEnterBackground()
        time.advance(by: .seconds(3600))
        appLock.appDidBecomeActive()

        #expect(!appLock.isLocked)
        #expect(window.isOpen)
        #expect(authentication.promptCount == 0)
    }

    @Test func namesWhatTheDeviceAsksFor() {
        authentication.setCapability(.available(.touchID))
        #expect(makeAppLock().biometry == .touchID)

        authentication.setCapability(.available(.none))
        #expect(makeAppLock().biometry == .none)
        #expect(Biometry.none.displayName == "Passcode")
        #expect(Biometry.none.inSentence == "your passcode")
        #expect(Biometry.faceID.inSentence == "Face ID")
    }
}
