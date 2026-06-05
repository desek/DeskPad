//
//  render.avsbdl_display_immediately_attachment.swift
//  DeskPad
//
//  @agents-index CR-0002 Phase 2: helper that stamps a
//  `CMSampleBuffer` with
//  `kCMSampleAttachmentKey_DisplayImmediately = kCFBooleanTrue` on its
//  first attachments dictionary, so the AVSBDL backend's
//  `AVSampleBufferVideoRenderer` presents each captured frame as soon as
//  it is decoded rather than scheduling it against a PTS timebase that
//  DeskPad's live-mirror source does not maintain. Cited:
//  `CMSampleBuffer.h:1518` (the attachment key) and
//  `AVSampleBufferDisplayLayer.h:117, .h:128, .h:137` (display-immediately
//  is the documented mode for live mirror sources without a control
//  timebase or a synchronizer, and **MUST NOT** be combined with one;
//  CR-0002 FR-8 and FR-9).
//

import CoreMedia
import Foundation

/// Sets `kCMSampleAttachmentKey_DisplayImmediately` to `kCFBooleanTrue`
/// on the first per-sample attachments dictionary of `sampleBuffer`.
///
/// - Parameter sampleBuffer: an `IOSurface`-backed `CMSampleBuffer`
///   delivered by the capture subsystem.
/// - Returns: `true` when the attachment was applied successfully,
///   `false` if the attachments array could not be obtained or was
///   empty. The boolean is intentionally surfaced so the AVSBDL backend
///   can decide whether to enqueue (per CR-0002 FR-8 the attachment is
///   required); the backend treats `false` as a drop.
/// - Side effects: mutates the `CMSampleBuffer`'s sample attachments
///   array via `CMSampleBufferGetSampleAttachmentsArray(_, true)` plus
///   `CFDictionarySetValue`, exactly as documented at
///   `AVSampleBufferDisplayLayer.h:128`. Zero-copy on the pixel data.
@discardableResult
public func applyDisplayImmediatelyAttachment(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer, createIfNecessary: true
    ) else {
        return false
    }
    let count = CFArrayGetCount(attachmentsArray)
    guard count > 0 else { return false }
    // The attachments array is a CFArray of mutable CFDictionaryRef.
    let raw = CFArrayGetValueAtIndex(attachmentsArray, 0)
    guard let raw else { return false }
    let dict = unsafeBitCast(raw, to: CFMutableDictionary.self)
    let key = unsafeBitCast(kCMSampleAttachmentKey_DisplayImmediately, to: UnsafeRawPointer.self)
    let value = unsafeBitCast(kCFBooleanTrue, to: UnsafeRawPointer.self)
    CFDictionarySetValue(dict, key, value)
    return true
}
