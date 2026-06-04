//
//  stream_configuration_tests.swift
//  DeskPadTests
//
//  @agents-index Asserts the CR-0001 Phase 2 Test Strategy row
//  `testStreamConfigurationDefaults`: BGRA, queueDepth in {2,3},
//  showsCursor, and mode-selected minimumFrameInterval.
//

import CoreMedia
import CoreVideo
import ScreenCaptureKit
import XCTest

@testable import DeskPad

final class StreamConfigurationTests: XCTestCase {
    /// `testStreamConfigurationDefaults` — verifies BGRA pixel format,
    /// queueDepth bounded to {2,3}, showsCursor true, and mode-selected
    /// minimumFrameInterval (panel max in low-latency mode, 1/60 in power-
    /// saving mode).
    func testStreamConfigurationDefaults() {
        let factory = StreamConfigurationFactory()
        let lowLatency = factory.makeConfiguration(
            resolution: CGSize(width: 1920, height: 1080),
            scaleFactor: 2,
            mode: .lowLatency(panelMaxRefreshHz: 120)
        )
        XCTAssertEqual(lowLatency.pixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertTrue(lowLatency.showsCursor)
        XCTAssertTrue((2 ... 3).contains(lowLatency.queueDepth))
        XCTAssertEqual(lowLatency.width, 3840)
        XCTAssertEqual(lowLatency.height, 2160)
        XCTAssertEqual(lowLatency.minimumFrameInterval, CMTime(value: 1, timescale: 120))

        let powerSaving = factory.makeConfiguration(
            resolution: CGSize(width: 1920, height: 1080),
            scaleFactor: 1,
            mode: .powerSaving
        )
        XCTAssertEqual(powerSaving.minimumFrameInterval, CMTime(value: 1, timescale: 60))
    }

    /// Out-of-range queueDepth values must be clamped to the {2,3} range
    /// required by FR-14. Defends against future callers that pass 1 or 4.
    func testQueueDepthClampedToFR14Range() {
        let factory = StreamConfigurationFactory()
        let tooLow = factory.makeConfiguration(
            resolution: CGSize(width: 1280, height: 720),
            scaleFactor: 1,
            mode: .powerSaving,
            queueDepth: 1
        )
        XCTAssertEqual(tooLow.queueDepth, 2)
        let tooHigh = factory.makeConfiguration(
            resolution: CGSize(width: 1280, height: 720),
            scaleFactor: 1,
            mode: .powerSaving,
            queueDepth: 7
        )
        XCTAssertEqual(tooHigh.queueDepth, 3)
    }
}
