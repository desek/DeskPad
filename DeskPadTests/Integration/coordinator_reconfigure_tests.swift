//
//  coordinator_reconfigure_tests.swift
//  DeskPadTests
//
//  @agents-index Asserts the CR-0001 Phase 4 Test Strategy row
//  `testReconfigureOnResolutionChange`: a resolution change drives the
//  stream coordinator's `updateConfiguration` exactly once, with zero
//  `start`/`stop` pairs (FR-6, AC-9). Uses a stub stream handle so the
//  test runs without ScreenCaptureKit, screen-recording permission, or a
//  real virtual display.
//

import Foundation
import XCTest

@testable import DeskPad

/// Stub stream handle that records every lifecycle call so the test can
/// assert the reconfigure-vs-restart contract.
private final class RecordingStreamHandle: StreamHandle, @unchecked Sendable {
    var startCount: Int = 0
    var stopCount: Int = 0
    var updateConfigurationCount: Int = 0
    var lastWidth: Int = 0
    var lastHeight: Int = 0

    func startStream() async throws { startCount += 1 }
    func stopStream() async throws { stopCount += 1 }
    func updateConfiguration(width: Int, height: Int) async throws {
        updateConfigurationCount += 1
        lastWidth = width
        lastHeight = height
    }
}

final class CoordinatorReconfigureTests: XCTestCase {
    /// `testReconfigureOnResolutionChange` — exactly one update, zero
    /// stop/start pairs (FR-6, AC-9).
    func testReconfigureOnResolutionChange() async throws {
        let handle = RecordingStreamHandle()
        let coordinator = StreamCoordinator()
        await coordinator.install(handle: handle)

        try await coordinator.updateConfiguration(width: 3840, height: 2160)

        XCTAssertEqual(handle.updateConfigurationCount, 1)
        XCTAssertEqual(handle.startCount, 0)
        XCTAssertEqual(handle.stopCount, 0)
        XCTAssertEqual(handle.lastWidth, 3840)
        XCTAssertEqual(handle.lastHeight, 2160)

        let updates = await coordinator.updateConfigurationCount
        let starts = await coordinator.startCount
        let stops = await coordinator.stopCount
        XCTAssertEqual(updates, 1)
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(stops, 0)
    }
}
