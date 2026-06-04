//
//  stream_coordinator_restart_tests.swift
//  DeskPadTests
//
//  @agents-index Asserts the CR-0001 Phase 2 Test Strategy row
//  `testRestartBackoffSchedule`: bounded exponential backoff capped at 5 s
//  with at most 10 attempts; the eleventh restart never fires.
//

import Foundation
import XCTest

@testable import DeskPad

/// Fake `StreamClock` that records every requested sleep interval and
/// resumes immediately so the test runs in microseconds. Thread-safe via an
/// actor; the coordinator awaits each `sleep` call so the recorded ordering
/// matches the schedule.
private actor RecordingClock: StreamClock {
    private(set) var recordedIntervals: [Double] = []

    func sleep(seconds: Double) async throws {
        recordedIntervals.append(seconds)
    }

    func snapshot() -> [Double] { recordedIntervals }
}

final class StreamCoordinatorRestartTests: XCTestCase {
    /// `testRestartBackoffSchedule` — verifies the per-attempt delays match
    /// 0.1, 0.2, 0.4, 0.8, 1.6, 3.2, 5.0, 5.0, 5.0, 5.0 and that no eleventh
    /// attempt is scheduled.
    func testRestartBackoffSchedule() async throws {
        let clock = RecordingClock()
        let coordinator = StreamCoordinator(clock: clock)
        try await coordinator.runRestartScheduleForTest()

        let intervals = await clock.snapshot()
        let expected: [Double] = [0.1, 0.2, 0.4, 0.8, 1.6, 3.2, 5.0, 5.0, 5.0, 5.0]
        XCTAssertEqual(intervals.count, expected.count)
        for (got, want) in zip(intervals, expected) {
            XCTAssertEqual(got, want, accuracy: 0.0001)
        }

        let terminalState = await coordinator.state
        XCTAssertEqual(terminalState, .failed)
    }

    /// Pure-function check on the backoff helper; ensures the cap and the
    /// growth rule are independently asserted, not only via the full run.
    func testBackoffDelayCaps() {
        XCTAssertEqual(StreamCoordinator.backoffDelay(forAttempt: 1), 0.1, accuracy: 0.0001)
        XCTAssertEqual(StreamCoordinator.backoffDelay(forAttempt: 7), 5.0, accuracy: 0.0001)
        XCTAssertEqual(StreamCoordinator.backoffDelay(forAttempt: 99), 5.0, accuracy: 0.0001)
        XCTAssertEqual(StreamCoordinator.backoffDelay(forAttempt: 0), 0.0, accuracy: 0.0001)
    }
}
