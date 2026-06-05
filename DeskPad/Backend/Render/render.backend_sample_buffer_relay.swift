//
//  render.backend_sample_buffer_relay.swift
//  DeskPad
//
//  @agents-index Coalescing capture-to-MainActor relay: carries the newest
//  pending `CMSampleBuffer` from the SCK delivery thread to the active
//  `PresentationBackend.enqueue(_:)` with at most one in-flight Task,
//  replacing the per-frame `Task { @MainActor }` allocation (CR-0002
//  energy fix, docs/cr/CR-0002-repl.md).
//

import CoreMedia
import Foundation
import os

/// `CMSampleBuffer` is not `Sendable` under Swift 6 strict concurrency.
/// The relay owns the buffer from the moment the SCK callback hands it
/// over until the MainActor sink consumes it; the wrapper documents that
/// single-owner hand-off across the actor hop.
private struct UncheckedSampleBuffer: @unchecked Sendable {
    let buffer: CMSampleBuffer
}

/// Coalesces capture-thread `CMSampleBuffer` pushes into MainActor
/// deliveries with newest-frame-wins semantics and at most one scheduled
/// hop at a time.
///
/// Why: wiring `StreamOutput.setOnSampleBuffer` directly to
/// `Task { @MainActor in backend.enqueue(buffer) }` allocates one Task
/// (plus actor-queue churn) per captured frame, at the full capture rate.
/// The relay keeps a single pending slot under an unfair lock: pushes
/// overwrite the slot, and only the first push after a drain schedules a
/// hop. The MainActor drain loop keeps consuming until the slot is empty,
/// so a burst of N frames costs one Task and delivers only the newest
/// content, mirroring the capture path's newest-frame-wins policy.
public final class BackendSampleBufferRelay: @unchecked Sendable {
    /// Slot state: the newest undelivered buffer plus whether a drain
    /// hop is already scheduled or running.
    private struct Slot {
        var pending: UncheckedSampleBuffer?
        var hopScheduled = false
    }

    private let slot = OSAllocatedUnfairLock<Slot>(initialState: Slot())
    /// Sink the drain loop feeds; the coordinator points this at
    /// `currentBackend.enqueue(_:)` so a live backend switch is picked
    /// up by the very next delivery. Declared as a plain closure (not a
    /// `@MainActor` function type) but invoked exclusively from the
    /// MainActor drain hop via `MainActor.assumeIsolated`, which is the
    /// CR-0002 FR-2 sanctioned callback-context form of the actor hop.
    private let sink: SinkBox

    /// `@unchecked Sendable` box for the MainActor-only sink closure.
    /// The closure is constructed on the MainActor (coordinator init)
    /// and only ever invoked on the MainActor (the drain hop); the box
    /// exists purely so the relay itself can be `Sendable`.
    private final class SinkBox: @unchecked Sendable {
        let call: (CMSampleBuffer) -> Void
        init(_ call: @escaping (CMSampleBuffer) -> Void) { self.call = call }
    }

    /// - Parameter sink: consumer for each drained buffer; always
    ///   invoked on the MainActor.
    @MainActor
    public init(sink: @escaping (CMSampleBuffer) -> Void) {
        self.sink = SinkBox(sink)
    }

    /// Push one captured buffer from any thread. Overwrites any
    /// undelivered buffer (newest-frame-wins) and schedules the single
    /// MainActor drain hop if none is in flight.
    public func push(_ buffer: CMSampleBuffer) {
        // Wrap before entering the `@Sendable` lock closure; the bare
        // `CMSampleBuffer` must not be captured there under Swift 6.
        let wrapped = UncheckedSampleBuffer(buffer: buffer)
        let shouldSchedule = slot.withLock { state -> Bool in
            state.pending = wrapped
            guard !state.hopScheduled else { return false }
            state.hopScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        Task { @MainActor [self] in drain() }
    }

    /// Drain loop on the MainActor: deliver the pending buffer, then
    /// re-check the slot; frames pushed while the sink ran are consumed
    /// by the same hop. Clears `hopScheduled` only when the slot is
    /// observed empty, so no push is ever stranded.
    @MainActor
    private func drain() {
        while true {
            let next = slot.withLock { state -> UncheckedSampleBuffer? in
                guard let pending = state.pending else {
                    state.hopScheduled = false
                    return nil
                }
                state.pending = nil
                return pending
            }
            guard let next else { return }
            sink.call(next.buffer)
        }
    }
}
