//
//  render.display_link_pacer.swift
//  DeskPad
//
//  @agents-index Display-link pacer that drives the renderer once per
//  refresh, gated by a `Bool` dirty flag so idle frames cost zero GPU
//  work (CR-0001 FR-5). Production attaches a `CAMetalDisplayLink` to
//  the host view's `CAMetalLayer` per FR-17 / AC-16 so the per-tick
//  `targetPresentationTimestamp` reaches the present closure and the
//  drawable can be anchored to the vsync grid. The deprecated
//  `CVDisplayLink` API is explicitly forbidden in this code path.
//

import AppKit
import Foundation
import QuartzCore

/// Per-tick context handed to the present closure. Carries the
/// `targetPresentationTimestamp` so the renderer can call
/// `MTLDrawable.present(at:)` aligned to the upcoming vsync (FR-17,
/// AC-16). Test paths construct a synthetic instance with zero
/// timestamps.
public struct PacerTick: @unchecked Sendable {
    /// Target presentation time on the host clock; the renderer hands
    /// this verbatim to `MTLDrawable.present(at:)`.
    public let targetPresentationTimestamp: CFTimeInterval
    /// Per-tick anticipated refresh interval. Surfaced for diagnostics.
    public let targetTimestamp: CFTimeInterval
    /// Drawable vended by `CAMetalDisplayLink.Update`. When a metal
    /// display link is attached to a layer, drawables MUST be consumed
    /// from the link's update rather than `layer.nextDrawable()`; the
    /// two paths conflict and `nextDrawable()` starves (returns nil),
    /// which presented as an all-white window. Nil in tests and on the
    /// legacy tick path, where the renderer falls back to the layer.
    public let drawable: (any CAMetalDrawable)?

    public init(
        targetPresentationTimestamp: CFTimeInterval = 0,
        targetTimestamp: CFTimeInterval = 0,
        drawable: (any CAMetalDrawable)? = nil
    ) {
        self.targetPresentationTimestamp = targetPresentationTimestamp
        self.targetTimestamp = targetTimestamp
        self.drawable = drawable
    }
}

/// Display-link pacer. The pacer is `@MainActor`-isolated because both
/// the production tick source (`CAMetalDisplayLink`) and the renderer
/// it drives are main-actor APIs.
@MainActor
public final class DisplayLinkPacer: NSObject {
    /// Closure invoked once per display-link tick when the dirty flag is
    /// set. Receives the tick context so the renderer can anchor the
    /// drawable to the vsync grid (FR-17).
    public typealias Present = (PacerTick) -> Void

    private let log = Logger(category: "render")
    private var metalDisplayLink: CAMetalDisplayLink?
    private var present: Present
    private var dirty: Bool = false

    /// Test-only counter: how many times `present` was actually invoked.
    public private(set) var presentCallCount: Int = 0
    /// Test-only counter: how many ticks were observed total.
    public private(set) var tickCount: Int = 0

    /// Build a pacer with the closure invoked on a dirty tick. The
    /// display link is not started until `attach(toMetalLayer:)`.
    public init(present: @escaping Present) {
        self.present = present
    }

    /// Mark the next tick as dirty. Called by the capture-to-render
    /// bridge when a new `IOSurface` becomes available.
    public func markDirty() {
        dirty = true
    }

    /// Swap the present closure post-construction. The coordinator
    /// builds the pacer first (so it can be exposed publicly) and then
    /// installs the render-loop closure once all dependencies have been
    /// constructed.
    public func replacePresent(_ newPresent: @escaping Present) {
        present = newPresent
    }

    /// Attach the pacer to a `CAMetalLayer`, building a
    /// `CAMetalDisplayLink` per FR-17 / AC-16 and adding it to the main
    /// run loop. The pacer becomes the link's delegate.
    public func attach(toMetalLayer layer: CAMetalLayer) {
        detach()
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.delegate = self
        link.add(to: .main, forMode: .common)
        metalDisplayLink = link
        log.info("DisplayLinkPacer attached to CAMetalLayer")
    }

    /// Invalidate and drop the underlying display link.
    public func detach() {
        metalDisplayLink?.invalidate()
        metalDisplayLink = nil
    }

    /// Test-only entry point: drive the same code path as a real
    /// display-link callback without requiring the system link.
    public func tick(_ context: PacerTick = PacerTick()) {
        tickCount += 1
        guard dirty else { return }
        dirty = false
        presentCallCount += 1
        present(context)
    }
}

extension DisplayLinkPacer: CAMetalDisplayLinkDelegate {
    public nonisolated func metalDisplayLink(
        _: CAMetalDisplayLink,
        needsUpdate update: CAMetalDisplayLink.Update
    ) {
        let tickContext = PacerTick(
            targetPresentationTimestamp: update.targetPresentationTimestamp,
            targetTimestamp: update.targetTimestamp,
            drawable: update.drawable
        )
        MainActor.assumeIsolated {
            tick(tickContext)
        }
    }
}
