//
//  iosurface_texture_cache_tests.swift
//  DeskPadTests
//
//  @agents-index Asserts the CR-0001 Phase 3 Test Strategy row
//  `testCacheReusesTextureForSameSurface`: two lookups against one
//  `IOSurface` return the identical `MTLTexture`.
//

import IOSurface
import Metal
import XCTest

@testable import DeskPad

final class IOSurfaceTextureCacheTests: XCTestCase {
    /// `testCacheReusesTextureForSameSurface`: two lookups against one
    /// `IOSurface` must return the same `MTLTexture` instance, confirming
    /// the cache reuses entries keyed by `IOSurfaceID`.
    func testCacheReusesTextureForSameSurface() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this host")
        }
        let surface = try makeIOSurface(width: 64, height: 64)
        let cache = IOSurfaceTextureCache(device: device)

        let first = cache.texture(for: surface)
        let second = cache.texture(for: surface)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
    }

    /// Build a small BGRA `IOSurface` for the cache lookup. Throws if the
    /// surface cannot be created (kernel-level failure, treated as a
    /// host-environment skip).
    private func makeIOSurface(width: Int, height: Int) throws -> IOSurface {
        let attributes: [IOSurfacePropertyKey: Any] = [
            .width: width,
            .height: height,
            .pixelFormat: kCVPixelFormatType_32BGRA,
            .bytesPerElement: 4,
        ]
        guard let surface = IOSurface(properties: attributes) else {
            throw XCTSkip("IOSurface creation failed")
        }
        return surface
    }
}
