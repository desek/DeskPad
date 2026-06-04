//
//  capture.stream_output.swift
//  DeskPad
//
//  @agents-index `SCStreamOutput` + `SCStreamDelegate` implementation that
//  extracts the zero-copy `IOSurface` from each delivered `CMSampleBuffer` via
//  `CVPixelBufferGetIOSurface` and atomically publishes it for the renderer
//  to consume on the next display-link tick.
//
//  Only the most recent surface matters — DeskPad mirrors, it does not
//  buffer — so the publish slot is a single atomic reference rather than a
//  queue. The renderer reads via `latestSurface` from the main / render
//  thread; the SCK output queue writes here from a background queue. The
//  cross-thread hand-off goes through an `OSAllocatedUnfairLock` so the
//  swap is a couple of nanoseconds with no allocation.
//

import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import IOSurface
import os
import ScreenCaptureKit

/// Stream output that captures the most recent `IOSurface` delivered by an
/// `SCStream` and exposes it via `latestSurface`. Also reports delegate
/// errors (`SCStreamDelegate.stream(_:didStopWithError:)`) by invoking
/// `onStopError` so the coordinator can drive backoff/restart.
///
/// Marked `@unchecked Sendable` because it is reference type whose mutable
/// state is guarded entirely by `lock`; this is the established pattern for
/// SCK output classes that need to be retained by `SCStream` (which is itself
/// Objective-C and not `Sendable`).
public final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Closure invoked when the stream stops with an error. Captured by the
    /// coordinator to drive exponential-backoff restart.
    public typealias StopErrorHandler = @Sendable (any Error) -> Void

    private let log = Logger(category: "capture")
    private let lock = OSAllocatedUnfairLock<IOSurface?>(initialState: nil)
    private let stopErrorHandler: StopErrorHandler?

    /// Build a stream output.
    ///
    /// - Parameter onStopError: Invoked from the SCK delegate queue when the
    ///   stream reports an unrecoverable error. The closure is responsible
    ///   for any thread-hop; the call site here makes no assumptions.
    public init(onStopError: StopErrorHandler? = nil) {
        stopErrorHandler = onStopError
        super.init()
    }

    /// Latest `IOSurface` published by the SCK output queue, or `nil` if no
    /// frame has yet been delivered. Snapshotted under `lock`; the returned
    /// reference is retained, so the caller can safely consume it after the
    /// lock has been released.
    public var latestSurface: IOSurface? {
        lock.withLock { $0 }
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
        lock.withLock { $0 = surface }
    }

    // MARK: - SCStreamOutput

    /// SCK delivery callback. Only `.screen` samples carry pixel data; audio
    /// and microphone outputs are ignored because DeskPad does not capture
    /// them.
    public func stream(
        _: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        ingest(sampleBuffer)
    }

    // MARK: - SCStreamDelegate

    /// SCK delegate callback fired when the stream stops (gracefully or
    /// otherwise). Forwarded verbatim to the configured stop-error handler.
    public func stream(_: SCStream, didStopWithError error: any Error) {
        log.error("SCStream stopped: \(error.localizedDescription)")
        stopErrorHandler?(error)
    }

    // MARK: - Private

    /// Extract the `IOSurface` from `sampleBuffer` (via
    /// `CVPixelBufferGetIOSurface`) and atomically publish it. Drops the
    /// sample silently if it lacks an attached surface; this can happen for
    /// the first frame on some macOS revisions.
    private func ingest(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer) else { return }
        let surface = surfaceRef.takeUnretainedValue()
        lock.withLock { $0 = surface }
    }
}
