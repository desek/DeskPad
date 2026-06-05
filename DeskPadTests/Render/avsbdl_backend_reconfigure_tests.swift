//
//  avsbdl_backend_reconfigure_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0002 Phase 2 Test Strategy row
//  `testReconfigureFlushesAndUpdatesBounds`: the second `configure(...)`
//  call MUST flush the renderer with `removeDisplayedImage = true` and
//  update the host view's bounds before the next enqueue (FR-12, AC-12).
//

import AppKit
import XCTest

@testable import DeskPad

@MainActor
final class AVSBDLBackendReconfigureTests: XCTestCase {
    func testReconfigureFlushesAndUpdatesBounds() throws {
        let spy = SpyAVSBDLRenderer()
        let view = NSView(frame: .zero)
        let backend = AVSBDLBackend(renderer: spy, hostView: view)

        try backend.configure(displaySize: CGSize(width: 800, height: 600), scaleFactor: 1.0)
        XCTAssertEqual(spy.flushCalls.count, 0, "first configure MUST NOT flush")
        XCTAssertEqual(view.frame.size, CGSize(width: 800, height: 600))

        try backend.configure(displaySize: CGSize(width: 1920, height: 1080), scaleFactor: 2.0)
        XCTAssertEqual(spy.flushCalls.count, 1, "reconfigure MUST flush exactly once")
        XCTAssertTrue(spy.flushCalls[0].removeImage)
        XCTAssertTrue(spy.flushCalls[0].completed)
        XCTAssertEqual(view.frame.size, CGSize(width: 1920, height: 1080))

        // No enqueue between the second configure call and now.
        XCTAssertEqual(spy.enqueued.count, 0)
    }
}
