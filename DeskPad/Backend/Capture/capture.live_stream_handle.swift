//
//  capture.live_stream_handle.swift
//  DeskPad
//
//  @agents-index Production `StreamHandle` implementation wrapping a
//  live `SCStream`. The coordinator installs this handle via
//  `StreamCoordinator.install(handle:)` once the filter / configuration
//  / output have been built, then drives the lifecycle (start, stop,
//  reconfigure) through the abstract protocol so tests can still stub
//  the handle (FR-1, FR-2, FR-6, AC-1, AC-9).
//

import Foundation
import ScreenCaptureKit

/// Live `SCStream` handle. Builds the stream eagerly in `init`, attaches
/// the supplied `StreamOutput` for `.screen` samples on a dedicated
/// background queue (FR-2 off-main delivery), and forwards lifecycle
/// calls to the underlying `SCStream`.
public final class LiveStreamHandle: StreamHandle, @unchecked Sendable {
    private let stream: SCStream
    private let output: StreamOutput
    private let sampleQueue: DispatchQueue
    private var currentConfiguration: SCStreamConfiguration
    private let filter: SCContentFilter
    private let configurationFactory: StreamConfigurationFactory
    private var mode: CaptureMode
    private let log = Logger(category: "capture")

    /// Build a live handle: construct the `SCStream`, attach the output,
    /// and remember the supplied configuration so subsequent
    /// `updateConfiguration` calls can mutate just the pixel size.
    ///
    /// - Parameters:
    ///   - filter: Content filter scoping the stream to one display.
    ///   - configuration: Initial `SCStreamConfiguration`.
    ///   - output: Output / delegate that consumes `.screen` samples.
    ///   - mode: Active `CaptureMode` (informational; the configuration
    ///     factory has already baked the frame interval).
    ///   - configurationFactory: Factory used to rebuild the
    ///     configuration on `updateConfiguration` calls.
    public init(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        output: StreamOutput,
        mode: CaptureMode,
        configurationFactory: StreamConfigurationFactory = StreamConfigurationFactory()
    ) throws {
        self.filter = filter
        self.output = output
        self.mode = mode
        self.configurationFactory = configurationFactory
        currentConfiguration = configuration
        sampleQueue = DispatchQueue(label: "com.stengo.DeskPad.capture.sample", qos: .userInteractive)
        stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
    }

    public func startStream() async throws {
        log.notice("SCStream startCapture")
        try await stream.startCapture()
    }

    public func stopStream() async throws {
        log.notice("SCStream stopCapture")
        try await stream.stopCapture()
    }

    public func updateConfiguration(width: Int, height: Int) async throws {
        currentConfiguration.width = width
        currentConfiguration.height = height
        log.info("SCStream updateConfiguration \(width)x\(height)")
        try await stream.updateConfiguration(currentConfiguration)
    }

    /// Update the active capture mode by rebuilding the configuration's
    /// `minimumFrameInterval` (FR-18). The pixel dimensions are
    /// preserved from the previously-applied configuration.
    public func updateMode(_ newMode: CaptureMode) async throws {
        mode = newMode
        let resolution = CGSize(
            width: CGFloat(currentConfiguration.width),
            height: CGFloat(currentConfiguration.height)
        )
        let rebuilt = configurationFactory.makeConfiguration(
            resolution: resolution,
            scaleFactor: 1,
            mode: newMode
        )
        currentConfiguration = rebuilt
        try await stream.updateConfiguration(rebuilt)
        log.notice("capture mode switched: \(String(describing: newMode))")
    }
}
