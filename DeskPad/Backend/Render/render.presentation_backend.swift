//
//  render.presentation_backend.swift
//  DeskPad
//
//  @agents-index CR-0002 Phase 1: the Dependency-Inversion seam between
//  the capture subsystem and the presentation stage. Declared
//  `@MainActor` because every backend implementation owns an
//  `NSView`-rooted host and `CALayer` state, which AppKit/QuartzCore
//  pin to the main actor; the cross-actor hand-off from the capture
//  subsystem's background queue uses `await backend.enqueue(buffer)`
//  (or the equivalent `MainActor.assumeIsolated` form in a callback
//  context). Exists so the capture subsystem stays backend-agnostic and
//  so the runtime can swap between the CR-0001 Metal pipeline and the
//  CR-0002 `AVSampleBufferDisplayLayer` pipeline without the capture
//  side being aware of which backend is active.
//

import AppKit
import CoreMedia
import Foundation

/// Protocol both presentation backends conform to. `@MainActor` and
/// `AnyObject` so the conforming `final class` implementations can own
/// main-actor-only AppKit/QuartzCore state without per-call isolation
/// hops, while still being held as an existential by the coordinator.
@MainActor
public protocol PresentationBackend: AnyObject {
    /// Prepare the backend for a given output resolution. Called on
    /// initial start and on every reconfiguration event (resolution or
    /// scale-factor change). Backends that already had a prior
    /// configuration **MUST** flush whatever is pinned to the old
    /// geometry before returning (CR-0002 FR-12).
    func configure(displaySize: CGSize, scaleFactor: CGFloat) throws

    /// Hand off one captured frame for presentation. Called from the
    /// capture subsystem's dedicated background queue via
    /// `await backend.enqueue(buffer)` (CR-0002 FR-2). Backends **MUST
    /// NOT** block this queue; readiness gating and drop policy is
    /// implemented inside the backend (CR-0002 FR-13).
    func enqueue(_ sampleBuffer: CMSampleBuffer)

    /// Release all backend-owned resources. Called on shutdown and on
    /// backend switch (CR-0002 FR-6).
    func teardown()

    /// The view the window's content view embeds. Swapped in and out by
    /// the coordinator on a live backend switch.
    var hostView: NSView { get }

    /// Snapshot of backend-specific health. Logged on every transition;
    /// read by `evaluateAdaptiveMode` to decide whether the
    /// low-latency request applies to the current backend
    /// (CR-0002 FR-14).
    var diagnostics: PresentationBackendDiagnostics { get }

    /// Monotonic counter of frames successfully presented by this
    /// backend. Read by the CR-0003 `PresentStallWatchdog` (via the
    /// coordinator) so the same stall signature works against either
    /// active backend without modification (CR-0002 FR-18).
    var presentedFrameCount: Int { get }
}
