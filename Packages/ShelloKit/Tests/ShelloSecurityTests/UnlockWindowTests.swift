import Foundation
import LocalAuthentication
import Testing

@testable import ShelloSecurity

/// The unlock window (README section 13): one authentication, one context, until app lock
/// re-engages.
struct UnlockWindowTests {
    let authentication = TestAuthentication()
    let time = TestTime()
    let window: UnlockWindow

    init() {
        let time = time
        window = UnlockWindow(authentication: authentication, now: { time.now })
    }

    @Test func startsClosed() {
        #expect(!window.isOpen)
        #expect(throws: UnlockWindowClosed.self) { try window.withAuthenticationContext { _ in } }
        #expect(authentication.promptCount == 0)
    }

    @Test func opensWhenTheUserAuthenticates() async throws {
        try await window.open(reason: "Unlock Shello")

        #expect(window.isOpen)
        #expect(authentication.promptCount == 1)
        #expect(authentication.reasons == ["Unlock Shello"])
    }

    /// Everything inside the window gets the one context the user authenticated on, and that
    /// context can ask nothing more.
    @Test func handsOutTheContextTheUserAuthenticatedOn() async throws {
        try await window.open(reason: "Unlock Shello")

        let contexts = try (0..<3).map { _ in
            try window.withAuthenticationContext { ObjectIdentifier($0) }
        }
        let interactionNotAllowed = try window.withAuthenticationContext { $0.interactionNotAllowed }

        #expect(contexts == Array(repeating: authentication.promptedContexts[0], count: 3))
        #expect(interactionNotAllowed)
        #expect(authentication.promptCount == 1)
    }

    @Test(arguments: [UnlockError.cancelled, .failed, .other(code: -1004)])
    func staysClosedWhenTheUserDoesNotAuthenticate(error: UnlockError) async {
        authentication.answer(.failure(error))

        await #expect(throws: error) { try await window.open(reason: "Unlock Shello") }

        #expect(!window.isOpen)
        #expect(authentication.isInvalidated(authentication.promptedContexts[0]))
    }

    @Test func closingInvalidatesTheContext() async throws {
        try await window.open(reason: "Unlock Shello")
        let context = authentication.promptedContexts[0]

        window.close()

        #expect(!window.isOpen)
        #expect(authentication.isInvalidated(context))
        #expect(throws: UnlockWindowClosed.self) { try window.withAuthenticationContext { _ in } }
    }

    /// App lock re-engaging means a new prompt and a new context.
    @Test func reopeningAsksAgainForANewContext() async throws {
        try await window.open(reason: "Unlock Shello")
        window.close()

        try await window.open(reason: "Unlock Shello")

        #expect(authentication.promptCount == 2)
        let current = try window.withAuthenticationContext { ObjectIdentifier($0) }
        #expect(current == authentication.promptedContexts[1])
        #expect(current != authentication.promptedContexts[0])
    }

    @Test func unlockingAgainReplacesAndInvalidatesTheOpenContext() async throws {
        try await window.open(reason: "Unlock Shello")

        try await window.open(reason: "Unlock Shello")

        #expect(authentication.isInvalidated(authentication.promptedContexts[0]))
        #expect(try window.withAuthenticationContext { ObjectIdentifier($0) } == authentication.promptedContexts[1])
    }

    // MARK: - Time in the background

    @Test func staysOpenWhenTheAppReturnsBeforeTheTimeout() async throws {
        try await window.open(reason: "Unlock Shello")

        window.closeAfter(.seconds(60))
        time.advance(by: .seconds(59))

        #expect(window.stayOpen())
        time.advance(by: .seconds(3600))
        #expect(window.isOpen)
    }

    @Test func closesOnceTheAppHasBeenAwayForTheTimeout() async throws {
        try await window.open(reason: "Unlock Shello")
        let context = authentication.promptedContexts[0]

        window.closeAfter(.seconds(60))
        time.advance(by: .seconds(60))

        #expect(!window.stayOpen())
        #expect(authentication.isInvalidated(context))
    }

    /// Code that runs before the interface has noticed the timeout finds the window closed too.
    @Test func timeoutClosesTheWindowForEveryoneWithoutWaitingForTheInterface() async throws {
        try await window.open(reason: "Unlock Shello")
        window.closeAfter(.seconds(300))

        time.advance(by: .seconds(301))

        #expect(throws: UnlockWindowClosed.self) { try window.withAuthenticationContext { _ in } }
        #expect(!window.isOpen)
    }

    @Test func zeroTimeoutClosesAtOnce() async throws {
        try await window.open(reason: "Unlock Shello")

        window.closeAfter(.zero)

        #expect(!window.isOpen)
        #expect(authentication.isInvalidated(authentication.promptedContexts[0]))
    }

    @Test func countdownOfAClosedWindowDoesNothing() {
        window.closeAfter(.seconds(60))
        time.advance(by: .seconds(61))

        #expect(!window.stayOpen())
        #expect(authentication.promptCount == 0)
    }

    // MARK: - Devices without a passcode

    @Test func deviceWithoutAPasscodeCannotAsk() async {
        authentication.setCapability(.passcodeNotSet)

        await #expect(throws: UnlockError.passcodeNotSet) { try await window.open(reason: "Unlock Shello") }

        #expect(window.capability == .passcodeNotSet)
        #expect(authentication.promptCount == 0)
        #expect(!window.isOpen)
    }

    @Test func opensWithoutAuthenticationOnAContextThatCannotAsk() throws {
        window.openWithoutAuthentication()

        #expect(window.isOpen)
        #expect(authentication.promptCount == 0)
        #expect(try window.withAuthenticationContext { $0.interactionNotAllowed })
    }

    @Test func reportsWhatTheDeviceAsksFor() {
        authentication.setCapability(.available(.touchID))

        #expect(window.capability == .available(.touchID))
    }
}

/// An unlock that is still asking the user when app lock re-engages is thrown away.
struct UnlockWindowRaceTests {
    @Test func closingWhileTheUserIsAskedCancelsTheUnlock() async throws {
        let authentication = SlowAuthentication()
        let window = UnlockWindow(authentication: authentication)

        let unlock = Task { try await window.open(reason: "Unlock Shello") }
        await authentication.waitUntilAsking()
        window.close()
        authentication.finish()

        await #expect(throws: UnlockError.cancelled) { try await unlock.value }
        #expect(!window.isOpen)
    }
}

/// An authentication whose prompt stays up until the test ends it.
private final class SlowAuthentication: Authentication {
    private let asking = AsyncStream<Void>.makeStream()
    private let answers = AsyncStream<Void>.makeStream()

    func makeContext() -> sending LAContext { LAContext() }

    func capability(of context: LAContext) -> AuthenticationCapability { .available(.faceID) }

    func authenticate(_ context: LAContext, reason: String) async throws(UnlockError) {
        asking.continuation.yield()
        for await _ in answers.stream { return }
    }

    func invalidate(_ context: LAContext) {}

    func waitUntilAsking() async {
        for await _ in asking.stream { return }
    }

    func finish() {
        answers.continuation.yield()
    }
}
