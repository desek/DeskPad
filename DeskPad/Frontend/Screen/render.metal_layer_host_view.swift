//
//  render.metal_layer_host_view.swift
//  DeskPad
//
//  @agents-index `NSView` subclass that hosts a `CAMetalLayer` for the
//  CR-0001 Phase 3 render path. Owns the `MTLDevice`, drives the layer's
//  `drawableSize` from the captured resolution, and exposes the layer for
//  the blit pipeline and display-link pacer wired in by Phase 4.
//
//  The view is layer-hosted (`wantsLayer = true`, `layer = CAMetalLayer()`),
//  not layer-backed: AppKit must not own a `CAMetalLayer`'s contents because
//  the renderer drives drawable acquisition itself. `framebufferOnly = true`
//  is retained (per the CR's Proposed Change section: we only present, never
//  read back) and `maximumDrawableCount = 2` enforces FR-14's shallow
//  presentation queue so backlog cannot accumulate inside the compositor.
//

import AppKit
import Metal
import QuartzCore

/// `NSView` that hosts a `CAMetalLayer`. The view owns the `MTLDevice` so a
/// single device flows from the host view through to the cache, pipeline, and
/// recovery utility; device-loss recovery (see
/// `render.device_loss_recovery.swift`) rebuilds the device by mutating the
/// `device` reference on `metalLayer`.
public final class MetalLayerHostView: NSView {
    /// Underlying `CAMetalLayer` instance; force-cast is safe because the
    /// view installs the layer itself in `makeBackingLayer()`.
    public var metalLayer: CAMetalLayer {
        // swiftlint:disable:next force_cast
        return layer as! CAMetalLayer
    }

    /// Current Metal device backing the layer. Reassigning via
    /// `replaceDevice(_:)` propagates the new device to the layer atomically.
    public private(set) var device: MTLDevice

    private let log = Logger(category: "render")

    /// Build a host view with the supplied `MTLDevice`. Callers typically
    /// pass `MTLCreateSystemDefaultDevice()`; the device-loss recovery path
    /// constructs a fresh device and hands it back via `replaceDevice(_:)`.
    public init(device: MTLDevice) {
        self.device = device
        super.init(frame: .zero)
        wantsLayer = true
        let metal = CAMetalLayer()
        metal.device = device
        metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = true
        metal.maximumDrawableCount = 2
        metal.isOpaque = true
        metal.contentsGravity = .resizeAspect
        layer = metal
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("MetalLayerHostView is constructed programmatically")
    }

    /// Resize the layer's `drawableSize` to match a captured frame size in
    /// pixels. Callers must pass pixel (not point) dimensions so the texture
    /// blit lands one-to-one without filtering.
    public func setDrawablePixelSize(_ pixelSize: CGSize) {
        let clamped = CGSize(
            width: max(1, pixelSize.width),
            height: max(1, pixelSize.height)
        )
        if metalLayer.drawableSize != clamped {
            metalLayer.drawableSize = clamped
            log.info("drawable resized to \(Int(clamped.width))x\(Int(clamped.height))")
        }
    }

    /// Swap in a freshly-acquired `MTLDevice` after a device-loss event.
    /// Propagates the device to the hosted `CAMetalLayer`.
    public func replaceDevice(_ newDevice: MTLDevice) {
        device = newDevice
        metalLayer.device = newDevice
        log.notice("MTLDevice replaced after device-loss event")
    }
}
