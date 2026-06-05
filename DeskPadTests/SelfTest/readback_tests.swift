//
//  readback_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0003 Phase 3 tests for the Layer 2 drawable read-back
//  utility. Drives `SelfTestReadback.computeStats` and `.evaluate` against
//  synthetic BGRA buffers so the verdict math is verified independently of a
//  live Metal device (the GPU blit path is incidentally exercised when a
//  device is available; otherwise the test gracefully skips that case).
//  Covers (a) uniform white -> FAIL with a variance/white-related reason,
//  (b) RGB gradient -> PASS, (c) threshold constants honoured at their
//  declared boundaries, and (d) argv parsing for the dispatcher.
//

import Metal
import XCTest

@testable import DeskPad

final class SelfTestReadbackTests: XCTestCase {
    // MARK: Synthetic buffer helpers

    /// Builds a uniform-white BGRA buffer of `pixelCount` pixels. Each pixel
    /// is (B=255, G=255, R=255, A=255), i.e. the on-disk byte pattern the
    /// CR-0001 white-window failure produced.
    private func uniformWhite(pixelCount: Int) -> [UInt8] {
        return [UInt8](repeating: 255, count: pixelCount * SelfTestReadback.kBytesPerPixel)
    }

    /// Builds a horizontal RGB gradient where channel intensity varies with
    /// pixel index, so per-channel variance is well above `kMinVariance`.
    private func rgbGradient(width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8((x * 255) / max(1, width - 1)) // B
                bytes[i + 1] = UInt8((y * 255) / max(1, height - 1)) // G
                bytes[i + 2] = UInt8(((x + y) * 255) / max(1, width + height - 2)) // R
                bytes[i + 3] = 255
            }
        }
        return bytes
    }

    // MARK: (a) Uniform white -> FAIL

    func testUniformWhiteFailsWithWhiteOrVarianceReason() {
        let bytes = uniformWhite(pixelCount: 64 * 64)
        let stats = SelfTestReadback.computeStats(bgraBytes: bytes)
        // Means clamp to 1.0 and variance to 0.0, so both FAIL clauses
        // trigger; the white-mean clause is checked first and wins.
        XCTAssertEqual(stats.meanR, 1.0, accuracy: 1e-9)
        XCTAssertEqual(stats.meanG, 1.0, accuracy: 1e-9)
        XCTAssertEqual(stats.meanB, 1.0, accuracy: 1e-9)
        XCTAssertEqual(stats.varianceR, 0.0, accuracy: 1e-9)
        let verdict = SelfTestReadback.evaluate(stats: stats)
        guard case let .fail(reason) = verdict else {
            return XCTFail("uniform white must FAIL, got \(verdict)")
        }
        XCTAssertTrue(reason.hasPrefix("uniform_white") || reason.hasPrefix("low_variance"),
                      "white frame should be reported as white or low variance, got: \(reason)")
    }

    // MARK: (b) Gradient -> PASS

    func testRgbGradientPasses() {
        let bytes = rgbGradient(width: 64, height: 64)
        let stats = SelfTestReadback.computeStats(bgraBytes: bytes)
        // Variance for a 0..255 ramp is ~1/12 on the unit scale (~0.083),
        // far above kMinVariance, so all three channels are well-varied.
        XCTAssertGreaterThan(stats.varianceR, SelfTestThresholds.kMinVariance)
        XCTAssertGreaterThan(stats.varianceG, SelfTestThresholds.kMinVariance)
        XCTAssertGreaterThan(stats.varianceB, SelfTestThresholds.kMinVariance)
        XCTAssertEqual(SelfTestReadback.evaluate(stats: stats), .pass)
    }

    // MARK: (c) Threshold boundaries

    func testEvaluateAtVarianceBoundary() {
        // Variance exactly at the boundary is treated as FAIL (the rule is
        // strict-greater per FR-10: variance MUST be strictly greater than
        // kMinVariance). Means are mid-grey so the white-mean clause does
        // not engage.
        let stats = SelfTestPixelStats(
            meanR: 0.5, meanG: 0.5, meanB: 0.5,
            varianceR: SelfTestThresholds.kMinVariance,
            varianceG: SelfTestThresholds.kMinVariance,
            varianceB: SelfTestThresholds.kMinVariance
        )
        guard case let .fail(reason) = SelfTestReadback.evaluate(stats: stats) else {
            return XCTFail("variance exactly at kMinVariance must FAIL")
        }
        XCTAssertTrue(reason.hasPrefix("low_variance"), reason)
    }

    func testEvaluateJustAboveVarianceBoundaryPasses() {
        let bump = SelfTestThresholds.kMinVariance + 1e-6
        let stats = SelfTestPixelStats(
            meanR: 0.5, meanG: 0.5, meanB: 0.5,
            varianceR: bump, varianceG: bump, varianceB: bump
        )
        XCTAssertEqual(SelfTestReadback.evaluate(stats: stats), .pass)
    }

    func testEvaluateAtWhiteMeanBoundaryFails() {
        // Mean inside the tolerance band (just shy of the boundary, to
        // avoid float-rounding ambiguity at the `<=` edge) trips the
        // white-mean clause regardless of variance.
        let near = 1.0 - SelfTestThresholds.kWhiteMeanTolerance / 2.0
        let stats = SelfTestPixelStats(
            meanR: near, meanG: near, meanB: near,
            varianceR: 0.1, varianceG: 0.1, varianceB: 0.1
        )
        guard case let .fail(reason) = SelfTestReadback.evaluate(stats: stats) else {
            return XCTFail("mean at white-tolerance boundary must FAIL")
        }
        XCTAssertTrue(reason.hasPrefix("uniform_white"), reason)
    }

    func testEvaluateOutsideWhiteToleranceWithVariancePasses() {
        // One channel pulled below the white-tolerance band, with all
        // variances above the floor, must PASS.
        let stats = SelfTestPixelStats(
            meanR: 1.0 - SelfTestThresholds.kWhiteMeanTolerance * 4.0,
            meanG: 1.0,
            meanB: 1.0,
            varianceR: 0.01, varianceG: 0.01, varianceB: 0.01
        )
        XCTAssertEqual(SelfTestReadback.evaluate(stats: stats), .pass)
    }

    // MARK: Argv dispatch

    func testDispatchIgnoresArgvWithoutFlag() {
        let outcome = SelfTestLaunchDispatch.parse(arguments: ["DeskPad", "--other"])
        XCTAssertEqual(outcome, .continueNormalLaunch)
    }

    func testDispatchParsesSelfTestFlag() {
        let outcome = SelfTestLaunchDispatch.parse(arguments: ["DeskPad", "--self-test"])
        XCTAssertEqual(outcome, .selfTest(SelfTestConfig(frames: SelfTestConfig.kDefaultFrames)))
    }

    func testDispatchParsesFrameOverride() {
        let outcome = SelfTestLaunchDispatch.parse(
            arguments: ["DeskPad", "--self-test", "--self-test-frames=120"]
        )
        XCTAssertEqual(outcome, .selfTest(SelfTestConfig(frames: 120)))
    }

    func testDispatchFallsBackOnMalformedFrameOverride() {
        let outcome = SelfTestLaunchDispatch.parse(
            arguments: ["DeskPad", "--self-test", "--self-test-frames=garbage"]
        )
        XCTAssertEqual(outcome, .selfTest(SelfTestConfig(frames: SelfTestConfig.kDefaultFrames)))
    }

    func testDispatchRejectsNonPositiveFrameOverride() {
        let outcome = SelfTestLaunchDispatch.parse(
            arguments: ["DeskPad", "--self-test", "--self-test-frames=0"]
        )
        XCTAssertEqual(outcome, .selfTest(SelfTestConfig(frames: SelfTestConfig.kDefaultFrames)))
    }

    // MARK: Optional GPU readback path

    /// When a Metal device is available, blit a known gradient through the
    /// real `MTLBlitCommandEncoder` path and confirm the read-back bytes
    /// reduce to a PASS verdict end-to-end. This guards the format check
    /// and the buffer plumbing; the math is already covered above.
    func testGpuReadbackOnGradientTexturePasses() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this host")
        }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let width = 32, height = 32
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .bgra8Unorm
        descriptor.width = width
        descriptor.height = height
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let bytes = rgbGradient(width: width, height: height)
        bytes.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0,
                            withBytes: raw.baseAddress!,
                            bytesPerRow: width * 4)
        }
        let readBytes = try SelfTestReadback.readBack(texture: texture, commandQueue: queue)
        XCTAssertEqual(readBytes.count, width * height * 4)
        let stats = SelfTestReadback.computeStats(bgraBytes: readBytes)
        XCTAssertEqual(SelfTestReadback.evaluate(stats: stats), .pass)
    }

    func testGpuReadbackRejectsNonBgraTexture() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this host")
        }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = 8
        descriptor.height = 8
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        XCTAssertThrowsError(try SelfTestReadback.readBack(texture: texture, commandQueue: queue)) { error in
            XCTAssertEqual(error as? SelfTestReadbackError, .unsupportedPixelFormat)
        }
    }
}
