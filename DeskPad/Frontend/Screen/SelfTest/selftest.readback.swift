//
//  selftest.readback.swift
//  DeskPad
//
//  @agents-index CR-0003 Phase 3 Layer 2 drawable read-back utility. Blit-copies
//  a presented BGRA `MTLTexture` into a CPU-readable `MTLStorageMode.shared`
//  `MTLBuffer`, reduces the buffer to per-channel mean and variance, and
//  evaluates the result against the named PASS/FAIL thresholds defined here so
//  future tuning is a one-line change. The white-window failure class is the
//  primary regression target (FR-10): a uniform white drawable must be
//  classified `FAIL` because both its variance is below `kMinVariance` and its
//  mean is within `kWhiteMeanTolerance` of (1, 1, 1).
//
//  The utility is backend-agnostic per FR-15: it takes an arbitrary `MTLTexture`
//  plus an `MTLCommandQueue`, so any presentation backend that can hand off a
//  presented texture (current `CAMetalLayer` or future `AVSampleBufferDisplayLayer`
//  per CR-0002) plugs in unchanged. No I/O is performed here; emitting the
//  verdict is `selftest.verdict_writer.swift`'s responsibility.
//

import Foundation
import Metal

/// Configurable thresholds for the Layer 2 read-back verdict (FR-10).
/// Declared at file scope as named constants so future tuning is a one-line
/// change and tests can reference them at their declared boundaries.
public enum SelfTestThresholds {
    /// Minimum per-channel variance required to PASS. A uniform image has
    /// variance 0; the white-window failure class must therefore fall below
    /// this threshold on every channel and is classified FAIL.
    public static let kMinVariance: Double = 0.0005
    /// Mean-distance tolerance to the uniform-white outcome (1.0, 1.0, 1.0).
    /// If `|mean - 1.0|` is within this on every channel, the frame is
    /// considered white and classified FAIL even if variance is non-zero.
    public static let kWhiteMeanTolerance: Double = 0.005
}

/// Per-channel statistics computed across the read-back buffer. Values are
/// unit-normalized (`UInt8 / 255.0`) so thresholds are scale-independent.
public struct SelfTestPixelStats: Equatable, Sendable {
    public let meanR: Double
    public let meanG: Double
    public let meanB: Double
    public let varianceR: Double
    public let varianceG: Double
    public let varianceB: Double

    public init(meanR: Double, meanG: Double, meanB: Double,
                varianceR: Double, varianceG: Double, varianceB: Double)
    {
        self.meanR = meanR
        self.meanG = meanG
        self.meanB = meanB
        self.varianceR = varianceR
        self.varianceG = varianceG
        self.varianceB = varianceB
    }
}

/// Outcome of a Layer 2 read-back evaluation. `reason` is non-nil iff
/// `.fail`. The reason string is stable across runs for the same underlying
/// cause so a CI runner can branch on it (FR-9 reason stability).
public enum SelfTestVerdict: Equatable, Sendable {
    case pass
    case fail(reason: String)
}

/// Errors raised by the read-back path. Distinct cases so the caller can
/// translate them into stable `FAIL: <reason>` strings.
public enum SelfTestReadbackError: Error, Equatable {
    case unsupportedPixelFormat
    case commandQueueAllocationFailed
    case stagingBufferAllocationFailed
    case blitEncoderUnavailable
    case commandBufferUnavailable
}

/// Pure read-back utility. Stateless; one entry point per responsibility so
/// tests can drive the math directly with synthetic buffers and skip Metal
/// entirely when the host has no GPU.
public enum SelfTestReadback {
    /// Bytes per BGRA8 pixel. Hard-coded because the pipeline pins
    /// `.bgra8Unorm` end-to-end; if a future backend introduces another
    /// format this constant moves with the new format check.
    public static let kBytesPerPixel: Int = 4

    /// Blits `texture` into a `.shared` `MTLBuffer` and returns its raw bytes
    /// as a BGRA byte sequence. Throws on allocation or encoding failure.
    /// - Parameter texture: a `.bgra8Unorm` texture whose contents are to be
    ///   read back. Storage mode is irrelevant; the blit lands in a freshly
    ///   allocated CPU-readable staging buffer.
    /// - Parameter commandQueue: a queue on the same device as `texture`.
    public static func readBack(texture: MTLTexture,
                                commandQueue: MTLCommandQueue) throws -> [UInt8]
    {
        guard texture.pixelFormat == .bgra8Unorm else {
            throw SelfTestReadbackError.unsupportedPixelFormat
        }
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * kBytesPerPixel
        let totalBytes = bytesPerRow * height
        let device = texture.device
        guard let staging = device.makeBuffer(length: totalBytes,
                                              options: [.storageModeShared])
        else {
            throw SelfTestReadbackError.stagingBufferAllocationFailed
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw SelfTestReadbackError.commandBufferUnavailable
        }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw SelfTestReadbackError.blitEncoderUnavailable
        }
        blit.copy(from: texture,
                  sourceSlice: 0,
                  sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: staging,
                  destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: totalBytes)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let pointer = staging.contents().assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: pointer, count: totalBytes))
    }

    /// Reduces a BGRA byte sequence to per-channel mean and variance on the
    /// unit-normalized scale. The input order is BGRA per Metal's
    /// `.bgra8Unorm` memory layout. Single-pass two-accumulator math; the
    /// pixel count is independent of dimensions so synthetic test buffers do
    /// not need a width/height.
    public static func computeStats(bgraBytes: [UInt8]) -> SelfTestPixelStats {
        let pixelCount = bgraBytes.count / kBytesPerPixel
        if pixelCount == 0 {
            return SelfTestPixelStats(meanR: 0, meanG: 0, meanB: 0,
                                      varianceR: 0, varianceG: 0, varianceB: 0)
        }
        var sumB: Double = 0, sumG: Double = 0, sumR: Double = 0
        var sumB2: Double = 0, sumG2: Double = 0, sumR2: Double = 0
        for pixel in 0 ..< pixelCount {
            let i = pixel * kBytesPerPixel
            let b = Double(bgraBytes[i]) / 255.0
            let g = Double(bgraBytes[i + 1]) / 255.0
            let r = Double(bgraBytes[i + 2]) / 255.0
            sumB += b; sumG += g; sumR += r
            sumB2 += b * b; sumG2 += g * g; sumR2 += r * r
        }
        let n = Double(pixelCount)
        let meanB = sumB / n
        let meanG = sumG / n
        let meanR = sumR / n
        // Population variance E[X^2] - E[X]^2. Clamp to >= 0 against tiny
        // floating-point negatives on near-uniform inputs.
        let varB = max(0, sumB2 / n - meanB * meanB)
        let varG = max(0, sumG2 / n - meanG * meanG)
        let varR = max(0, sumR2 / n - meanR * meanR)
        return SelfTestPixelStats(meanR: meanR, meanG: meanG, meanB: meanB,
                                  varianceR: varR, varianceG: varG, varianceB: varB)
    }

    /// Applies the FR-10 verdict rules to `stats`. Returns `.fail` when
    /// either (a) every channel's variance is `<= kMinVariance` (uniform
    /// image, including black, mid-grey, and white), or (b) the per-channel
    /// mean is within `kWhiteMeanTolerance` of (1, 1, 1) (the specific
    /// white-window failure class). Otherwise `.pass`.
    public static func evaluate(stats: SelfTestPixelStats) -> SelfTestVerdict {
        let nearWhite = abs(stats.meanR - 1.0) <= SelfTestThresholds.kWhiteMeanTolerance
            && abs(stats.meanG - 1.0) <= SelfTestThresholds.kWhiteMeanTolerance
            && abs(stats.meanB - 1.0) <= SelfTestThresholds.kWhiteMeanTolerance
        if nearWhite {
            return .fail(reason: "uniform_white mean=\(format3(stats.meanR, stats.meanG, stats.meanB))")
        }
        let lowVar = stats.varianceR <= SelfTestThresholds.kMinVariance
            && stats.varianceG <= SelfTestThresholds.kMinVariance
            && stats.varianceB <= SelfTestThresholds.kMinVariance
        if lowVar {
            return .fail(reason: "low_variance variance=\(format3(stats.varianceR, stats.varianceG, stats.varianceB))")
        }
        return .pass
    }

    /// Format a per-channel triple at fixed precision so verdict strings are
    /// byte-stable across runs (grep-friendly).
    public static func format3(_ a: Double, _ b: Double, _ c: Double) -> String {
        return String(format: "%.4f,%.4f,%.4f", a, b, c)
    }

    // sampleBGRA(...) and mismatchReason(...) live in
    // selftest.readback.sampling.swift to keep this file under the 200-LOC
    // project cap (NFR-6 / FR-16 / AC-18).
}
