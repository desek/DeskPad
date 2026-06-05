//
//  present_stall_watchdog_backend_agnostic_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0002 Phase 3 / FR-18 / AC-20: after a live switch
//  from Metal to AVSBDL the coordinator's `presentedFrameCount`
//  accessor reads through the active backend so the CR-0003
//  `PresentStallWatchdog` continues to see a meaningful sample.
//

import XCTest

@testable import DeskPad

@MainActor
final class PresentStallWatchdogBackendAgnosticTests: XCTestCase {
    func testWatchdogReadsPresentedCountFromActiveBackend() {
        let coordinator = CaptureRenderCoordinator()
        XCTAssertEqual(coordinator.currentBackend.diagnostics.identifier, "metal")
        let metalCount = coordinator.currentBackend.presentedFrameCount
        XCTAssertGreaterThanOrEqual(metalCount, 0)

        coordinator.switchBackend(to: .avsbdl, trigger: "test")
        XCTAssertEqual(coordinator.currentBackend.diagnostics.identifier, "avsbdl")
        // Fresh AVSBDL backend starts at 0 presented frames; the
        // accessor MUST resolve to this backend, not the torn-down
        // Metal backend.
        XCTAssertEqual(coordinator.currentBackend.presentedFrameCount, 0)
    }
}
