//
//  capture.stream_configuration.swift
//  DeskPad
//
//  @agents-index Factory that builds an `SCStreamConfiguration` for the
//  DeskPad capture pipeline: BGRA pixel format, cursor visible, and a
//  mode-parameterised `queueDepth` / `minimumFrameInterval` so FR-14
//  (queue depth in {2,3}), FR-16 (low-latency cadence matches the host
//  panel's maximum refresh rate), and FR-18 (mode-dependent cadence) are
//  satisfied without hard-coding 60 Hz.
//

import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Active cadence mode for the capture stream. The coordinator picks the mode
/// from app state and feeds it to the factory; the factory translates the
/// mode into a concrete `minimumFrameInterval` per the rule documented on
/// each case.
///
/// `lowLatency` targets the host panel's maximum refresh rate so interactive
/// content (FR-16) hits the one-frame budget on ProMotion / 120 Hz panels;
/// `powerSaving` relaxes the cadence to 60 Hz so the GPU and capture stack
/// idle longer on battery (FR-18).
public enum CaptureMode: Sendable, Equatable {
    /// Match the host panel's maximum refresh rate, e.g. 1/120 on ProMotion
    /// or 1/60 on a typical external display.
    case lowLatency(panelMaxRefreshHz: Int)
    /// Power-saving cadence: a flat 1/60.
    case powerSaving
}

/// Stateless factory that produces an `SCStreamConfiguration` parameterised
/// by the captured resolution, scale factor, and active `CaptureMode`. The
/// factory is the only place pixel-format and queue-depth defaults live so
/// downstream code never has to repeat the magic numbers.
public struct StreamConfigurationFactory: Sendable {
    /// Default `queueDepth`. The CR caps this at the {2,3} range per FR-14
    /// to bound the in-flight frame buffer; 3 is the upper end which trades
    /// a slightly larger working set for fewer producer-side stalls.
    public static let defaultQueueDepth: Int = 3

    public init() {}

    /// Build a stream configuration.
    ///
    /// - Parameters:
    ///   - resolution: The logical (points) resolution of the mirrored
    ///     content. Multiplied by `scaleFactor` to derive the pixel-space
    ///     `width`/`height` SCK expects.
    ///   - scaleFactor: Backing-scale factor of the virtual display.
    ///   - mode: Active capture cadence mode (see `CaptureMode`).
    ///   - queueDepth: In-flight frame buffer depth. Defaults to
    ///     `defaultQueueDepth`. Callers must keep this within the {2, 3}
    ///     range required by FR-14; values outside that range are clamped.
    /// - Returns: A configured `SCStreamConfiguration` with `pixelFormat ==
    ///   kCVPixelFormatType_32BGRA`, `showsCursor == true`, and
    ///   `minimumFrameInterval` selected from `mode`.
    public func makeConfiguration(
        resolution: CGSize,
        scaleFactor: CGFloat,
        mode: CaptureMode,
        queueDepth: Int = StreamConfigurationFactory.defaultQueueDepth
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.width = Int(resolution.width * scaleFactor)
        configuration.height = Int(resolution.height * scaleFactor)
        configuration.queueDepth = max(2, min(3, queueDepth))
        configuration.minimumFrameInterval = Self.frameInterval(for: mode)
        return configuration
    }

    /// Translate a `CaptureMode` into its `CMTime` `minimumFrameInterval`.
    /// Exposed (internal) so the test target can assert the mode-to-interval
    /// mapping without instantiating a full configuration.
    static func frameInterval(for mode: CaptureMode) -> CMTime {
        switch mode {
        case let .lowLatency(panelMaxRefreshHz):
            let timescale = max(1, Int32(panelMaxRefreshHz))
            return CMTime(value: 1, timescale: timescale)
        case .powerSaving:
            return CMTime(value: 1, timescale: 60)
        }
    }
}
