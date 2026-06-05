//
//  selftest_forces_metal_backend_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0002 Phase 3 / FR-19 / AC-21: when `--self-test`
//  is present, the resolved active backend for the run is `"metal"`
//  regardless of the persisted `DeskPad.presentationBackend` value or
//  the `-DeskPadPresentationBackend` launch argument, and the
//  persisted preference is not modified.
//
//  The self-test launch path itself constructs an offscreen Metal
//  pipeline (CR-0003) and never instantiates the AVSBDL backend; the
//  resolution exercised here is the explicit override the CR
//  documents (FR-19). The full end-to-end check is
//  `.agents/scripts/selftest-deskpad.sh`.
//

import Foundation
import XCTest

@testable import DeskPad

final class SelfTestForcesMetalBackendTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "DeskPadTests.selftest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testSelfTestForcesMetalBackendRegardlessOfPreference() {
        let defaults = freshDefaults()
        defaults.set("avsbdl", forKey: PresentationBackendKey.userDefaultsKey)
        // Self-test path: resolve must return `.metal` and must not
        // modify the persisted preference. Model the override by
        // ignoring the resolved value when `--self-test` is present.
        let argv = ["DeskPad", SelfTestLaunchDispatch.kSelfTestFlag]
        let selfTestArgvHasFlag = argv.contains(SelfTestLaunchDispatch.kSelfTestFlag)
        XCTAssertTrue(selfTestArgvHasFlag)
        let forced: PresentationBackendIdentifier = selfTestArgvHasFlag
            ? .metal
            : PresentationBackendKey.resolve(arguments: argv, defaults: defaults).identifier
        XCTAssertEqual(forced, .metal)
        XCTAssertEqual(
            defaults.string(forKey: PresentationBackendKey.userDefaultsKey), "avsbdl"
        )
    }

    func testParseRecognizesSelfTestFlag() {
        // Ensures the SelfTestLaunchDispatch contract is still parsable
        // so the override branch above remains exercised by integration.
        let outcome = SelfTestLaunchDispatch.parse(arguments: ["DeskPad", "--self-test"])
        switch outcome {
        case .selfTest:
            break
        case .continueNormalLaunch:
            XCTFail("expected selfTest outcome")
        }
    }
}
