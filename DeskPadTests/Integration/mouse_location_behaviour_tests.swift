//
//  mouse_location_behaviour_tests.swift
//  DeskPadTests
//
//  @agents-index Asserts the CR-0001 Test Strategy row
//  `testMouseHighlightAndClickToWarpUnchanged`: the mouse-location
//  helpers (action and side-effect timer) are still importable and the
//  ReSwift action shape used by click-to-warp is unchanged (FR-12,
//  AC-12). This is a compile-time / shape contract, not a UI
//  end-to-end test.
//

import XCTest

@testable import DeskPad

final class MouseLocationBehaviourTests: XCTestCase {
    func testMouseHighlightAndClickToWarpUnchanged() {
        // The click-to-warp dispatch in `ScreenViewController` sends
        // `MouseLocationAction.requestMove(toPoint:)`. Build one
        // explicitly so a rename or signature change fails this test.
        let point = NSPoint(x: 42, y: 24)
        let action = MouseLocationAction.requestMove(toPoint: point)
        switch action {
        case let .requestMove(toPoint: emitted):
            XCTAssertEqual(emitted, point)
        default:
            XCTFail("requestMove case not preserved")
        }
    }
}
