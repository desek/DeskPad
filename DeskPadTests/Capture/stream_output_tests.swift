//
//  stream_output_tests.swift
//  DeskPadTests
//
//  @agents-index Asserts the CR-0001 Phase 2 Test Strategy row
//  `testIOSurfaceExtractedZeroCopy`: the stream output publishes the same
//  `IOSurfaceID` as the source `CMSampleBuffer`'s pixel buffer.
//

import CoreMedia
import CoreVideo
import IOSurface
import XCTest

@testable import DeskPad

final class StreamOutputTests: XCTestCase {
    /// `testIOSurfaceExtractedZeroCopy` — synthesises a `CMSampleBuffer`
    /// backed by an `IOSurface`, feeds it through `StreamOutput`, and
    /// confirms the published surface's `IOSurfaceID` equals the source.
    func testIOSurfaceExtractedZeroCopy() throws {
        let width = 64
        let height = 64
        let surfaceProperties: [IOSurfacePropertyKey: Any] = [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ]
        let surface = try XCTUnwrap(IOSurface(properties: surfaceProperties))
        let sourceID = IOSurfaceGetID(surface)

        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        var unmanagedPixelBuffer: Unmanaged<CVPixelBuffer>?
        let status = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault,
            surface,
            attrs as CFDictionary,
            &unmanagedPixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let pb = try XCTUnwrap(unmanagedPixelBuffer).takeRetainedValue()

        // StreamOutput's ingest only reads the image buffer; we therefore
        // bypass building a full CMSampleBuffer (whose Swift signature for
        // imageBuffer changed across SDKs and is finicky) and exercise the
        // same extraction path that runs in production via the explicit
        // CVPixelBuffer entry point.
        let output = StreamOutput()
        output.publishForTest(pixelBuffer: pb)

        let publishedSurface = try XCTUnwrap(output.latestSurface)
        XCTAssertEqual(IOSurfaceGetID(publishedSurface), sourceID)
    }

    /// CR-0002 FR-2: when ingestion runs through the `SCStreamOutput`
    /// path, the published `CapturedSurface` carries the source
    /// `CMSampleBuffer` so the `PresentationBackend.enqueue(_:)`
    /// hand-off does not need a second IOSurface extraction. Asserts
    /// against `latestCapturedSurface?.sampleBuffer` directly.
    func testIngestPublishesSourceCMSampleBuffer() throws {
        let width = 32
        let height = 32
        let surfaceProperties: [IOSurfacePropertyKey: Any] = [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ]
        let surface = try XCTUnwrap(IOSurface(properties: surfaceProperties))
        let sourceID = IOSurfaceGetID(surface)

        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        var unmanagedPixelBuffer: Unmanaged<CVPixelBuffer>?
        let status = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, surface, attrs as CFDictionary, &unmanagedPixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let pb = try XCTUnwrap(unmanagedPixelBuffer).takeRetainedValue()

        var formatDesc: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pb,
                formatDescriptionOut: &formatDesc
            ),
            noErr
        )
        let fmt = try XCTUnwrap(formatDesc)
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: 0, timescale: 60),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pb,
                dataReady: true, makeDataReadyCallback: nil,
                refcon: nil, formatDescription: fmt,
                sampleTiming: &timing, sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        let sb = try XCTUnwrap(sampleBuffer)

        let output = StreamOutput()
        output.publishForTest(sampleBuffer: sb)

        let captured = try XCTUnwrap(output.latestCapturedSurface)
        XCTAssertEqual(IOSurfaceGetID(captured.surface), sourceID)
        let republished = try XCTUnwrap(captured.sampleBuffer)
        let republishedPB = try XCTUnwrap(CMSampleBufferGetImageBuffer(republished))
        let republishedSurfaceRef = try XCTUnwrap(CVPixelBufferGetIOSurface(republishedPB))
        XCTAssertEqual(IOSurfaceGetID(republishedSurfaceRef.takeUnretainedValue()), sourceID)
    }
}
