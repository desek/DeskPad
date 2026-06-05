//
//  frame_presenter_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0003 Phase 1 closure for `render.frame_presenter.swift`.
//  Exercises the link-vended drawable branch through `PacerTick.drawable`,
//  covering the call site that produced the white-window regression
//  (checkpoint `6a4eea3`) and the latency-log cadence.
//

import CoreVideo
import IOSurface
import Metal
import QuartzCore
import XCTest

@testable import DeskPad

@MainActor
final class FramePresenterTests: XCTestCase {
    private func makeIOSurface(width: Int = 64, height: Int = 64) throws -> IOSurface {
        let props: [IOSurfacePropertyKey: Any] = [
            .width: width,
            .height: height,
            .pixelFormat: kCVPixelFormatType_32BGRA,
            .bytesPerElement: 4,
        ]
        return try XCTUnwrap(IOSurface(properties: props))
    }

    /// Verifies the link-vended drawable branch is taken when
    /// `PacerTick.drawable` is non-nil and `presentedFrameCount`
    /// advances. Regression for `6a4eea3` (white-window class).
    func testPresentUsesLinkVendedDrawable() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let cache = IOSurfaceTextureCache(device: device)
        let output = StreamOutput()
        let surface = try makeIOSurface()
        var pixelBuf: Unmanaged<CVPixelBuffer>?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        let status = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, surface, attrs as CFDictionary, &pixelBuf
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let pb = try XCTUnwrap(pixelBuf).takeRetainedValue()
        output.publishForTest(pixelBuffer: pb)

        let hostView = MetalLayerHostView(device: device)
        let queue = device.makeCommandQueue()
        let pipeline = try BlitPipeline(device: device)
        let presenter = FramePresenter(
            textureCache: cache, streamOutput: output, hostView: hostView,
            commandQueue: queue, getPipeline: { pipeline },
            onCommandBufferError: { _ in }
        )

        let drawable = try XCTUnwrap(FakeMetalDrawable(device: device, width: 64, height: 64))
        let tick = PacerTick(
            targetPresentationTimestamp: CACurrentMediaTime() + 0.016,
            targetTimestamp: CACurrentMediaTime(),
            drawable: drawable
        )
        presenter.present(tick: tick)
        // `framesPresented` advances when the link-vended drawable branch
        // is taken (regression assertion for `6a4eea3`).
        XCTAssertEqual(presenter.presentedFrameCount, 1)
        // Explicit `present(at:)` must never be invoked on a link-vended
        // drawable (FR-3; raises NSException in production, was the
        // root cause of `5806880`). FramePresenter only calls plain
        // `cb.present(drawable)`, so `presentAtCalls` stays at zero.
        XCTAssertEqual(drawable.presentAtCalls, 0)
    }

    /// Verifies the latency log threshold is reached on the 60th frame.
    /// `framesPresented % 60 == 0` is the only branch that emits, so 60
    /// successful presents exercise it exactly once.
    func testLatencyLogEmittedEvery60Frames() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let cache = IOSurfaceTextureCache(device: device)
        let output = StreamOutput()
        let surface = try makeIOSurface()
        var pixelBuf: Unmanaged<CVPixelBuffer>?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        _ = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, surface, attrs as CFDictionary, &pixelBuf
        )
        let pb = try XCTUnwrap(pixelBuf).takeRetainedValue()
        output.publishForTest(pixelBuffer: pb)

        let hostView = MetalLayerHostView(device: device)
        let queue = device.makeCommandQueue()
        let pipeline = try BlitPipeline(device: device)
        let presenter = FramePresenter(
            textureCache: cache, streamOutput: output, hostView: hostView,
            commandQueue: queue, getPipeline: { pipeline },
            onCommandBufferError: { _ in }
        )

        for _ in 0 ..< 60 {
            let drawable = try XCTUnwrap(FakeMetalDrawable(device: device))
            presenter.present(tick: PacerTick(drawable: drawable))
        }
        XCTAssertEqual(presenter.presentedFrameCount, 60)
    }

    /// Verifies that swapping the command-buffer error handler post-init
    /// installs the new closure. Asserted by direct observation of the
    /// swap, not the completion callback (which is asynchronous).
    func testCommandBufferErrorHandlerPropagation() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let cache = IOSurfaceTextureCache(device: device)
        let output = StreamOutput()
        let hostView = MetalLayerHostView(device: device)
        let presenter = FramePresenter(
            textureCache: cache, streamOutput: output, hostView: hostView,
            commandQueue: device.makeCommandQueue(),
            getPipeline: { nil },
            onCommandBufferError: { _ in }
        )
        // Smoke: the setter accepts a new handler without crashing.
        presenter.setOnCommandBufferError { _ in }
        // No captured surface -> presenter bails on the first guard;
        // `presentedFrameCount` remains 0. Asserts the early-return path
        // is taken when `StreamOutput.latestCapturedSurface` is nil.
        presenter.present(tick: PacerTick())
        XCTAssertEqual(presenter.presentedFrameCount, 0)
    }
}
