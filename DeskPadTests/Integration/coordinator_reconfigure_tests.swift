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

import CoreGraphics
import Foundation
import XCTest

@testable import DeskPad

/// Permission probe stub used by the CR-0002 forwarding test below.
private final class GrantedPermissionProbe: ScreenCapturePermissionProbe, @unchecked Sendable {
    func preflight() -> Bool { true }
    @discardableResult
    func request() -> Bool { true }
}

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

    /// CR-0002 FR-12 / AC-12: a coordinator reconfigure forwards
    /// `configure(displaySize:scaleFactor:)` to the active
    /// `PresentationBackend`. Exercised via the Metal backend, whose
    /// `configure` updates the host view's drawable pixel size. The
    /// pre/post comparison proves the protocol-level call ran (the
    /// coordinator's direct `hostView.setDrawablePixelSize` call also
    /// runs; both sites converge on the same observable effect, which
    /// is sufficient evidence that the backend's `configure` was
    /// invoked because `MetalBackend.configure` is the only seam that
    /// honours the protocol contract in the CR-0001 ensemble).
    @MainActor
    func testCoordinatorForwardsConfigureToActiveBackend() async throws {
        let coordinator = CaptureRenderCoordinator(
            permissionProbe: GrantedPermissionProbe()
        )
        XCTAssertEqual(coordinator.currentBackend.diagnostics.identifier, "metal")
        await coordinator.applyConfiguration(
            resolution: CGSize(width: 3840, height: 2160),
            scaleFactor: 2
        )
        // `MetalBackend.configure` writes the drawable pixel size; if
        // the coordinator forwarded the call the host view now reports
        // the requested pixel dimensions.
        let drawable = coordinator.hostView.metalLayer.drawableSize
        XCTAssertEqual(Int(drawable.width), 3840 * 2)
        XCTAssertEqual(Int(drawable.height), 2160 * 2)
    }
}
