//
//  avsbdl_backend_status_recovery_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0002 Phase 2 Test Strategy row
//  `testRecoversOnStatusFailed`: when a status-failed transition is
//  observed the backend MUST log the error and call
//  `flushWithRemovalOfDisplayedImage(true, completion:)` on the
//  renderer (FR-10, AC-10). The real KVO observer requires an
//  `AVSampleBufferVideoRenderer` we cannot mutate; the test drives the
//  same `triggerRecovery(reason:errorDescription:)` entry point the KVO
//  callback funnels through, so the contract under test is the recovery
//  side-effect chain rather than KVO plumbing.
//

import AppKit
import XCTest

@testable import DeskPad

@MainActor
final class AVSBDLBackendStatusRecoveryTests: XCTestCase {
    func testRecoversOnStatusFailed() {
        let spy = SpyAVSBDLRenderer()
        let backend = AVSBDLBackend(renderer: spy, hostView: NSView(frame: .zero))

        backend.triggerRecovery(reason: "status=failed", errorDescription: "synthesized failure")

        XCTAssertEqual(spy.flushCalls.count, 1)
        XCTAssertTrue(spy.flushCalls[0].removeImage)
        XCTAssertTrue(spy.flushCalls[0].completed)
        XCTAssertEqual(backend.diagnostics.lastErrorDescription, "synthesized failure")
    }
}
