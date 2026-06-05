//
//  metal_backend_adapter_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0002 Phase 1 Test Strategy row
//  `testMetalAdapterUnwrapsIOSurface`: verifies the Metal adapter
//  unwraps `CMSampleBuffer` to its `IOSurface` via
//  `CMSampleBufferGetImageBuffer` + `CVPixelBufferGetIOSurface` and
//  forwards the surface to the existing `StreamOutput` so the
//  downstream renderer reads the same `IOSurfaceID`.
//

import CoreMedia
import CoreVideo
import IOSurface
import Metal
import XCTest

@testable import DeskPad

@MainActor
final class MetalBackendAdapterTests: XCTestCase {
    func testMetalAdapterUnwrapsIOSurface() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let hostView = MetalLayerHostView(device: device)
        let cache = IOSurfaceTextureCache(device: device)
        let output = StreamOutput()
        let presenter = FramePresenter(
            textureCache: cache, streamOutput: output, hostView: hostView,
            commandQueue: device.makeCommandQueue(),
            getPipeline: { nil }, onCommandBufferError: { _ in }
        )
        let backend = MetalBackend(hostView: hostView, presenter: presenter, streamOutput: output)

        let width = 64, height = 64
        let surfaceProps: [IOSurfacePropertyKey: Any] = [
            .width: width, .height: height,
            .pixelFormat: kCVPixelFormatType_32BGRA, .bytesPerElement: 4,
        ]
        let surface = try XCTUnwrap(IOSurface(properties: surfaceProps))
        let sourceID = IOSurfaceGetID(surface)
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
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDesc
            ),
            noErr
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: 0, timescale: 60),
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
        let sampleBuffer = try XCTUnwrap(sb)

        backend.enqueue(sampleBuffer)

        let published = try XCTUnwrap(output.latestSurface)
        XCTAssertEqual(IOSurfaceGetID(published), sourceID)
        XCTAssertEqual(backend.diagnostics.identifier, "metal")
        XCTAssertTrue(backend.diagnostics.latencyModeApplicable)
    }
}
