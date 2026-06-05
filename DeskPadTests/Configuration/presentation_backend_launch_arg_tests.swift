//
//  presentation_backend_launch_arg_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0002 Phase 3 / AC-5: the launch argument overrides
//  `UserDefaults` for the current launch and does not persist.
//

import Foundation
import XCTest

@testable import DeskPad

final class PresentationBackendLaunchArgTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "DeskPadTests.presentation_backend.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testLaunchArgOverridesUserDefaults() {
        let defaults = freshDefaults()
        defaults.set("metal", forKey: PresentationBackendKey.userDefaultsKey)
        let args = ["DeskPad", PresentationBackendKey.launchArgumentFlag, "avsbdl"]
        let selection = PresentationBackendKey.resolve(arguments: args, defaults: defaults)
        XCTAssertEqual(selection.identifier, .avsbdl)
        XCTAssertEqual(selection.source, .launchArgument)
        // Persisted value is unchanged: resolve(_:_:) MUST be read-only.
        XCTAssertEqual(
            defaults.string(forKey: PresentationBackendKey.userDefaultsKey), "metal"
        )
    }
}
