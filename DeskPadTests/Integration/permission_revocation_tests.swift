//
//  permission_revocation_tests.swift
//  DeskPadTests
//
//  @agents-index Asserts the CR-0001 Phase 4 Test Strategy row
//  `testPermissionRevocationSurfacedAfterErrorBackoff`: when
//  `CGPreflightScreenCaptureAccess` returns false, the coordinator
//  transitions to `.permissionRequired` and triggers a request through
//  the injected permission probe (FR-8, AC-7).
//

import Foundation
import XCTest

@testable import DeskPad

/// Stub probe that exposes a mutable `granted` flag and counts request
/// calls so the test can assert the TCC prompt was triggered.
private final class StubPermissionProbe: ScreenCapturePermissionProbe, @unchecked Sendable {
    var granted: Bool
    var requestCount: Int = 0

    init(granted: Bool) {
        self.granted = granted
    }

    func preflight() -> Bool { granted }

    @discardableResult
    func request() -> Bool {
        requestCount += 1
        return granted
    }
}

@MainActor
final class PermissionRevocationTests: XCTestCase {
    /// Pre-flight returns false: state flips to `.permissionRequired` and
    /// `request()` is invoked once.
    func testPermissionRevocationSurfacedAfterErrorBackoff() {
        let probe = StubPermissionProbe(granted: false)
        let coordinator = CaptureRenderCoordinator(permissionProbe: probe)
        // Simulate the coordinator entering a failed state after restart
        // exhaustion (the Phase 2 backoff schedule terminates here).
        coordinator._setStateForTest(.failed)

        let result = coordinator.evaluatePermission()

        XCTAssertEqual(result, .permissionRequired)
        XCTAssertEqual(coordinator.state, .permissionRequired)
        XCTAssertEqual(probe.requestCount, 1)
    }

    /// Pre-flight returns true: state is left untouched and no TCC prompt
    /// is triggered. Guarantees the watcher is silent on the happy path.
    func testNoPromptWhenPermissionGranted() {
        let probe = StubPermissionProbe(granted: true)
        let coordinator = CaptureRenderCoordinator(permissionProbe: probe)
        coordinator._setStateForTest(.running)

        let result = coordinator.evaluatePermission()

        XCTAssertEqual(result, .running)
        XCTAssertEqual(probe.requestCount, 0)
    }
}
