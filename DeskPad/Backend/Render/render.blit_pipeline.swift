//
//  render.blit_pipeline.swift
//  DeskPad
//
//  @agents-index Textured-quad render pipeline for the CR-0001 Phase 3
//  blit path. Owns the `MTLRenderPipelineState`, the shader source, and
//  the `draw(into:from:)` entry point that encodes a full-screen quad
//  sampling the supplied `MTLTexture` into the supplied drawable.
//
//  The shader sources are inlined as a Swift string and compiled via
//  `MTLDevice.makeLibrary(source:options:)` rather than precompiled into a
//  `.metallib` so the pipeline is fully self-contained and does not depend
//  on a Metal source file being added to the build phase (which would
//  require a separate `MTL_LANGUAGE_REVISION` line item in the pbxproj).
//

import Foundation
import Metal
import simd

/// Textured-quad pipeline used by the renderer to blit an
/// `IOSurface`-backed `MTLTexture` into a `CAMetalLayer` drawable. The
/// pipeline is rebuilt on device-loss via `BlitPipeline(device:)` and the
/// `replaceDevice(_:)` recovery helper.
public final class BlitPipeline {
    /// Inline MSL source: vertex stage emits a full-screen triangle pair
    /// derived from `vertex_id` (no vertex buffer required); fragment stage
    /// samples the supplied texture with a linear sampler.
    private static let shaderSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VOut blit_vertex(uint vid [[vertex_id]]) {
        float2 positions[4] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0,  1.0)
        };
        float2 uvs[4] = {
            float2(0.0, 1.0),
            float2(1.0, 1.0),
            float2(0.0, 0.0),
            float2(1.0, 0.0)
        };
        VOut out;
        out.position = float4(positions[vid], 0.0, 1.0);
        out.uv = uvs[vid];
        return out;
    }

    fragment float4 blit_fragment(
        VOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]]
    ) {
        constexpr sampler s(mag_filter::linear, min_filter::linear);
        return tex.sample(s, in.uv);
    }
    """

    private let log = Logger(category: "render")
    private(set) var device: MTLDevice
    private(set) var pipelineState: MTLRenderPipelineState
    private(set) var sampler: MTLSamplerState

    /// Construct the pipeline against `device`. Throws if the shader source
    /// fails to compile or pipeline-state construction fails (which on a
    /// healthy device only happens during device-loss).
    public init(device: MTLDevice) throws {
        self.device = device
        (pipelineState, sampler) = try Self.makePipeline(device: device)
    }

    /// Compile the shader source and build the pipeline-state plus the
    /// linear sampler. Factored out so device-loss recovery can rebuild
    /// without reconstructing the surrounding `BlitPipeline`.
    private static func makePipeline(device: MTLDevice) throws -> (MTLRenderPipelineState, MTLSamplerState) {
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        guard
            let vertexFn = library.makeFunction(name: "blit_vertex"),
            let fragmentFn = library.makeFunction(name: "blit_fragment")
        else {
            throw NSError(
                domain: "DeskPad.BlitPipeline",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "shader functions missing"]
            )
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw NSError(
                domain: "DeskPad.BlitPipeline",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "sampler creation failed"]
            )
        }
        return (pipelineState, sampler)
    }

    /// Encode a single textured-quad blit of `source` into the supplied
    /// drawable texture via the supplied command buffer. Returns `false`
    /// when the command encoder could not be created (treated by the
    /// caller as a transient drop, not an error).
    @discardableResult
    public func draw(
        into drawableTexture: MTLTexture,
        from source: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawableTexture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return false
        }
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return true
    }

    /// Rebuild the pipeline state against a freshly-acquired `MTLDevice`
    /// after device-loss recovery. Throws if the new device cannot compile
    /// the shader source, which is treated as a fatal recovery failure.
    public func replaceDevice(_ newDevice: MTLDevice) throws {
        let (newState, newSampler) = try Self.makePipeline(device: newDevice)
        device = newDevice
        pipelineState = newState
        sampler = newSampler
        log.notice("BlitPipeline rebuilt after device-loss event")
    }
}
