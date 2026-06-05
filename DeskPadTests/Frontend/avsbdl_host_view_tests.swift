//
//  avsbdl_host_view_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0002 Phase 2 Test Strategy row
//  `testHostViewBackingLayerIsAVSampleBufferDisplayLayer`: verifies the
//  AVSBDL host view's backing layer is an `AVSampleBufferDisplayLayer`
//  so the backend can drive its `sampleBufferRenderer`.
//

import AppKit
import AVFoundation
import XCTest

@testable import DeskPad

@MainActor
final class AVSBDLHostViewTests: XCTestCase {
    func testHostViewBackingLayerIsAVSampleBufferDisplayLayer() {
        let view = AVSBDLHostView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        // Force layer realization through wantsLayer / makeBackingLayer.
        _ = view.layer
        XCTAssertTrue(view.layer is AVSampleBufferDisplayLayer)
        XCTAssertNotNil(view.sampleBufferDisplayLayer)
        XCTAssertEqual(view.sampleBufferDisplayLayer.videoGravity, .resize)
    }
}
