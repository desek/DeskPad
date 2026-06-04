//
//  render.device_loss_recovery.swift
//  DeskPad
//
//  @agents-index Device-loss recovery utility. Inspects a completed
//  `MTLCommandBuffer.error` and, if its code is one of the device-loss
//  class values (`MTLCommandBufferError.deviceRemoved`, `.accessRevoked`,
//  `.notPermitted` per FR-9), acquires a fresh device via
//  `MTLCreateSystemDefaultDevice()` and rebuilds the dependent pipeline
//  state (texture cache + blit pipeline + host view's `CAMetalLayer`
//  device).
//
//  The utility deliberately keeps no state of its own beyond a closure
//  the caller supplies for "where to swap the device in"; the renderer
//  passes a closure that updates the host view, the cache, and the
//  pipeline in one shot.
//

import Foundation
import Metal

/// Outcome of inspecting a completed command buffer. `noError` means
/// nothing to do; `recovered` means a new device was acquired and the
/// dependents were rebuilt; `failed` means the error was in the
/// device-loss class but no replacement device could be acquired (the
/// renderer surfaces this as a permanent error state to Phase 4's
/// coordinator).
public enum DeviceLossOutcome: Sendable, Equatable {
    case noError
    case recovered
    case failed
}

/// Stateless utility wrapping the device-loss recovery decision. The
/// `swapIn` closure is invoked with the freshly-acquired device and is
/// responsible for updating every dependent: typically the host view, the
/// texture cache, and the blit pipeline.
public struct DeviceLossRecovery {
    /// Callback invoked with a freshly-acquired `MTLDevice`. Throws to
    /// signal that the new device could not be wired up (e.g. shader
    /// compilation failed against the new device), which the utility
    /// translates into a `.failed` outcome.
    public typealias SwapIn = (MTLDevice) throws -> Void

    /// Factory for the replacement device. Defaults to
    /// `MTLCreateSystemDefaultDevice()`; tests inject a stub that returns
    /// a controlled device (or `nil` to exercise the `.failed` path).
    public var deviceFactory: @Sendable () -> MTLDevice?

    /// Build a recovery utility with the default system device factory.
    public init(deviceFactory: @escaping @Sendable () -> MTLDevice? = { MTLCreateSystemDefaultDevice() }) {
        self.deviceFactory = deviceFactory
    }

    /// Inspect `error` and, if it represents device loss, run `swapIn`
    /// with a fresh device. Returns the outcome.
    public func handle(error: NSError?, swapIn: SwapIn) -> DeviceLossOutcome {
        guard let error else { return .noError }
        guard error.domain == MTLCommandBufferErrorDomain else { return .noError }
        guard let code = MTLCommandBufferError.Code(rawValue: UInt(error.code)) else { return .noError }
        switch code {
        case .deviceRemoved, .accessRevoked, .notPermitted:
            break
        default:
            return .noError
        }
        guard let newDevice = deviceFactory() else {
            return .failed
        }
        do {
            try swapIn(newDevice)
            return .recovered
        } catch {
            return .failed
        }
    }

    /// Convenience: inspect a completed `MTLCommandBuffer` directly.
    public func handle(commandBuffer: MTLCommandBuffer, swapIn: SwapIn) -> DeviceLossOutcome {
        return handle(error: commandBuffer.error as NSError?, swapIn: swapIn)
    }
}
