//
//  avsbdl_backend_readiness_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0002 Phase 2 Test Strategy row
//  `testDropsFrameWhenNotReadyForMoreMediaData`: ten enqueues against a
//  renderer reporting `readyForMoreMediaData = false` MUST drop all ten,
//  bump the drop counter to 10, and emit at most one rate-limited log
//  line (FR-13, AC-13).
//

import AppKit
import XCTest

@testable import DeskPad

@MainActor
final class AVSBDLBackendReadinessTests: XCTestCase {
    func testDropsFrameWhenNotReadyForMoreMediaData() throws {
        let spy = SpyAVSBDLRenderer()
        spy.stubbedReady = false
        let backend = AVSBDLBackend(renderer: spy, hostView: NSView(frame: .zero))

        for _ in 0 ..< 10 {
            let buffer = try AVSBDLTestBuffers.make()
            backend.enqueue(buffer)
        }

        XCTAssertEqual(spy.enqueued.count, 0)
        XCTAssertEqual(backend.diagnostics.droppedFrameCount, 10)
        XCTAssertEqual(backend.presentedFrameCount, 0)
    }
}
