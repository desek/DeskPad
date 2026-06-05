//
//  selftest.presentation_backend.swift
//  DeskPad
//
//  @agents-index CR-0003 FR-15 / AC-15 backend-agnostic self-test surface.
//  Declares the small protocol the Layer 2 read-back and Layer 3 loopback
//  assertions are expressed against: any presentation backend that can return
//  a CPU-readable BGRA pixel buffer plus the active sample points satisfies
//  the harness. The Metal/CAMetalLayer path is the sole production
//  conformance in this CR; the CR-0002 AVSampleBufferDisplayLayer backend is
//  expected to add the second conformance without touching the harness.
//

import Foundation
import Metal

/// Small typed surface the self-test harness consumes (FR-15). A backend
/// returns the most recently presented pixels as a row-major BGRA byte buffer
/// of known `width * height` dimensions, plus the active sample points the
/// Layer 3 loopback should assert on. The protocol is intentionally minimal
/// (two methods, no associated types) so a future backend conforms in a few
/// lines rather than a rewrite.
public protocol SelfTestPresentationBackend {
    /// Width of the read-back buffer in pixels.
    var pixelWidth: Int { get }
    /// Height of the read-back buffer in pixels.
    var pixelHeight: Int { get }
    /// CPU-readable BGRA bytes for the most recently presented frame.
    func readBackPresentedBGRA() throws -> [UInt8]
    /// The sample points the Layer 3 loopback should assert.
    func samplePoints() -> [SelfTestSamplePoint]
}

/// Production conformance for the Metal/CAMetalLayer backend. Wraps the
/// existing `SelfTestReadback` free functions so the typed protocol surface
/// has exactly one production conformance in this CR (AC-15). The harness
/// can be driven by passing any `SelfTestPresentationBackend`; tests can
/// substitute a fixture conformance.
public struct MetalSelfTestPresentationBackend: SelfTestPresentationBackend {
    public let texture: MTLTexture
    public let commandQueue: MTLCommandQueue
    public let points: [SelfTestSamplePoint]

    public init(texture: MTLTexture,
                commandQueue: MTLCommandQueue,
                points: [SelfTestSamplePoint] = SelfTestLoopbackPattern.defaultSamplePoints)
    {
        self.texture = texture
        self.commandQueue = commandQueue
        self.points = points
    }

    public var pixelWidth: Int { texture.width }
    public var pixelHeight: Int { texture.height }

    public func readBackPresentedBGRA() throws -> [UInt8] {
        return try SelfTestReadback.readBack(texture: texture, commandQueue: commandQueue)
    }

    public func samplePoints() -> [SelfTestSamplePoint] { points }
}
