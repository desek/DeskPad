//
//  avsbdl_backend_decode_failure_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0002 Phase 2 Test Strategy row
//  `testRecoversOnDecodeFailureNotification`: the
//  `AVSampleBufferVideoRendererDidFailToDecodeNotification` MUST be
//  handled as a recovery trigger equivalent to the status-failed path
//  (FR-11, AC-11). The test drives the shared
//  `triggerRecovery(reason:errorDescription:)` entry point with the
//  same reason string the notification observer uses.
//

import AppKit
import XCTest

@testable import DeskPad

@MainActor
final class AVSBDLBackendDecodeFailureTests: XCTestCase {
    func testRecoversOnDecodeFailureNotification() {
        let spy = SpyAVSBDLRenderer()
        let backend = AVSBDLBackend(renderer: spy, hostView: NSView(frame: .zero))

        backend.triggerRecovery(reason: "DidFailToDecode", errorDescription: "decode failed")

        XCTAssertEqual(spy.flushCalls.count, 1)
        XCTAssertTrue(spy.flushCalls[0].removeImage)
        XCTAssertEqual(backend.diagnostics.lastErrorDescription, "decode failed")
    }
}
