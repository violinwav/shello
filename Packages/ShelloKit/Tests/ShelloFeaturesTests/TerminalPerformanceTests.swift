import ShelloModel
import ShelloTerminalUI
import Synchronization
import XCTest
import os

@testable import ShelloFeatures

/// Printing 10 MB keeps input responsive (README section 16, STACK section 6), with each renderer,
/// CoreText and Metal, to choose between them by measurement (spike item 8).
///
/// The terminal demo prints its 10 MB output test while a key arrives every 100 ms, as from a fast
/// typist. Each key is timed from the moment it is queued on the main thread to the moment its byte
/// reaches the stream, the signpost interval "Keystroke"; the output test is "Output". Both are
/// measured with XCTOSSignpostMetric, and the keys' latencies are attached to the results.
///
/// The budget holds for the renderer Shello uses. It is loose, to catch a terminal that freezes
/// input on a slow CI runner rather than to time it: the numbers that matter come from devices and
/// Release builds (README section 16). The other renderer is measured for comparison only.
nonisolated final class TerminalPerformanceTests: XCTestCase {
    @MainActor
    func testTenMegabytesKeepInputResponsiveWithCoreText() {
        measureOutput(renderer: .coreText)
    }

    @MainActor
    func testTenMegabytesKeepInputResponsiveWithMetal() {
        measureOutput(renderer: .metal)
    }

    /// How long 95 % of keys may wait while 10 MB print, in the simulator.
    private static let latencyBudget = Duration.milliseconds(250)
    /// How long any key may wait: longer, and input froze. Input behind the whole output would
    /// wait several seconds; a busy CI runner can hold a single key for most of a second.
    private static let freezeBudget = Duration.seconds(2)

    @MainActor
    private func measureOutput(renderer: TerminalRenderer) {
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        var runs: [OutputRun] = []
        let metrics: [any XCTMetric] = [
            XCTOSSignpostMetric(subsystem: Signposts.subsystem, category: Signposts.category, name: "Keystroke"),
            XCTOSSignpostMetric(subsystem: Signposts.subsystem, category: Signposts.category, name: "Output"),
            XCTCPUMetric(),
            XCTMemoryMetric(),
        ]
        measure(metrics: metrics, options: options) {
            runs.append(printTenMegabytes(renderer: renderer))
        }

        let latencies = runs.flatMap(\.latencies).sorted()
        let summary = OutputRun.summary(of: runs, renderer: renderer)
        XCTContext.runActivity(named: summary) { activity in
            let attachment = XCTAttachment(string: summary)
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        Self.logger.notice("\(summary, privacy: .public)")
        XCTAssertGreaterThan(latencies.count, 50, "Too few keys arrived while the output printed")
        guard renderer == .standard, let slowest = latencies.last else { return }
        let p95 = latencies[latencies.count * 95 / 100]
        XCTAssertLessThan(p95, Self.latencyBudget, "Keys waited \(p95) behind the output")
        XCTAssertLessThan(slowest, Self.freezeBudget, "A key waited \(slowest) behind the output")
    }

    /// Prints the demo's 10 MB while keys arrive, and returns how long that took and how long
    /// each key waited.
    @MainActor
    private func printTenMegabytes(renderer: TerminalRenderer) -> OutputRun {
        DesignSystem.registerFonts()
        let controller = TerminalController(
            preferences: TerminalPreferences(), theme: .night, typeface: DesignSystem.terminalTypeface,
            renderer: renderer)
        let window = UIWindow.withoutScene(frame: CGRect(x: 0, y: 0, width: 390, height: 640))
        controller.view.frame = window.bounds
        window.addSubview(controller.view)
        controller.view.layoutIfNeeded()

        let keys = KeyLatencies()
        let printed = expectation(description: "The demo printed 10 MB")
        let stream = MeasuredDemo(keys: keys, printed: printed)
        controller.attach(stream)
        let deadline = Date.now.addingTimeInterval(10)
        while !controller.view.visibleRowsText(0..<10).contains(where: { $0.hasPrefix("demo$") }), Date.now < deadline {
            RunLoop.main.run(until: .now.addingTimeInterval(0.05))
        }

        let start = ContinuousClock.now
        let output = Signposts.signposter.beginInterval("Output")
        stream.demo.run(.flood)
        let typist = Typist(keys: keys) { [weak controller] in
            controller?.view.insertText("x")
        }
        typist.start()
        wait(for: [printed], timeout: 300)
        typist.stop()
        Signposts.signposter.endInterval("Output", output)
        let duration = ContinuousClock.now - start
        let frames = controller.view.diagnostics.frames
        controller.detach()
        return OutputRun(duration: duration, frames: frames, latencies: keys.latencies)
    }

    private static let logger = Logger(subsystem: Signposts.subsystem, category: Signposts.category)
}

nonisolated private enum Signposts {
    static let subsystem = "ch.shello.Shello"
    static let category = "TerminalPerformance"
    static let signposter = OSSignposter(subsystem: subsystem, category: category)
}

/// One run of the output test.
private struct OutputRun {
    let duration: Duration
    let frames: Int
    let latencies: [Duration]

    static func summary(of runs: [OutputRun], renderer: TerminalRenderer) -> String {
        let latencies = runs.flatMap(\.latencies).sorted()
        func percentile(_ fraction: Double) -> String {
            guard !latencies.isEmpty else { return "-" }
            let index = min(latencies.count - 1, Int(Double(latencies.count) * fraction))
            return milliseconds(latencies[index])
        }
        let durations = runs.map { String(format: "%.2f s", seconds($0.duration)) }.joined(separator: ", ")
        let frames = runs.map { String($0.frames) }.joined(separator: ", ")
        return "\(renderer == .metal ? "Metal" : "CoreText"): 10 MB in \(durations); frames \(frames); "
            + "\(latencies.count) keys, latency median \(percentile(0.5)), p95 \(percentile(0.95)), "
            + "max \(latencies.last.map(milliseconds) ?? "-")"
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func milliseconds(_ duration: Duration) -> String {
        String(format: "%.1f ms", seconds(duration) * 1000)
    }
}

/// The keys queued on the main thread, and when each reached the stream. Keys reach the stream in
/// the order they were queued: the main queue runs in order, and each key sends one byte.
nonisolated private final class KeyLatencies: Sendable {
    private struct State {
        var queued: [(interval: OSSignpostIntervalState, at: ContinuousClock.Instant)] = []
        var latencies: [Duration] = []
    }

    private let state = Mutex(State())

    func queued() {
        let interval = Signposts.signposter.beginInterval("Keystroke", id: Signposts.signposter.makeSignpostID())
        state.withLock { $0.queued.append((interval, .now)) }
    }

    func sent(_ count: Int) {
        let now = ContinuousClock.now
        let arrived = state.withLock { state in
            let arrived = state.queued.prefix(count)
            state.queued.removeFirst(arrived.count)
            state.latencies += arrived.map { now - $0.at }
            return Array(arrived)
        }
        for key in arrived {
            Signposts.signposter.endInterval("Keystroke", key.interval)
        }
    }

    var latencies: [Duration] { state.withLock { $0.latencies } }
}

/// The terminal demo, with its output and input watched: input is timed, and the end of the output
/// test fulfils `printed`.
nonisolated private final class MeasuredDemo: TerminalByteStream {
    let demo = TerminalDemo()
    let output: AsyncMapSequence<TerminalDemo.Output, [UInt8]>
    private let keys: KeyLatencies

    init(keys: KeyLatencies, printed: XCTestExpectation) {
        self.keys = keys
        output = demo.output.map { chunk in
            // The summary comes in a chunk of its own, after the 16 KiB chunks of the test.
            if chunk.count < 1024, String(decoding: chunk, as: UTF8.self).contains("Printed 10.0 MB") {
                printed.fulfill()
            }
            return chunk
        }
    }

    func send(_ bytes: [UInt8]) {
        keys.sent(bytes.count)
        demo.send(bytes)
    }

    func resize(to size: TerminalSize) {
        demo.resize(to: size)
    }
}

/// A key every 100 ms, queued on the main thread from a thread of its own, as key events arrive.
nonisolated private final class Typist: Sendable {
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "ch.shello.typist"))

    init(keys: KeyLatencies, type: @escaping @MainActor () -> Void) {
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler {
            keys.queued()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { type() }
            }
        }
    }

    func start() {
        timer.resume()
    }

    func stop() {
        timer.cancel()
    }
}
