//
//  selftest.loopback_pattern.swift
//  DeskPad
//
//  @agents-index CR-0003 Phase 4 Layer 3 loopback pattern source. Produces a
//  deterministic horizontal RGB gradient plus a frame-counter component, along
//  with a fixed set of named sample points whose expected `(R, G, B)` triples
//  are pure functions of the pattern dimensions and the frame index. The
//  pattern is the ground truth for the FR-12 / FR-13 sample-point assertions
//  in `selftest.readback.swift`. Tolerance math (FR-12: 8 levels per channel
//  on an 8-bit BGRA scale) is centralized here so both the read-back assertion
//  and the unit tests reference the same constant.
//
//  The pattern is intentionally independent of any Apple windowing or display
//  API: it is a pure (width, height, frameIndex) -> bytes / colors function.
//  This lets unit tests verify determinism without a `MTLDevice`, and lets the
//  CR-0001 fallback path (virtual display not addressable as an `NSScreen`)
//  drop the captured-pixel comparison without re-implementing the pattern
//  itself, per the CR's documented fallback (Open Questions, virtual display
//  addressability).
//

import Foundation

/// A configured sample point in pattern space. Coordinates are pattern-pixel
/// integers, not normalized; the loopback harness reads exactly these pixels
/// out of the captured and/or presented buffer and compares them against the
/// triple returned by `SelfTestLoopbackPattern.expectedColor(at:frameIndex:)`.
public struct SelfTestSamplePoint: Equatable, Sendable {
    public let name: String
    public let x: Int
    public let y: Int

    public init(name: String, x: Int, y: Int) {
        self.name = name
        self.x = x
        self.y = y
    }
}

/// A single 8-bit RGB triple. Stored as `UInt8` so equality and tolerance math
/// match the on-the-wire pixel format exactly.
public struct SelfTestColor: Equatable, Sendable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// Deterministic test-pattern source. All entry points are pure functions of
/// their inputs; no global state, no I/O.
public enum SelfTestLoopbackPattern {
    /// FR-12 / AC-13 tolerance: 8 levels per channel on the 8-bit scale. The
    /// constant is intentionally named so future tuning is one line.
    public static let kTolerance: Int = 8

    /// Default named sample points used by the harness. Three points per
    /// FR-12. Coordinates are clamped against the pattern dimensions inside
    /// `expectedColor(at:frameIndex:width:height:)`, so the same set is
    /// reusable across pattern resolutions without breaking the harness when
    /// the virtual display is resized.
    public static let defaultSamplePoints: [SelfTestSamplePoint] = [
        SelfTestSamplePoint(name: "top_left_quartile", x: 16, y: 16),
        SelfTestSamplePoint(name: "center", x: 128, y: 96),
        SelfTestSamplePoint(name: "bottom_right_quartile", x: 240, y: 176),
    ]

    /// Compute the expected pattern pixel at `(x, y)` for `frameIndex` on a
    /// pattern of `(width, height)` pixels. Horizontal position drives R, the
    /// vertical position drives G, and a frame-counter byte drives B so the
    /// pattern is visibly changing across frames (which is exactly the signal
    /// the white-window failure class destroys).
    public static func expectedColor(x: Int, y: Int,
                                     frameIndex: Int,
                                     width: Int, height: Int) -> SelfTestColor
    {
        let cx = max(0, min(x, max(1, width - 1)))
        let cy = max(0, min(y, max(1, height - 1)))
        let wScale = max(1, width - 1)
        let hScale = max(1, height - 1)
        let r = UInt8((cx * 255) / wScale)
        let g = UInt8((cy * 255) / hScale)
        // Frame counter wraps modulo 256 so the byte is stable and the
        // pattern remains valid past the 256th frame.
        let b = UInt8(frameIndex & 0xFF)
        return SelfTestColor(r: r, g: g, b: b)
    }

    /// Convenience: compute the expected triple at a named sample point.
    public static func expectedColor(at point: SelfTestSamplePoint,
                                     frameIndex: Int,
                                     width: Int, height: Int) -> SelfTestColor
    {
        return expectedColor(x: point.x, y: point.y,
                             frameIndex: frameIndex,
                             width: width, height: height)
    }

    /// FR-12 tolerance comparison. Returns `true` iff every channel of
    /// `actual` is within `tolerance` (default `kTolerance`) of the matching
    /// channel in `expected`, measured on the unsigned 8-bit scale.
    public static func matches(expected: SelfTestColor,
                               actual: SelfTestColor,
                               tolerance: Int = SelfTestLoopbackPattern.kTolerance) -> Bool
    {
        return channelWithin(expected.r, actual.r, tolerance: tolerance)
            && channelWithin(expected.g, actual.g, tolerance: tolerance)
            && channelWithin(expected.b, actual.b, tolerance: tolerance)
    }

    /// Render the full pattern into a freshly allocated BGRA byte buffer. The
    /// buffer is laid out row-major, BGRA per pixel, matching Metal's
    /// `.bgra8Unorm` memory order so the read-back path consumes it directly.
    public static func renderBGRA(width: Int, height: Int, frameIndex: Int) -> [UInt8] {
        let bytesPerPixel = 4
        var bytes = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let b = UInt8(frameIndex & 0xFF)
        for y in 0 ..< height {
            let g = UInt8((y * 255) / max(1, height - 1))
            let rowStart = y * width * bytesPerPixel
            for x in 0 ..< width {
                let r = UInt8((x * 255) / max(1, width - 1))
                let i = rowStart + x * bytesPerPixel
                bytes[i] = b
                bytes[i + 1] = g
                bytes[i + 2] = r
                bytes[i + 3] = 255
            }
        }
        return bytes
    }

    /// Absolute-difference comparison on `UInt8` without overflow.
    private static func channelWithin(_ a: UInt8, _ b: UInt8, tolerance: Int) -> Bool {
        let delta = a >= b ? Int(a) - Int(b) : Int(b) - Int(a)
        return delta <= tolerance
    }
}
