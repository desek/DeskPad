//
//  render.avsbdl_system_renderer_adapter.swift
//  DeskPad
//
//  @agents-index CR-0002 Phase 2 / Phase 4 split: production adapter that
//  conforms a real `AVSampleBufferVideoRenderer` to the test seam
//  `AVSBDLSampleBufferRendering` used by `AVSBDLBackend`. This adapter is
//  the only file in the project that calls the modern
//  `enqueue(_:)` and
//  `flush(removingDisplayedImage:completionHandler:)` methods on the
//  system renderer, keeping the deprecated layer-level API surface
//  (per `AVSampleBufferDisplayLayer.h` lines 94..226) entirely unused
//  (CR-0002 FR-7, AC-8). Extracted from `render.avsbdl_backend.swift`
//  in Phase 4 to keep both files under the project's 200-line
//  small-file convention.
//

import AVFoundation
import CoreMedia
import Foundation

/// Production adapter that conforms an `AVSampleBufferVideoRenderer` to
/// the `AVSBDLSampleBufferRendering` protocol the backend talks to.
@MainActor
final class AVSBDLSystemRendererAdapter: AVSBDLSampleBufferRendering {
    private let renderer: AVSampleBufferVideoRenderer

    init(renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
    }

    var isReadyForMoreMediaData: Bool { renderer.isReadyForMoreMediaData }

    func enqueueSampleBuffer(_ buffer: CMSampleBuffer) {
        renderer.enqueue(buffer)
    }

    func flushWithRemovalOfDisplayedImage(_ removeImage: Bool, completion: @escaping @Sendable () -> Void) {
        renderer.flush(removingDisplayedImage: removeImage, completionHandler: completion)
    }
}
