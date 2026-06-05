//
//  avsbdl_spy_renderer.swift
//  DeskPadTests
//
//  @agents-index CR-0002 Phase 2 test support: spy implementation of
//  `AVSBDLSampleBufferRendering` used by every `avsbdl_backend_*` test.
//  Records every `enqueueSampleBuffer(_:)` and
//  `flushWithRemovalOfDisplayedImage(_:completion:)` call so tests can
//  assert FR-7, FR-10, FR-11, FR-12, FR-13 behaviour without
//  instantiating a real `AVSampleBufferDisplayLayer`.
//

import AppKit
import CoreMedia
import Foundation

@testable import DeskPad

@MainActor
final class SpyAVSBDLRenderer: AVSBDLSampleBufferRendering {
    var stubbedReady: Bool = true
    private(set) var enqueued: [CMSampleBuffer] = []
    private(set) var flushCalls: [(removeImage: Bool, completed: Bool)] = []

    var isReadyForMoreMediaData: Bool { stubbedReady }

    func enqueueSampleBuffer(_ buffer: CMSampleBuffer) {
        enqueued.append(buffer)
    }

    func flushWithRemovalOfDisplayedImage(_ removeImage: Bool, completion: @escaping @Sendable () -> Void) {
        flushCalls.append((removeImage: removeImage, completed: false))
        completion()
        // Mark the most recent call as completed for assertion convenience.
        let idx = flushCalls.count - 1
        flushCalls[idx] = (removeImage: removeImage, completed: true)
    }
}
