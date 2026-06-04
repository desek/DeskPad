//
//  render.frame_presenter.swift
//  DeskPad
//
//  @agents-index Per-tick render closure: pulls the latest captured
//  `IOSurface` from `StreamOutput`, mints / reuses an `MTLTexture` via
//  the cache, encodes a blit via `BlitPipeline`, and presents the
//  drawable at the vsync-aligned `targetPresentationTimestamp` (FR-3,
//  FR-5, FR-14, FR-17). Extracted from the coordinator so the latter
//  stays under the NFR-4 / AC-17 200-LOC cap and the render-loop body
//  can be unit-exercised independently.
//

import Foundation
import Metal
import QuartzCore

/// Render loop driver. Constructed once by the coordinator with the
/// shared dependencies; `present(tick:)` is invoked by the pacer on
/// every dirty tick and emits one drawable.
@MainActor
public final class FramePresenter {
    private let textureCache: IOSurfaceTextureCache
    private let streamOutput: StreamOutput
    private let hostView: MetalLayerHostView
    private let commandQueue: MTLCommandQueue?
    private let getPipeline: () -> BlitPipeline?
    private var onCommandBufferError: @Sendable (NSError?) -> Void
    private let log = Logger(category: "render")
    private var framesPresented: Int = 0

    public init(
        textureCache: IOSurfaceTextureCache,
        streamOutput: StreamOutput,
        hostView: MetalLayerHostView,
        commandQueue: MTLCommandQueue?,
        getPipeline: @escaping () -> BlitPipeline?,
        onCommandBufferError: @escaping @Sendable (NSError?) -> Void
    ) {
        self.textureCache = textureCache
        self.streamOutput = streamOutput
        self.hostView = hostView
        self.commandQueue = commandQueue
        self.getPipeline = getPipeline
        self.onCommandBufferError = onCommandBufferError
    }

    /// Test-only counter for the per-tick render path.
    public var presentedFrameCount: Int { framesPresented }

    /// Swap the command-buffer error handler post-construction so the
    /// coordinator can install a closure that captures `weak self`
    /// without bootstrapping it before `init` completes.
    public func setOnCommandBufferError(_ handler: @escaping @Sendable (NSError?) -> Void) {
        onCommandBufferError = handler
    }

    /// Encode and present one frame using the pacer-supplied tick.
    public func present(tick: PacerTick) {
        guard let captured = streamOutput.latestCapturedSurface else { return }
        guard let texture = textureCache.texture(for: captured.surface) else { return }
        guard let drawable = hostView.metalLayer.nextDrawable() else { return }
        guard let cb = commandQueue?.makeCommandBuffer() else { return }
        guard let pipeline = getPipeline() else { return }
        _ = pipeline.draw(into: drawable.texture, from: texture, commandBuffer: cb)
        if tick.targetPresentationTimestamp > 0 {
            cb.present(drawable, atTime: tick.targetPresentationTimestamp)
        } else {
            cb.present(drawable)
        }
        let onError = onCommandBufferError
        cb.addCompletedHandler { completed in
            let nsError = completed.error as NSError?
            Task { @MainActor in onError(nsError) }
        }
        cb.commit()
        framesPresented += 1
        if framesPresented % 60 == 0 {
            let latency = CACurrentMediaTime() - captured.ingestHostTime
            log.info("capture-to-present latency ms=\(Int(latency * 1000)) frame=\(framesPresented)")
        }
    }
}
