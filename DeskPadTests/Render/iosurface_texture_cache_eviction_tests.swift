//
//  iosurface_texture_cache_eviction_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0003 Phase 1 closure for
//  `render.iosurface_texture_cache.swift`. Covers the weak-eviction branch
//  and `replaceDevice(_:)` flush. Sibling of the existing
//  `iosurface_texture_cache_tests.swift` which already covers the reuse path.
//

import CoreVideo
import IOSurface
import Metal
import XCTest

@testable import DeskPad

final class IOSurfaceTextureCacheEvictionTests: XCTestCase {
    private func makeIOSurface(width: Int = 64, height: Int = 64) throws -> IOSurface {
        let props: [IOSurfacePropertyKey: Any] = [
            .width: width,
            .height: height,
            .pixelFormat: kCVPixelFormatType_32BGRA,
            .bytesPerElement: 4,
        ]
        return try XCTUnwrap(IOSurface(properties: props))
    }

    /// Releasing the only strong reference to the cached texture causes
    /// the next lookup to mint a fresh `MTLTexture`.
    func testWeakEvictionMintsFreshTexture() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this host")
        }
        let cache = IOSurfaceTextureCache(device: device)
        let surface = try makeIOSurface()
        autoreleasepool {
            _ = cache.texture(for: surface)
        }
        // After the autoreleasepool drains, the weak entry should be
        // evicted. The pruning lookup reports zero live entries.
        XCTAssertEqual(cache.liveEntryCountForTest(), 0)
        let refreshed = cache.texture(for: surface)
        XCTAssertNotNil(refreshed)
    }

    /// `replaceDevice(_:)` flushes the dictionary.
    func testReplaceDeviceFlushesCache() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this host")
        }
        let cache = IOSurfaceTextureCache(device: device)
        let surface = try makeIOSurface()
        let texture = cache.texture(for: surface)
        withExtendedLifetime(texture) {
            XCTAssertEqual(cache.liveEntryCountForTest(), 1)
            cache.replaceDevice(device)
            XCTAssertEqual(cache.liveEntryCountForTest(), 0)
        }
    }

    /// `flush()` clears the dictionary directly.
    func testFlushClearsEntries() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this host")
        }
        let cache = IOSurfaceTextureCache(device: device)
        let surface = try makeIOSurface()
        let texture = cache.texture(for: surface)
        withExtendedLifetime(texture) {
            cache.flush()
            XCTAssertEqual(cache.liveEntryCountForTest(), 0)
        }
    }
}
