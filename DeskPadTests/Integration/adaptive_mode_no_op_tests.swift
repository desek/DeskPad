//
//  adaptive_mode_no_op_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0002 Phase 3 / FR-14 / AC-14: when the AVSBDL
//  backend is active, the adaptive-mode `.lowLatency` request is a
//  presentation-side no-op. The coordinator's `currentMode` still
//  reflects the requested mode (capture-side effects MAY apply), but
//  the active backend is not asked to alter its presentation
//  behaviour.
//

import XCTest

@testable import DeskPad

@MainActor
final class AdaptiveModeNoOpTests: XCTestCase {
    func testLatencyModeIsNoOpOnAVSBDL() {
        let coordinator = CaptureRenderCoordinator()
        // Switch to AVSBDL: `latencyModeApplicable == false`.
        coordinator.switchBackend(to: .avsbdl, trigger: "test")
        XCTAssertEqual(coordinator.currentBackend.diagnostics.identifier, "avsbdl")
        XCTAssertFalse(coordinator.currentBackend.diagnostics.latencyModeApplicable)

        // Drive the EMA so the desired mode resolves to `.lowLatency`.
        var t: CFTimeInterval = 1
        for _ in 0 ..< 32 {
            coordinator.streamOutput.publishForTest(syntheticIngestHostTime: t)
            t += 1.0 / 60.0
        }
        let mode = coordinator.evaluateAdaptiveMode()
        switch mode {
        case .lowLatency:
            break
        default:
            XCTFail("expected lowLatency mode, got \(mode)")
        }
        // The AVSBDL backend is the active backend; it was not torn
        // down or reconfigured by the latency-mode request (the test
        // is satisfied by the diagnostics still reporting avsbdl).
        XCTAssertEqual(coordinator.currentBackend.diagnostics.identifier, "avsbdl")
    }
}
