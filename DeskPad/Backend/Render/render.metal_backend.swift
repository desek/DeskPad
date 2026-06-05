//
//  render.metal_backend.swift
//  DeskPad
//
//  @agents-index CR-0002 Phase 1: thin adapter that conforms the
//  CR-0001 ensemble (`FramePresenter`, `MetalLayerHostView`,
//  `IOSurfaceTextureCache`, `BlitPipeline`, `DisplayLinkPacer`) to
//  `PresentationBackend`. Behavioural no-op for the CR-0001 path: the
//  steady-state Metal pipeline keeps publishing through `StreamOutput`
//  and presenting on the `CAMetalDisplayLink` tick exactly as before;
//  this adapter exists so the coordinator can hold a
//  `PresentationBackend` existential rather than the concrete
//  ensemble, satisfying Dependency Inversion and unblocking the
//  Phase 2 AVSBDL backend.
//

import AppKit
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import IOSurface

/// Metal-backed presentation backend. Owns no new state of its own; it
/// holds references to the CR-0001 ensemble the coordinator already
/// constructs and forwards `PresentationBackend` calls to the
/// appropriate member. `enqueue(_:)` unwraps the `CMSampleBuffer` to
/// its underlying `IOSurface` exactly the way `StreamOutput.ingest`
/// does today, so the unwrap site can migrate from the capture
/// subsystem into the backend in a later phase without changing the
/// pixel-data path (still zero-copy in unified memory).
@MainActor
public final class MetalBackend: PresentationBackend {
    private let hostViewImpl: MetalLayerHostView
    private let presenter: FramePresenter
    private let streamOutput: StreamOutput
    private let log = Logger(category: "render")
    private var lastErrorDescription: String?

    /// Construct the adapter around the existing CR-0001 ensemble. The
    /// coordinator passes in the pieces it already owns; the backend
    /// does not allocate Metal state of its own.
    public init(
        hostView: MetalLayerHostView,
        presenter: FramePresenter,
        streamOutput: StreamOutput
    ) {
        hostViewImpl = hostView
        self.presenter = presenter
        self.streamOutput = streamOutput
    }

    public var hostView: NSView { hostViewImpl }

    /// Forwards to `FramePresenter.presentedFrameCount`, which is the
    /// counter the CR-0003 watchdog has been reading since Phase 2.
    public var presentedFrameCount: Int { presenter.presentedFrameCount }

    public var diagnostics: PresentationBackendDiagnostics {
        PresentationBackendDiagnostics(
            identifier: "metal",
            latencyModeApplicable: true,
            lastErrorDescription: lastErrorDescription,
            droppedFrameCount: 0
        )
    }

    /// Apply a new output geometry to the host view. The CR-0001
    /// `MetalLayerHostView` already drives the drawable size from
    /// `setDrawablePixelSize(_:)`; the coordinator continues to call
    /// that directly for the steady-state path, but conforming
    /// `configure` keeps the protocol surface honest and lets a future
    /// phase route geometry through the backend without further churn.
    public func configure(displaySize: CGSize, scaleFactor: CGFloat) throws {
        let width = Int(displaySize.width * scaleFactor)
        let height = Int(displaySize.height * scaleFactor)
        guard width > 0, height > 0 else { return }
        hostViewImpl.setDrawablePixelSize(CGSize(width: width, height: height))
    }

    /// Unwrap the `CMSampleBuffer` to its underlying `IOSurface` via
    /// `CMSampleBufferGetImageBuffer` plus `CVPixelBufferGetIOSurface`
    /// and republish it through the existing `StreamOutput` so the
    /// `FramePresenter` continues to read `latestCapturedSurface` on
    /// each `CAMetalDisplayLink` tick. This is the migration target for
    /// Phase 3 once the coordinator forwards captured buffers through
    /// the backend; until then the production path still runs through
    /// `StreamOutput`'s `SCStreamOutput` callback directly and this
    /// entry point is exercised by tests only. The unwrap matches the
    /// pixel-data path documented at
    /// `CoreVideo/CVPixelBufferIOSurface.h:62` and stays zero-copy.
    public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer) else { return }
        streamOutput.publishForTest(pixelBuffer: pixelBuffer)
        _ = surfaceRef
    }

    public func teardown() {
        // Metal backend is owned by the coordinator's lifetime today;
        // the protocol method exists so the AVSBDL backend can release
        // its `AVSampleBufferDisplayLayer` on a live switch
        // (CR-0002 FR-6). The Metal path has no extra state to drop
        // beyond what `CaptureRenderCoordinator` deinit already
        // releases.
        log.info("MetalBackend teardown: no-op (coordinator-owned ensemble)")
    }
}
