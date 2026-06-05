//
//  avsbdl_test_buffers.swift
//  DeskPadTests
//
//  @agents-index CR-0002 Phase 2 test support: shared helper that
//  synthesises an `IOSurface`-backed `CMSampleBuffer` matching the shape
//  the capture subsystem delivers, so each `avsbdl_backend_*` test does
//  not duplicate the construction.
//

import CoreMedia
import CoreVideo
import IOSurface
import XCTest

@MainActor
enum AVSBDLTestBuffers {
    /// Build one `IOSurface`-backed `CMSampleBuffer` with a 32BGRA pixel
    /// format. Mirrors the path CR-0001's `StreamOutput` exercises.
    static func make(
        width: Int = 64, height: Int = 64,
        pts: CMTime = CMTime(value: 0, timescale: 60)
    ) throws -> CMSampleBuffer {
        let props: [IOSurfacePropertyKey: Any] = [
            .width: width, .height: height,
            .pixelFormat: kCVPixelFormatType_32BGRA, .bytesPerElement: 4,
        ]
        let surface = try XCTUnwrap(IOSurface(properties: props))
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        var pb: Unmanaged<CVPixelBuffer>?
        XCTAssertEqual(
            CVPixelBufferCreateWithIOSurface(
                kCFAllocatorDefault, surface, attrs as CFDictionary, &pb
            ),
            kCVReturnSuccess
        )
        let pixelBuffer = try XCTUnwrap(pb).takeRetainedValue()
        var formatDesc: CMFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDesc
            ),
            noErr
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sb: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                formatDescription: try XCTUnwrap(formatDesc),
                sampleTiming: &timing, sampleBufferOut: &sb
            ),
            noErr
        )
        return try XCTUnwrap(sb)
    }
}
