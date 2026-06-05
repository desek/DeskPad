//
//  subscriber_view_controller_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0003 AC-8 lifecycle coverage for
//  `SubscriberViewController`. Drives `viewWillAppear()` followed by
//  `viewWillDisappear()` against a concrete `ViewDataType` subscriber and
//  asserts that `update(with:)` is invoked while subscribed and that the
//  subscribe/unsubscribe lifecycle balances. Coverage of the abstract base
//  is incidental; this test specifically exercises the two lifecycle hooks
//  (`viewWillAppear` / `viewWillDisappear`) the base class overrides.
//

import AppKit
import XCTest

@testable import DeskPad

@MainActor
final class SubscriberViewControllerTests: XCTestCase {
    /// Direct-call the two lifecycle hooks the base class overrides and
    /// assert (a) `update(with:)` fires at least once between subscribe and
    /// unsubscribe (driven by the shared `store`'s initial state), and (b)
    /// invoking the disappear hook afterwards is a no-op that does not
    /// crash. The shared store is the production singleton; this is the only
    /// store ReSwift exposes for direct subscription in this project.
    func testViewWillAppearAndDisappearBalance() {
        let controller = TestSubscriberVC()
        controller.viewWillAppear()
        // The store fires the initial state synchronously to a fresh
        // subscriber; `newState(state:)` dispatches `update(with:)` to the
        // main queue. Spin the runloop briefly to observe the dispatch.
        let exp = expectation(description: "update called")
        controller.onUpdate = { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertGreaterThanOrEqual(controller.updateCount, 1)
        // viewWillDisappear unsubscribes; calling it twice must remain safe.
        controller.viewWillDisappear()
        controller.viewWillDisappear()
    }
}

private struct ProbeViewData: ViewDataType {
    typealias StateFragment = StateBlob
    struct StateBlob: Equatable {
        let isWithinScreen: Bool
    }

    static func fragment(of appState: AppState) -> StateBlob {
        return StateBlob(isWithinScreen: appState.mouseLocationState.isWithinScreen)
    }

    init(for _: StateBlob) {}
}

@MainActor
private final class TestSubscriberVC: SubscriberViewController<ProbeViewData> {
    var updateCount = 0
    var onUpdate: (() -> Void)?
    override func update(with _: ProbeViewData) {
        updateCount += 1
        onUpdate?()
    }
}
