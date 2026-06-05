//
//  capture.stream_output.swift
//  DeskPad
//
//  @agents-index `SCStreamOutput` + `SCStreamDelegate` implementation that
//  extracts the zero-copy `IOSurface` from each delivered `CMSampleBuffer` via
//  `CVPixelBufferGetIOSurface` and atomically publishes it for the renderer
//  to consume on the next display-link tick. Also stamps the host-time at
//  ingest (FR-15 latency budget) and tracks an arrival-rate EMA (FR-18
//  adaptive mode switching).
//

import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import IOSurface
import os
import QuartzCore
import ScreenCaptureKit

/// Most-recent surface plus its ingest timestamp, used by the renderer
/// to compute capture-to-present latency (FR-15 / AC-13).
public struct CapturedSurface: Sendable {
    public let surface: IOSurface
    /// `CACurrentMediaTime()` recorded the moment the SCK delivery
    /// callback ran. Subtracting from the present time gives the
    /// end-to-end capture-to-present latency.
    public let ingestHostTime: CFTimeInterval
}

/// Stream output that captures the most recent `IOSurface` delivered by an
/// `SCStream` and exposes it via `latestSurface`. Also reports delegate
/// errors (`SCStreamDelegate.stream(_:didStopWithError:)`) by invoking
/// `onStopError` so the coordinator can drive backoff/restart.
public final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Closure invoked when the stream stops with an error. Captured by the
    /// coordinator to drive exponential-backoff restart.
    public typealias StopErrorHandler = @Sendable (any Error) -> Void

    private let log = Logger(category: "capture")
    private let lock = OSAllocatedUnfairLock<CapturedSurface?>(initialState: nil)
    private let metricsLock = OSAllocatedUnfairLock<ArrivalMetrics>(initialState: ArrivalMetrics())
    private let handlerLock = OSAllocatedUnfairLock<Handlers>(initialState: Handlers())

    /// Mutable handler bundle so the coordinator can wire stop-error
    /// and per-arrival callbacks after `StreamOutput` is constructed.
    /// Held under `handlerLock` so the SCK delivery queue and the main
    /// actor's writer side cannot race.
    private struct Handlers: Sendable {
        var stopErrorHandler: StopErrorHandler?
        var onArrival: (@Sendable () -> Void)?
    }

    private let initialStopErrorHandler: StopErrorHandler?

    /// Monotonic counter of successful surface extractions. Incremented
    /// exactly once per `ingest(_:)` (or test-only publish) call that
    /// extracts an `IOSurface`. Observed by the CR-0003 Layer 1 watchdog
    /// (`render.present_stall_watchdog.swift`) to detect the white-window
    /// failure class (ingestion advancing without presentation).
    private let ingestedCounterLock = OSAllocatedUnfairLock<Int>(initialState: 0)
    public var ingestedFrameCount: Int { ingestedCounterLock.withLock { $0 } }

    /// Snapshot of the EMA of inter-arrival intervals (seconds) plus the
    /// last-seen ingest timestamp. The coordinator's adaptive-mode logic
    /// (FR-18) reads `intervalEMA` to decide whether to switch modes.
    public struct ArrivalMetrics: Sendable {
        public var intervalEMA: Double = 0
        public var lastIngestHostTime: CFTimeInterval = 0
        public var sampleCount: Int = 0
    }

    public init(onStopError: StopErrorHandler? = nil) {
        initialStopErrorHandler = onStopError
        super.init()
        handlerLock.withLock { $0.stopErrorHandler = onStopError }
    }

    /// Replace the stop-error handler post-construction. Used by the
    /// coordinator to wire the FR-7 / AC-6 restart trigger after the
    /// output has been built.
    public func setStopErrorHandler(_ handler: StopErrorHandler?) {
        handlerLock.withLock { $0.stopErrorHandler = handler }
    }

    /// Install a per-arrival callback. The renderer wires this to
    /// `pacer.markDirty()` so a freshly-arrived `IOSurface` lifts the
    /// FR-5 dirty bit and the next display-link tick presents.
    public func setOnArrival(_ handler: (@Sendable () -> Void)?) {
        handlerLock.withLock { $0.onArrival = handler }
    }

    /// Latest captured surface bundle (`IOSurface` + ingest timestamp).
    public var latestCapturedSurface: CapturedSurface? {
        lock.withLock { $0 }
    }

    /// Backwards-compatible accessor: returns just the surface for
    /// existing callers that do not need the ingest timestamp.
    public var latestSurface: IOSurface? {
        lock.withLock { $0?.surface }
    }

    /// Snapshot the arrival-rate metrics under the metrics lock.
    public var arrivalMetrics: ArrivalMetrics {
        metricsLock.withLock { $0 }
    }

    /// Test-only entry point: synthesise the delivery path with a caller-
    /// provided `CMSampleBuffer`. Production traffic arrives via the
    /// `SCStreamOutput` protocol method below.
    public func publishForTest(sampleBuffer: CMSampleBuffer) {
        ingest(sampleBuffer)
    }

    /// Test-only entry point: exercise the same surface-extraction path as
    /// `ingest(_:)` starting from a bare `CVPixelBuffer`, skipping the
    /// `CMSampleBuffer` wrapping which has a SDK-fragile Swift signature.
    public func publishForTest(pixelBuffer: CVPixelBuffer) {
        guard let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer) else { return }
        let surface = surfaceRef.takeUnretainedValue()
        publish(surface: surface)
    }

    /// Test-only: drive the arrival-rate EMA from an explicit timestamp
    /// stream so `adaptive_mode_switch_tests.swift` can assert mode
    /// transitions deterministically without scheduling real frames.
    public func publishForTest(syntheticIngestHostTime: CFTimeInterval) {
        updateArrival(at: syntheticIngestHostTime)
    }

    // MARK: - SCStreamOutput

    public func stream(
        _: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        ingest(sampleBuffer)
    }

    // MARK: - SCStreamDelegate

    public func stream(_: SCStream, didStopWithError error: any Error) {
        log.error("SCStream stopped: \(error.localizedDescription)")
        let handler = handlerLock.withLock { $0.stopErrorHandler }
        handler?(error)
    }

    // MARK: - Private

    private func ingest(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer) else { return }
        let surface = surfaceRef.takeUnretainedValue()
        publish(surface: surface)
    }

    private func publish(surface: IOSurface) {
        ingestedCounterLock.withLock { $0 += 1 }
        let now = CACurrentMediaTime()
        let isFirst = lock.withLock { state in
            let wasEmpty = state == nil
            state = CapturedSurface(surface: surface, ingestHostTime: now)
            return wasEmpty
        }
        // One-shot arrival marker: proves capture-side frame flow in the
        // log without per-frame log volume.
        if isFirst {
            log.notice("first frame ingested (\(IOSurfaceGetWidth(surface))x\(IOSurfaceGetHeight(surface)))")
        }
        updateArrival(at: now)
        let onArrival = handlerLock.withLock { $0.onArrival }
        onArrival?()
    }

    /// EMA update for inter-arrival intervals. Alpha 0.1 trades some
    /// reactivity for less jitter; the adaptive-mode logic only acts on
    /// sustained changes so a slow EMA is preferred.
    private func updateArrival(at hostTime: CFTimeInterval) {
        metricsLock.withLock { metrics in
            defer {
                metrics.lastIngestHostTime = hostTime
                metrics.sampleCount += 1
            }
            guard metrics.lastIngestHostTime > 0 else { return }
            let delta = hostTime - metrics.lastIngestHostTime
            guard delta > 0 else { return }
            if metrics.intervalEMA == 0 {
                metrics.intervalEMA = delta
            } else {
                let alpha = 0.1
                metrics.intervalEMA = alpha * delta + (1 - alpha) * metrics.intervalEMA
            }
        }
    }
}
