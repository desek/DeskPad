//
//  selftest.readback.sampling.swift
//  DeskPad
//
//  @agents-index CR-0003 Phase 3 helpers split off from selftest.readback.swift
//  to keep both files under the 200-LOC project cap (NFR-6 / FR-16 / AC-18).
//  Holds the single-pixel sampling helper and the FR-13 mismatch-reason
//  builder; the parent file keeps the read-back blit, stats reduction, and
//  verdict evaluation. The split is purely mechanical; no behaviour changes.
//

import Foundation

public extension SelfTestReadback {
    /// Sample a single BGRA pixel out of a row-major byte buffer at `(x, y)`.
    /// Returns the pixel as an RGB triple in the order the loopback pattern
    /// emits (R first), so comparisons against `SelfTestLoopbackPattern`
    /// expectations are direct. Returns `nil` if the buffer is too small for
    /// the requested coordinate (defensive against a resolution mismatch
    /// between the captured surface and the configured sample point).
    static func sampleBGRA(bytes: [UInt8],
                           width: Int, height: Int,
                           x: Int, y: Int) -> SelfTestColor?
    {
        if x < 0 || y < 0 || x >= width || y >= height { return nil }
        let i = (y * width + x) * kBytesPerPixel
        if i + 3 >= bytes.count { return nil }
        return SelfTestColor(r: bytes[i + 2], g: bytes[i + 1], b: bytes[i])
    }

    /// FR-13 mismatch-reason builder. Produces the stable, parseable string
    /// the script and CI runners match on. `kind` is either
    /// `"capture_mismatch_at_point"` or `"present_mismatch_at_point"`.
    static func mismatchReason(kind: String,
                               point: SelfTestSamplePoint,
                               expected: SelfTestColor,
                               actual: SelfTestColor) -> String
    {
        return "loopback: \(kind)=(\(point.x),\(point.y))"
            + " expected=(\(expected.r),\(expected.g),\(expected.b))"
            + " actual=(\(actual.r),\(actual.g),\(actual.b))"
    }
}
