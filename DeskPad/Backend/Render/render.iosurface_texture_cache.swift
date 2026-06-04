//
//  render.iosurface_texture_cache.swift
//  DeskPad
//
//  @agents-index Small `IOSurface`-to-`MTLTexture` cache keyed by
//  `IOSurfaceID` so the renderer does not rebuild a texture descriptor for
//  every frame. The cache stores weak entries on the texture side (we never
//  retain `MTLTexture` past the next present per FR-11) and prunes the slot
//  if the underlying texture has been released, so memory pressure cannot
//  accumulate even when the SCK delivery rotates many distinct surfaces.
//
//  This is intentionally not an `LRUCache`: SCK reuses a small set of
//  `IOSurface`s in steady-state (governed by `queueDepth`), so the working
//  set is bounded structurally. A flat dictionary keyed by `IOSurfaceID`
//  is the smallest viable representation.
//

import Foundation
@preconcurrency import IOSurface
import Metal

/// `IOSurface`-to-`MTLTexture` cache. Not thread-safe by itself: the
/// renderer accesses it from a single render queue. Construction is cheap;
/// the cache holds only a dictionary of weak texture handles plus the
/// originating `MTLDevice`.
public final class IOSurfaceTextureCache {
    /// Weak wrapper so a texture entry evaporates the moment the renderer
    /// stops retaining its previous frame. The cache's `lookup(...)` path
    /// detects an evicted slot and rebuilds a fresh `MTLTexture` for the
    /// next caller.
    private final class WeakTexture {
        weak var texture: MTLTexture?
        init(_ texture: MTLTexture) { self.texture = texture }
    }

    private let log = Logger(category: "render")
    private var entries: [IOSurfaceID: WeakTexture] = [:]

    /// Device used to mint new textures. Replaced via `replaceDevice(_:)`
    /// during device-loss recovery so the cache flushes stale textures bound
    /// to the prior device.
    public private(set) var device: MTLDevice

    /// Build a cache bound to a Metal device.
    public init(device: MTLDevice) {
        self.device = device
    }

    /// Look up a texture for the supplied `IOSurface`, creating it via
    /// `MTLDevice.makeTexture(descriptor:iosurface:plane:)` on cache miss.
    /// Returns `nil` if Metal refuses to mint a texture (e.g. invalid
    /// descriptor or device removal in flight).
    public func texture(for surface: IOSurface) -> MTLTexture? {
        let key = IOSurfaceGetID(surface as IOSurfaceRef)
        if let cached = entries[key]?.texture {
            return cached
        }

        let width = IOSurfaceGetWidth(surface as IOSurfaceRef)
        let height = IOSurfaceGetHeight(surface as IOSurfaceRef)
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .bgra8Unorm
        descriptor.width = width
        descriptor.height = height
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(
            descriptor: descriptor,
            iosurface: surface as IOSurfaceRef,
            plane: 0
        ) else {
            log.error("failed to mint MTLTexture for IOSurface id=\(key)")
            return nil
        }
        entries[key] = WeakTexture(texture)
        return texture
    }

    /// Drop every cached entry. Called from device-loss recovery to ensure
    /// textures created against the previous `MTLDevice` are not handed back.
    public func flush() {
        entries.removeAll(keepingCapacity: true)
    }

    /// Replace the backing device and flush. Used by the device-loss
    /// recovery utility after `MTLCreateSystemDefaultDevice()` returns a
    /// fresh device.
    public func replaceDevice(_ newDevice: MTLDevice) {
        device = newDevice
        flush()
    }

    /// Test-only: number of currently-live entries (after pruning stale
    /// weak slots). Used by `iosurface_texture_cache_tests.swift` to confirm
    /// reuse semantics.
    public func liveEntryCountForTest() -> Int {
        entries = entries.filter { $0.value.texture != nil }
        return entries.count
    }
}
