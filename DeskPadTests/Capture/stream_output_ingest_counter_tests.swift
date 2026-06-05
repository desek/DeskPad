//
//  stream_output_ingest_counter_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0003 Phase 1 / FR-5 closure: asserts
//  `StreamOutput.ingestedFrameCount` advances by exactly one per
//  successful `ingest(_:)`. The counter is the seam the Layer 1 watchdog
//  observes to detect the white-window failure class.
//

import CoreVideo
import IOSurface
import XCTest

@testable import DeskPad

final class StreamOutputIngestCounterTests: XCTestCase {
    func testIngestedFrameCountIncrementsOnce() throws {
        let width = 32
        let height = 32
        let surfaceProps: [IOSurfacePropertyKey: Any] = [
            .width: width,
            .height: height,
            .pixelFormat: kCVPixelFormatType_32BGRA,
            .bytesPerElement: 4,
        ]
        let surface = try XCTUnwrap(IOSurface(properties: surfaceProps))
        var pixelBuf: Unmanaged<CVPixelBuffer>?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        _ = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, surface, attrs as CFDictionary, &pixelBuf
        )
        let pb = try XCTUnwrap(pixelBuf).takeRetainedValue()

        let output = StreamOutput()
        XCTAssertEqual(output.ingestedFrameCount, 0)
        output.publishForTest(pixelBuffer: pb)
        XCTAssertEqual(output.ingestedFrameCount, 1)
        output.publishForTest(pixelBuffer: pb)
        output.publishForTest(pixelBuffer: pb)
        XCTAssertEqual(output.ingestedFrameCount, 3)
    }
}
