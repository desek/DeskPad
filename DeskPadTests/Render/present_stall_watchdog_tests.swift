//
//  present_stall_watchdog_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0003 Phase 2 / AC-11 closure: exercises
//  `PresentStallWatchdog` against the five emission rules from FR-6:
//  no-emit when both counters advance, no-emit when neither advances,
//  one-emit when ingested advances and presented stalls for the full
//  three-second window, at-most-one-per-ten-seconds rate limit, and
//  no-emit outside `.running`. The watchdog is driven via its
//  injectable host-time seam so the tests complete in microseconds.
//

import XCTest

@testable import DeskPad

@MainActor
final class PresentStallWatchdogTests: XCTestCase {
    /// Mutable triple the test's sample-provider closure returns. Each
    /// test drives the watchdog by mutating these and calling
    /// `tick(now:)` with simulated host-time values.
    private final class Sampler {
        var ingested: Int = 0
        var presented: Int = 0
        var state: CaptureRenderCoordinatorState = .running
        func sample() -> PresentStallSample {
            PresentStallSample(ingested: ingested, presented: presented, state: state)
        }
    }

    /// Drive ticks at one-second cadence across a wall-clock window so
    /// the watchdog's three-second baseline rotation matches the
    /// production loop's behaviour. The mutator runs *before* each
    /// tick so callers can advance counters frame-by-frame.
    private func tickWindow(
        watchdog: PresentStallWatchdog,
        seconds: Int,
        start: Double = 0,
        mutator: (Int) -> Void
    ) {
        for i in 0 ..< seconds {
            mutator(i)
            watchdog.tick(now: start + Double(i))
        }
    }

    func testNoEmissionWhenBothCountersAdvance() {
        let sampler = Sampler()
        let log = TestLogCapture.install(category: "watchdog-both")
        let watchdog = PresentStallWatchdog(sampleProvider: sampler.sample, log: log.logger)
        tickWindow(watchdog: watchdog, seconds: 8) { i in
            sampler.ingested = i + 1
            sampler.presented = i + 1
        }
        XCTAssertEqual(log.lines.count, 0)
    }

    func testNoEmissionWhenNeitherAdvances() {
        let sampler = Sampler()
        let log = TestLogCapture.install(category: "watchdog-flat")
        let watchdog = PresentStallWatchdog(sampleProvider: sampler.sample, log: log.logger)
        tickWindow(watchdog: watchdog, seconds: 8) { _ in /* counters flat */ }
        XCTAssertEqual(log.lines.count, 0)
    }

    func testEmitsOnceWhenIngestAdvancesButPresentStalls() {
        let sampler = Sampler()
        let log = TestLogCapture.install(category: "watchdog-stall")
        let watchdog = PresentStallWatchdog(sampleProvider: sampler.sample, log: log.logger)
        // Seven ticks at one-second cadence: ingest advances every
        // tick; presented stays at zero. The baseline rotates at t=3
        // and again at t=6, so we expect exactly one WARN before the
        // ten-second rate-limit window opens a second slot.
        tickWindow(watchdog: watchdog, seconds: 7) { i in
            sampler.ingested = i + 1
        }
        XCTAssertEqual(log.lines.count, 1, "lines=\(log.lines)")
        XCTAssertTrue(log.lines[0].contains("present stall: ingested="))
    }

    func testRateLimitedToOnceEvery10Seconds() {
        let sampler = Sampler()
        let log = TestLogCapture.install(category: "watchdog-ratelimit")
        let watchdog = PresentStallWatchdog(sampleProvider: sampler.sample, log: log.logger)
        // 25 seconds of sustained stall: ingest advances every tick,
        // presented never. The watchdog rotates its three-second
        // baseline at t=3,6,9,... so a candidate emission would fire
        // at each rotation; the ten-second rate limit caps the total
        // to at most three lines (t~=3, t~=13, t~=23).
        tickWindow(watchdog: watchdog, seconds: 25) { i in
            sampler.ingested = i + 1
        }
        XCTAssertLessThanOrEqual(log.lines.count, 3, "lines=\(log.lines)")
        XCTAssertGreaterThanOrEqual(log.lines.count, 1, "expected at least one stall line")
    }

    func testNoEmissionOutsideRunningState() {
        let sampler = Sampler()
        sampler.state = .restarting(attempt: 1)
        let log = TestLogCapture.install(category: "watchdog-not-running")
        let watchdog = PresentStallWatchdog(sampleProvider: sampler.sample, log: log.logger)
        tickWindow(watchdog: watchdog, seconds: 8) { i in
            sampler.ingested = i + 1
        }
        XCTAssertEqual(log.lines.count, 0)
    }
}

/// Captures warn-level lines emitted through a real `Logger` so the
/// watchdog's exact log format (the `present stall: ingested=` prefix
/// per FR-7) can be asserted without parsing the rotating file sink.
/// The capture reads the file-sink log file before and after the test
/// run; an alternative would be a logger fake, but going through the
/// real logger also exercises the `filename:line` prefix and warn
/// level routing required by FR-7.
@MainActor
final class TestLogCapture {
    let logger: Logger
    private let category: String
    private let baselineCount: Int

    private init(category: String) {
        self.category = category
        logger = Logger(category: category)
        baselineCount = Self.readLines(matching: category).count
    }

    static func install(category: String) -> TestLogCapture {
        TestLogCapture(category: category)
    }

    /// Lines written *to the file sink* by the test's logger since
    /// `install(...)`, filtered by category so concurrent tests do not
    /// see each other's lines.
    var lines: [String] {
        let all = Self.readLines(matching: category)
        guard all.count > baselineCount else { return [] }
        return Array(all[baselineCount...])
    }

    private static func readLines(matching category: String) -> [String] {
        LogFileSink.shared._flushForTesting()
        guard let url = try? LogFileSink.shared._activeFileURLForTesting() else { return [] }
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.contains("[\(category)]") }
    }
}
