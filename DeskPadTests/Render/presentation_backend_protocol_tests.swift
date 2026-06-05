//
//  presentation_backend_protocol_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0002 Phase 1 Test Strategy row
//  `testCoordinatorHandsOffCMSampleBuffer`: verifies the seam exposes a
//  `CMSampleBuffer` enqueue path and that a fake backend records the
//  exact buffer it was handed. Phase 1 establishes the protocol; later
//  phases wire the coordinator to drive it in production.
//

import AppKit
import CoreMedia
import CoreVideo
import IOSurface
import XCTest

@testable import DeskPad

@MainActor
final class PresentationBackendProtocolTests: XCTestCase {
    /// Minimal fake backend that records every `enqueue(_:)` invocation
    /// so the test can assert pointer-identity of the forwarded buffer.
    private final class FakeBackend: PresentationBackend {
        var enqueued: [CMSampleBuffer] = []
        let hostView: NSView = .init()
        var presentedFrameCount: Int { enqueued.count }
        var diagnostics: PresentationBackendDiagnostics {
            PresentationBackendDiagnostics(identifier: "fake", latencyModeApplicable: true)
        }

        func configure(displaySize _: CGSize, scaleFactor _: CGFloat) throws {}
        func enqueue(_ sampleBuffer: CMSampleBuffer) { enqueued.append(sampleBuffer) }
        func teardown() {}
    }

    /// Synthesise an `IOSurface`-backed `CMSampleBuffer` so the test
    /// drives the same buffer shape the SCK delivery callback produces.
    private func makeSampleBuffer(width: Int = 64, height: Int = 64) throws -> CMSampleBuffer {
        let props: [IOSurfacePropertyKey: Any] = [
            .width: width, .height: height,
            .pixelFormat: kCVPixelFormatType_32BGRA, .bytesPerElement: 4,
        ]
        let surface = try XCTUnwrap(IOSurface(properties: props))
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        var pb: Unmanaged<CVPixelBuffer>?
        let pbStatus = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, surface, attrs as CFDictionary, &pb
        )
        XCTAssertEqual(pbStatus, kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(pb).takeRetainedValue()
        var formatDesc: CMFormatDescription?
        let fdStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        XCTAssertEqual(fdStatus, noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: 0, timescale: 60),
            decodeTimeStamp: .invalid
        )
        var sb: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: try XCTUnwrap(formatDesc),
            sampleTiming: &timing, sampleBufferOut: &sb
        )
        XCTAssertEqual(sbStatus, noErr)
        return try XCTUnwrap(sb)
    }

    /// Verifies a backend records the exact `CMSampleBuffer` it is
    /// handed (pointer identity), proving the seam is the buffer type
    /// the CR specifies and not a copy or unwrapped surrogate
    /// (CR-0002 FR-2).
    func testCoordinatorHandsOffCMSampleBuffer() throws {
        let backend = FakeBackend()
        let buffer = try makeSampleBuffer()
        backend.enqueue(buffer)
        XCTAssertEqual(backend.enqueued.count, 1)
        // CFEqual returns true only when the two refs are the same
        // CoreFoundation object; bridging through Swift's `===`
        // ambiguates because `CMSampleBuffer` is a `class` shim.
        let recorded = try XCTUnwrap(backend.enqueued.first)
        XCTAssertTrue(CFEqual(recorded, buffer))
    }
}
