//
//  blit_pipeline_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0003 Phase 1 closure for `render.blit_pipeline.swift`.
//  Constructs a real `MTLDevice` headlessly and exercises the encode path
//  end-to-end, including `replaceDevice(_:)`.
//

import Metal
import XCTest

@testable import DeskPad

final class BlitPipelineTests: XCTestCase {
    /// Encodes a draw into a `.shared`-storage destination so the texture
    /// is reachable from the CPU after `waitUntilCompleted()`. Asserts
    /// the encoder produced a non-uniform output, which catches the
    /// "shader silently emits the clear colour" regression class.
    func testBlitProducesNonUniformOutput() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this host")
        }
        let pipeline = try BlitPipeline(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())

        let srcDescriptor = MTLTextureDescriptor()
        srcDescriptor.pixelFormat = .bgra8Unorm
        srcDescriptor.width = 16
        srcDescriptor.height = 16
        srcDescriptor.usage = [.shaderRead]
        srcDescriptor.storageMode = .shared
        let source = try XCTUnwrap(device.makeTexture(descriptor: srcDescriptor))

        // Seed the source with a gradient so the fragment shader has
        // something distinct to sample.
        var bytes = [UInt8](repeating: 0, count: 16 * 16 * 4)
        for y in 0 ..< 16 {
            for x in 0 ..< 16 {
                let i = (y * 16 + x) * 4
                bytes[i] = UInt8(x * 16)
                bytes[i + 1] = UInt8(y * 16)
                bytes[i + 2] = 128
                bytes[i + 3] = 255
            }
        }
        source.replace(
            region: MTLRegionMake2D(0, 0, 16, 16),
            mipmapLevel: 0,
            withBytes: &bytes,
            bytesPerRow: 16 * 4
        )

        let dstDescriptor = MTLTextureDescriptor()
        dstDescriptor.pixelFormat = .bgra8Unorm
        dstDescriptor.width = 16
        dstDescriptor.height = 16
        dstDescriptor.usage = [.renderTarget]
        dstDescriptor.storageMode = .shared
        let destination = try XCTUnwrap(device.makeTexture(descriptor: dstDescriptor))

        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(pipeline.draw(into: destination, from: source, commandBuffer: cb))
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertNil(cb.error, "command buffer must not surface an error")

        var out = [UInt8](repeating: 0, count: 16 * 16 * 4)
        destination.getBytes(
            &out, bytesPerRow: 16 * 4,
            from: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0
        )
        let firstPixel = (out[0], out[1], out[2])
        let lastPixel = (out[16 * 16 * 4 - 4], out[16 * 16 * 4 - 3], out[16 * 16 * 4 - 2])
        XCTAssertNotEqual(
            firstPixel.0, lastPixel.0,
            "blit output must not be uniform"
        )
    }

    /// Verifies `replaceDevice(_:)` rebuilds the pipeline state.
    func testReplaceDeviceRebuildsPipelineState() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this host")
        }
        let pipeline = try BlitPipeline(device: device)
        let prior = pipeline.pipelineState
        try pipeline.replaceDevice(device)
        XCTAssertFalse(pipeline.pipelineState === prior)
    }
}
