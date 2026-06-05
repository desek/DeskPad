//
//  presentation_backend_default_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0002 Phase 3 / AC-3 / AC-6: with no override the
//  bootstrap-registered default resolves to `"metal"`.
//

import Foundation
import XCTest

@testable import DeskPad

final class PresentationBackendDefaultTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "DeskPadTests.presentation_backend.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultIsMetalWhenNoUserDefault() {
        let defaults = freshDefaults()
        PresentationBackendDefaultsBootstrap.register(into: defaults)
        let selection = PresentationBackendKey.resolve(arguments: [], defaults: defaults)
        XCTAssertEqual(selection.identifier, .metal)
        // Bootstrap-registered defaults appear in the registration
        // domain, so a `string(forKey:)` returns "metal".
        XCTAssertEqual(
            defaults.string(forKey: PresentationBackendKey.userDefaultsKey), "metal"
        )
    }
}
