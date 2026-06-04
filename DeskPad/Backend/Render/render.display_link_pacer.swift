//
//  render.display_link_pacer.swift
//  DeskPad
//
//  @agents-index Display-link pacer that drives the renderer once per
//  refresh, gated by a `Bool` dirty flag so idle frames cost zero GPU work
//  (CR-0001 FR-5). Acquires the underlying `CADisplayLink` from
//  `NSView.displayLink(target:selector:)` (macOS 14+) per FR-4; the
//  deprecated `CVDisplayLink` API is explicitly forbidden in this code
//  path and is not referenced anywhere here.
//
//  The pacer keeps the tick-source seam injectable so tests can drive
//  `tick()` directly without spinning up a real `CADisplayLink`. Production
//  attaches the real link via `attach(toHostView:)`; tests construct the
//  pacer with no link attached and call `tick()` from a synthetic loop.
//

import AppKit
import Foundation
import QuartzCore

/// Display-link pacer. The pacer is `@MainActor`-isolated because both
/// `NSView.displayLink(target:selector:)` (the production tick source) and
/// the renderer it drives are main-actor APIs; keeping the pacer itself
/// `@MainActor` lets us avoid hop annotations at every call site.
@MainActor
public final class DisplayLinkPacer {
    /// Closure invoked once per display-link tick when the dirty flag is
    /// set. The pacer clears the dirty flag immediately before invoking
    /// the closure so a newly-arrived frame mid-callback flips the flag
    /// back on for the next tick.
    public typealias Present = () -> Void

    private let log = Logger(category: "render")
    private var displayLink: CADisplayLink?
    private let present: Present
    private var dirty: Bool = false

    /// Test-only counter: how many times `present` was actually invoked.
    /// Exposed for `display_link_pacer_tests.swift` to assert FR-5.
    public private(set) var presentCallCount: Int = 0

    /// Test-only counter: how many ticks were observed total (whether or
    /// not they invoked `present`). Useful for asserting the pacer ticked
    /// but skipped the present.
    public private(set) var tickCount: Int = 0

    /// Build a pacer with the closure invoked on a dirty tick. The display
    /// link is not started until `attach(toHostView:)` is called.
    public init(present: @escaping Present) {
        self.present = present
    }

    /// Mark the next tick as dirty. Called by the capture-to-render bridge
    /// when a new `IOSurface` becomes available.
    public func markDirty() {
        dirty = true
    }

    /// Attach the pacer to a host `NSView`, obtaining a `CADisplayLink`
    /// via the macOS 14+ `NSView.displayLink(target:selector:)` selector
    /// and adding it to the main run loop. The pacer remembers the link so
    /// `detach()` can invalidate it on teardown.
    public func attach(toHostView view: NSView) {
        detach()
        let link = view.displayLink(target: self, selector: #selector(handleTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        log.info("DisplayLinkPacer attached to host view")
    }

    /// Invalidate and drop the underlying display link.
    public func detach() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Test-only entry point that drives the same code path as a real
    /// display-link callback without requiring a `CADisplayLink` to exist.
    public func tick() {
        tickCount += 1
        guard dirty else { return }
        dirty = false
        presentCallCount += 1
        present()
    }

    /// Internal selector target for the real `CADisplayLink`. Forwards to
    /// `tick()` so production and test paths share the same body.
    @objc private func handleTick(_: CADisplayLink) {
        tick()
    }
}
