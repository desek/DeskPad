//
//  render.avsbdl_host_view.swift
//  DeskPad
//
//  @agents-index CR-0002 Phase 2: layer-hosted `NSView` whose backing
//  layer is an `AVSampleBufferDisplayLayer`. Placed under
//  `Frontend/Screen/` (not `Backend/Render/`) alongside
//  `render.metal_layer_host_view.swift` because both are `NSView`
//  subclasses; views belong with the frontend. Owned by the CR-0002
//  AVSBDL backend (`render.avsbdl_backend.swift`); the backend reaches
//  the layer's modern `sampleBufferRenderer`
//  (`AVSampleBufferVideoRenderer`) for every enqueue, flush, and status
//  observation. The deprecated direct-on-layer APIs (`enqueueSampleBuffer:`,
//  `flush`, `flushAndRemoveImage`, `status`, `error`,
//  `readyForMoreMediaData`, `requiresFlushToResumeDecoding`, `timebase`)
//  per `AVSampleBufferDisplayLayer.h` lines 94..226 **MUST NOT** be used.
//

import AppKit
import AVFoundation
import QuartzCore

/// `NSView` that hosts an `AVSampleBufferDisplayLayer`. `videoGravity` is
/// `AVLayerVideoGravityResize` (per `AVAnimation.h:48`,
/// `API_AVAILABLE(macos(10.7))`) so the captured content fills the host
/// view exactly without aspect padding, matching the Metal host view's
/// behaviour for the screen-mirror use case.
public final class AVSBDLHostView: NSView {
    /// Underlying `AVSampleBufferDisplayLayer` instance. Force-cast is
    /// safe because the view installs the layer itself in
    /// `makeBackingLayer()`.
    public var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer {
        // swiftlint:disable:next force_cast
        return layer as! AVSampleBufferDisplayLayer
    }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("AVSBDLHostView is constructed programmatically")
    }

    override public func makeBackingLayer() -> CALayer {
        let avLayer = AVSampleBufferDisplayLayer()
        avLayer.videoGravity = .resize
        avLayer.isOpaque = true
        return avLayer
    }
}
