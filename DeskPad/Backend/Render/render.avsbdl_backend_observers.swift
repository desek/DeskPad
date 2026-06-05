//
//  render.avsbdl_backend_observers.swift
//  DeskPad
//
//  @agents-index CR-0002 gap-fix split-out of the `AVSBDLBackend` KVO
//  + notification observer installation routines and the rate-limited
//  drop logger. Kept in a separate file so `render.avsbdl_backend.swift`
//  honours the project's 200-LOC small-file convention (NFR-3, AC-18).
//

import AVFoundation
import Foundation

/// CR-0002 Phase 2 helpers. The closures are factored as `internal`
/// extension methods on `AVSBDLBackend` so the spy and production
/// constructors call into them without exposing state across files.
extension AVSBDLBackend {
    /// Install the `status` KVO observation. The change handler hops to
    /// the main actor before mutating backend state so it is safe to
    /// receive on whatever queue KVO posts on.
    func installKVO(on systemRenderer: AVSampleBufferVideoRenderer) {
        statusObservation = systemRenderer.observe(\.status, options: [.new]) { [weak self] rendererObj, _ in
            let status: AVQueuedSampleBufferRenderingStatus = rendererObj.status
            let description: String? = rendererObj.error?.localizedDescription
            guard status == .failed else { return }
            Task { @MainActor [weak self] in
                self?.triggerRecovery(reason: "status=failed", errorDescription: description)
            }
        }
    }

    /// Subscribe to the two `AVSampleBufferVideoRenderer` notifications
    /// that mandate the same flush-and-resume recovery per CR-0002 FR-11.
    func installNotificationObservers(for systemRenderer: AVSampleBufferVideoRenderer) {
        let center = NotificationCenter.default
        let didFailToken = center.addObserver(
            forName: AVSampleBufferVideoRenderer.didFailToDecodeNotification,
            object: systemRenderer, queue: .main
        ) { [weak self] note in
            let errorDescription = (note.userInfo?[AVSampleBufferVideoRenderer.didFailToDecodeNotificationErrorKey] as? NSError)?.localizedDescription
            Task { @MainActor [weak self] in
                self?.triggerRecovery(reason: "DidFailToDecode", errorDescription: errorDescription)
            }
        }
        let flushToken = center.addObserver(
            forName: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
            object: systemRenderer, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.triggerRecovery(reason: "RequiresFlushToResumeDecoding", errorDescription: nil)
            }
        }
        notificationObservers = [didFailToken, flushToken]
    }

    /// Rate-limited (>= 1 second cadence) warning emitter for the
    /// readiness-gated drop path. CR-0002 FR-13.
    func rateLimitedLogDrop() {
        let now = Date()
        if let last = lastDropLogTime, now.timeIntervalSince(last) < 1.0 {
            return
        }
        lastDropLogTime = now
        log.warning("backend=avsbdl dropped frame: readyForMoreMediaData=false (total=\(droppedFrameCount))")
    }
}
