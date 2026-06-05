//
//  loopback_pattern_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0003 Phase 4 tests for the Layer 3 loopback pattern. The
//  pattern is the ground truth for the FR-12 / FR-13 sample-point assertions,
//  so the tests focus on (a) determinism: the same `frameIndex` must produce
//  the same `(R, G, B)` triple every time, and (b) tolerance math: triples
//  exactly at the configured tolerance boundary match, triples one level
//  beyond do not. The full read-back round trip is exercised by
//  `readback_tests.swift`; this file pins the pattern surface itself.
//

import XCTest

@testable import DeskPad

final class SelfTestLoopbackPatternTests: XCTestCase {
    // MARK: (a) Determinism

    func testExpectedColorIsDeterministicForGivenFrame() {
        let width = 256, height = 192
        for point in SelfTestLoopbackPattern.defaultSamplePoints {
            let first = SelfTestLoopbackPattern.expectedColor(
                at: point, frameIndex: 42, width: width, height: height
            )
            let second = SelfTestLoopbackPattern.expectedColor(
                at: point, frameIndex: 42, width: width, height: height
            )
            XCTAssertEqual(first, second, "pattern must be deterministic at \(point.name)")
        }
    }

    func testFrameIndexChangesBlueChannel() {
        let p = SelfTestSamplePoint(name: "p", x: 10, y: 10)
        let c0 = SelfTestLoopbackPattern.expectedColor(
            at: p, frameIndex: 0, width: 256, height: 192
        )
        let c1 = SelfTestLoopbackPattern.expectedColor(
            at: p, frameIndex: 1, width: 256, height: 192
        )
        XCTAssertEqual(c0.r, c1.r)
        XCTAssertEqual(c0.g, c1.g)
        XCTAssertNotEqual(c0.b, c1.b, "frame counter must drive the blue channel")
    }

    func testRenderBGRABytesMatchPerPixelExpectations() {
        let width = 8, height = 4, frameIndex = 17
        let bytes = SelfTestLoopbackPattern.renderBGRA(
            width: width, height: height, frameIndex: frameIndex
        )
        XCTAssertEqual(bytes.count, width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let expected = SelfTestLoopbackPattern.expectedColor(
                    x: x, y: y, frameIndex: frameIndex, width: width, height: height
                )
                let i = (y * width + x) * 4
                XCTAssertEqual(bytes[i], expected.b, "B mismatch at (\(x),\(y))")
                XCTAssertEqual(bytes[i + 1], expected.g, "G mismatch at (\(x),\(y))")
                XCTAssertEqual(bytes[i + 2], expected.r, "R mismatch at (\(x),\(y))")
                XCTAssertEqual(bytes[i + 3], 255, "alpha must be opaque")
            }
        }
    }

    // MARK: (b) Tolerance math

    func testToleranceAcceptsBoundaryDeviation() {
        let expected = SelfTestColor(r: 100, g: 100, b: 100)
        let tolerance = SelfTestLoopbackPattern.kTolerance
        let bumped = SelfTestColor(
            r: UInt8(100 + tolerance),
            g: UInt8(100 - tolerance),
            b: UInt8(100 + tolerance)
        )
        XCTAssertTrue(
            SelfTestLoopbackPattern.matches(expected: expected, actual: bumped),
            "actual within ±\(tolerance) on every channel must match"
        )
    }

    func testToleranceRejectsOneLevelOver() {
        let expected = SelfTestColor(r: 100, g: 100, b: 100)
        let tolerance = SelfTestLoopbackPattern.kTolerance
        let bumped = SelfTestColor(
            r: UInt8(100 + tolerance + 1),
            g: 100,
            b: 100
        )
        XCTAssertFalse(
            SelfTestLoopbackPattern.matches(expected: expected, actual: bumped),
            "single channel one level past tolerance must fail"
        )
    }

    func testToleranceHandlesUnsignedUnderflow() {
        // 0 vs 8 is within tolerance; underflow on UInt8 must not crash.
        let expected = SelfTestColor(r: 0, g: 0, b: 0)
        let actual = SelfTestColor(r: 8, g: 0, b: 0)
        XCTAssertTrue(SelfTestLoopbackPattern.matches(expected: expected, actual: actual))
    }

    // MARK: Mismatch reason string

    func testMismatchReasonIsStableAndParseable() {
        let point = SelfTestSamplePoint(name: "p", x: 7, y: 9)
        let expected = SelfTestColor(r: 10, g: 20, b: 30)
        let actual = SelfTestColor(r: 11, g: 21, b: 31)
        let reason = SelfTestReadback.mismatchReason(
            kind: "present_mismatch_at_point",
            point: point, expected: expected, actual: actual
        )
        XCTAssertEqual(
            reason,
            "loopback: present_mismatch_at_point=(7,9) expected=(10,20,30) actual=(11,21,31)"
        )
    }

    // MARK: sampleBGRA helper

    func testSampleBGRAReadsTheConfiguredPixel() {
        let width = 4, height = 2
        let bytes = SelfTestLoopbackPattern.renderBGRA(
            width: width, height: height, frameIndex: 3
        )
        let sampled = SelfTestReadback.sampleBGRA(
            bytes: bytes, width: width, height: height, x: 1, y: 1
        )
        let expected = SelfTestLoopbackPattern.expectedColor(
            x: 1, y: 1, frameIndex: 3, width: width, height: height
        )
        XCTAssertEqual(sampled, expected)
    }

    func testSampleBGRAReturnsNilOutOfBounds() {
        let bytes = SelfTestLoopbackPattern.renderBGRA(width: 2, height: 2, frameIndex: 0)
        XCTAssertNil(SelfTestReadback.sampleBGRA(
            bytes: bytes, width: 2, height: 2, x: 5, y: 5
        ))
        XCTAssertNil(SelfTestReadback.sampleBGRA(
            bytes: bytes, width: 2, height: 2, x: -1, y: 0
        ))
    }
}
