//
//  newest_frame_wins_tests.swift
//  DeskPadTests
//
//  @agents-index Asserts the CR-0001 Test Strategy row
//  `testOlderSurfaceDroppedWhenNewerArrives`: `StreamOutput`'s
//  single-slot publish drops the older `IOSurface` as soon as a newer
//  one arrives (FR-14, AC-14).
//

import CoreVideo
import IOSurface
import XCTest

@testable import DeskPad

final class NewestFrameWinsTests: XCTestCase {
    func testOlderSurfaceDroppedWhenNewerArrives() throws {
        let output = StreamOutput()
        let older = try makeSurface(width: 32, height: 32)
        let newer = try makeSurface(width: 64, height: 64)

        output.publishForTest(pixelBuffer: try wrap(older))
        let firstID = IOSurfaceGetID(try XCTUnwrap(output.latestSurface))

        output.publishForTest(pixelBuffer: try wrap(newer))
        let secondID = IOSurfaceGetID(try XCTUnwrap(output.latestSurface))

        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(secondID, IOSurfaceGetID(newer))
    }

    private func makeSurface(width: Int, height: Int) throws -> IOSurface {
        let props: [IOSurfacePropertyKey: Any] = [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ]
        return try XCTUnwrap(IOSurface(properties: props))
    }

    private func wrap(_ surface: IOSurface) throws -> CVPixelBuffer {
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        var pb: Unmanaged<CVPixelBuffer>?
        let status = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, surface, attrs as CFDictionary, &pb
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(pb).takeRetainedValue()
    }
}
