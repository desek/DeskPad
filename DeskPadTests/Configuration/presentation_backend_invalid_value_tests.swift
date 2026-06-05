//
//  presentation_backend_invalid_value_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0002 Phase 3 / AC-6 / FR-4: an invalid value in
//  either source falls back to `"metal"` and is surfaced via the
//  `source = .fallbackInvalidValue` + `rawInvalidValue` fields so the
//  caller can log it.
//

import Foundation
import XCTest

@testable import DeskPad

final class PresentationBackendInvalidValueTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "DeskPadTests.presentation_backend.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testInvalidValueInUserDefaultsFallsBackToMetal() {
        let defaults = freshDefaults()
        defaults.set("glsl", forKey: PresentationBackendKey.userDefaultsKey)
        let selection = PresentationBackendKey.resolve(arguments: [], defaults: defaults)
        XCTAssertEqual(selection.identifier, .metal)
        XCTAssertEqual(selection.source, .fallbackInvalidValue)
        XCTAssertEqual(selection.rawInvalidValue, "glsl")
    }

    func testInvalidValueInLaunchArgFallsBackToMetal() {
        let defaults = freshDefaults()
        defaults.set("avsbdl", forKey: PresentationBackendKey.userDefaultsKey)
        let args = ["DeskPad", PresentationBackendKey.launchArgumentFlag, "vulkan"]
        let selection = PresentationBackendKey.resolve(arguments: args, defaults: defaults)
        XCTAssertEqual(selection.identifier, .metal)
        XCTAssertEqual(selection.source, .fallbackInvalidValue)
        XCTAssertEqual(selection.rawInvalidValue, "vulkan")
    }
}
