//
//  fake_metal_drawable.swift
//  DeskPadTests
//
//  @agents-index Test-only `CAMetalDrawable` stand-in for the CR-0003 Part A
//  coverage closure. Wraps an offscreen `MTLTexture` minted from a real
//  `MTLDevice` so `FramePresenter.present(tick:)` can be exercised on the
//  link-vended drawable branch without a live `CAMetalDisplayLink`. Lives
//  exclusively in the test target; a `grep -rn "FakeMetalDrawable" DeskPad/`
//  must return no matches (FR-17).
//

import Foundation
import Metal
import QuartzCore

@testable import DeskPad

/// Minimal `CAMetalDrawable` conformer used by the FramePresenter tests.
/// `present(_:)` and `present(at:)` are recorded as no-ops; the renderer
/// commits real Metal work into the wrapped texture before calling them.
final class FakeMetalDrawable: NSObject, CAMetalDrawable {
    /// The backing texture the renderer encodes into. Storage mode is
    /// `.private` because the encode path is a render-pass attachment;
    /// tests that need read-back blit into a `.shared` staging buffer.
    let _texture: MTLTexture
    /// Stand-in for the layer the drawable would belong to; tests do not
    /// touch the layer directly so a fresh, unattached `CAMetalLayer`
    /// suffices.
    let _layer: CAMetalLayer

    private(set) var presentCalls: Int = 0
    private(set) var presentAtCalls: Int = 0
    private(set) var lastPresentAt: CFTimeInterval = 0

    init?(device: MTLDevice, width: Int = 64, height: Int = 64) {
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .bgra8Unorm
        descriptor.width = width
        descriptor.height = height
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        _texture = texture
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        _layer = layer
        super.init()
    }

    var texture: MTLTexture { _texture }
    var layer: CAMetalLayer { _layer }

    func present() { presentCalls += 1 }
    func present(at presentationTime: CFTimeInterval) {
        presentAtCalls += 1
        lastPresentAt = presentationTime
    }

    func present(afterMinimumDuration _: CFTimeInterval) { presentCalls += 1 }
    func addPresentedHandler(_: @escaping (any MTLDrawable) -> Void) {}
    var presentedTime: CFTimeInterval { 0 }
    var drawableID: Int { 0 }

    // The MTLCommandBuffer.present(_:) path calls private ObjC selectors
    // such as `addPresentScheduledHandler:` and `presentAtTime:` on the
    // drawable to fold it into the schedule. They are not surfaced in the
    // Swift CAMetalDrawable protocol; expose them as @objc no-ops so the
    // fake drawable survives a real `cb.present(drawable)` without
    // raising `unrecognized selector`.
    @objc func addPresentScheduledHandler(_: Any) {}
}
