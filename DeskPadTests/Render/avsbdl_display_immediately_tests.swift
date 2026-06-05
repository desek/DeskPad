//
//  avsbdl_display_immediately_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0002 Phase 2 Test Strategy row
//  `testDisplayImmediatelyAttachmentApplied`: verifies the helper sets
//  `kCMSampleAttachmentKey_DisplayImmediately = kCFBooleanTrue` on the
//  first attachments dictionary (CR-0002 FR-8, AC-9).
//

import CoreMedia
import XCTest

@testable import DeskPad

@MainActor
final class AVSBDLDisplayImmediatelyTests: XCTestCase {
    func testDisplayImmediatelyAttachmentApplied() throws {
        let buffer = try AVSBDLTestBuffers.make()
        XCTAssertTrue(applyDisplayImmediatelyAttachment(buffer))

        let array = try XCTUnwrap(
            CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
        )
        XCTAssertGreaterThan(CFArrayGetCount(array), 0)
        let raw = CFArrayGetValueAtIndex(array, 0)
        let dict = unsafeBitCast(raw, to: CFDictionary.self)
        let key = unsafeBitCast(kCMSampleAttachmentKey_DisplayImmediately, to: UnsafeRawPointer.self)
        let value = CFDictionaryGetValue(dict, key)
        XCTAssertNotNil(value)
        let bool = unsafeBitCast(value, to: CFBoolean.self)
        XCTAssertTrue(CFBooleanGetValue(bool))
    }
}
