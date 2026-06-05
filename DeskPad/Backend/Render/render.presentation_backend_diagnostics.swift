//
//  render.presentation_backend_diagnostics.swift
//  DeskPad
//
//  @agents-index CR-0002 Phase 1: `Sendable` snapshot of a presentation
//  backend's health (backend identifier, last error description, whether
//  the coordinator's low-latency adaptive mode meaningfully applies to
//  this backend, and a rolling drop count). Declared `Sendable` so the
//  coordinator can read it from off-main contexts without crossing the
//  main-actor boundary for every sample.
//

import Foundation

/// Backend-agnostic diagnostics snapshot. Both the Metal and AVSBDL
/// backends produce one of these from their `diagnostics` accessor; the
/// coordinator logs it on every transition and reads
/// `latencyModeApplicable` inside `evaluateAdaptiveMode` so a
/// latency-mode request becomes a no-op on the AVSBDL backend
/// (CR-0002 FR-14).
public struct PresentationBackendDiagnostics: Sendable, Equatable {
    /// Stable identifier for log lines and tests. `"metal"` or
    /// `"avsbdl"`. Matches the `DeskPad.presentationBackend`
    /// `UserDefaults` string set so the value can be logged verbatim.
    public let identifier: String

    /// `true` if the backend's presentation stage responds to the
    /// coordinator's `CaptureMode.lowLatency` request. The Metal backend
    /// reports `true`; the AVSBDL backend reports `false` because the
    /// system video renderer's internal buffering is not under app
    /// control (CR-0002 FR-14, CR-0001 FR-18).
    public let latencyModeApplicable: Bool

    /// Last error description observed by the backend, if any. `nil`
    /// means the backend is currently healthy. Populated by the AVSBDL
    /// backend's KVO of `sampleBufferRenderer.status` transitioning to
    /// `Failed` and by the Metal backend's last command-buffer error
    /// classification.
    public let lastErrorDescription: String?

    /// Count of frames dropped in the current rolling window. The
    /// AVSBDL backend increments this when `readyForMoreMediaData` is
    /// `false` (CR-0002 FR-13); the Metal backend increments it when
    /// the newest-frame-wins policy supersedes a captured surface
    /// before it could be presented.
    public let droppedFrameCount: Int

    public init(
        identifier: String,
        latencyModeApplicable: Bool,
        lastErrorDescription: String? = nil,
        droppedFrameCount: Int = 0
    ) {
        self.identifier = identifier
        self.latencyModeApplicable = latencyModeApplicable
        self.lastErrorDescription = lastErrorDescription
        self.droppedFrameCount = droppedFrameCount
    }
}
