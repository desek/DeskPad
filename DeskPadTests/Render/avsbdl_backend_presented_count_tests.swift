//
//  avsbdl_backend_presented_count_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0002 Phase 2 Test Strategy row
//  `testPresentedFrameCountIncrementsOnSuccessfulEnqueue`: the
//  AVSBDL backend MUST increment `presentedFrameCount` exactly once per
//  successful, readiness-gated enqueue and MUST NOT increment when
//  `readyForMoreMediaData` is `false` (FR-18, AC-20). Without this the
//  CR-0003 `PresentStallWatchdog` would false-positive whenever the
//  AVSBDL backend is active.
//

import AppKit
import XCTest

@testable import DeskPad

@MainActor
final class AVSBDLBackendPresentedCountTests: XCTestCase {
    func testPresentedFrameCountIncrementsOnSuccessfulEnqueue() throws {
        let spy = SpyAVSBDLRenderer()
        let backend = AVSBDLBackend(renderer: spy, hostView: NSView(frame: .zero))

        // 5 successful enqueues.
        spy.stubbedReady = true
        for _ in 0 ..< 5 {
            backend.enqueue(try AVSBDLTestBuffers.make())
        }
        XCTAssertEqual(backend.presentedFrameCount, 5)
        XCTAssertEqual(spy.enqueued.count, 5)

        // 5 not-ready drops.
        spy.stubbedReady = false
        for _ in 0 ..< 5 {
            backend.enqueue(try AVSBDLTestBuffers.make())
        }
        XCTAssertEqual(backend.presentedFrameCount, 5, "drops MUST NOT count as presented")
        XCTAssertEqual(spy.enqueued.count, 5)
        XCTAssertEqual(backend.diagnostics.droppedFrameCount, 5)
    }
}
