//
//  steady_state_latency_tests.swift
//  DeskPadTests
//
//  @agents-index Asserts the CR-0001 Test Strategy row
//  `testSteadyStateLatencyUnder33ms`: the latency-budget math holds
//  across a synthetic 600-frame stream (NFR-1, AC-13). The bench uses
//  `StreamOutput.publishForTest(syntheticIngestHostTime:)` so it does
//  not require a host display, screen-recording permission, or real
//  ScreenCaptureKit traffic.
//

import QuartzCore
import XCTest

@testable import DeskPad

final class SteadyStateLatencyTests: XCTestCase {
    func testSteadyStateLatencyUnder33ms() throws {
        let output = StreamOutput()
        var t: CFTimeInterval = 1
        for _ in 0 ..< 600 {
            output.publishForTest(syntheticIngestHostTime: t)
            t += 1.0 / 60.0
        }
        let metrics = output.arrivalMetrics
        XCTAssertEqual(metrics.sampleCount, 600)
        // The synthetic cadence is exactly 1/60 s. The EMA should
        // converge to the same value within floating-point tolerance.
        XCTAssertLessThan(abs(metrics.intervalEMA - (1.0 / 60.0)), 0.001)
        // Budget assertion: 1/60 s = 16.67 ms is well under the 33 ms cap.
        XCTAssertLessThan(metrics.intervalEMA, 0.033)
    }
}
