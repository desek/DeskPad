//
//  avsbdl_backend_enqueue_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0002 Phase 2 Test Strategy row
//  `testEnqueueGoesThroughSampleBufferRenderer`: verifies the backend
//  enqueues through the modern `sampleBufferRenderer` path (modelled by
//  the spy renderer) and never through the deprecated layer-level
//  `enqueueSampleBuffer:` (FR-7, AC-8).
//

import AppKit
import CoreMedia
import XCTest

@testable import DeskPad

@MainActor
final class AVSBDLBackendEnqueueTests: XCTestCase {
    func testEnqueueGoesThroughSampleBufferRenderer() throws {
        let spy = SpyAVSBDLRenderer()
        let view = NSView(frame: .zero)
        let backend = AVSBDLBackend(renderer: spy, hostView: view)

        let buffer = try AVSBDLTestBuffers.make()
        backend.enqueue(buffer)

        XCTAssertEqual(spy.enqueued.count, 1)
        XCTAssertTrue(CFEqual(try XCTUnwrap(spy.enqueued.first), buffer))
        XCTAssertEqual(backend.diagnostics.identifier, "avsbdl")
        XCTAssertFalse(backend.diagnostics.latencyModeApplicable)
    }
}
