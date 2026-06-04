//
//  agents.log.logger.swift
//  DeskPad
//
//  @agents-index Logger wrapper around os.Logger that prefixes every emitted
//  line with the originating "filename:line" (derived from #fileID / #line),
//  per the project's logging standard. Lines are emitted to the unified
//  logging system AND teed into the rotating file sink so post-hoc grep and
//  diff against a persisted log file are possible.
//
//  The wrapper is a value type so it can be safely shared across actors and
//  concurrency domains under Swift strict concurrency. It does not retain
//  per-instance state beyond a subsystem/category pair; the file sink is a
//  shared global singleton (see agents.log.file_sink.swift).
//

import Foundation
import os

/// Severity levels exposed by the logger. Mirrors the subset of `OSLogType`
/// the project uses; kept as its own enum so call sites are independent of
/// the underlying os.log type system.
public enum LogLevel: String, Sendable {
    case debug
    case info
    case notice
    case warning
    case error
    case fault

    fileprivate var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .notice: return .default
        case .warning: return .default
        case .error: return .error
        case .fault: return .fault
        }
    }
}

/// A thin wrapper around `os.Logger` that tags every emitted line with a
/// `filename:line` prefix captured from the call site via `#fileID` / `#line`.
///
/// Usage:
/// ```swift
/// let log = Logger(category: "capture")
/// log.info("stream started")
/// // -> "capture.stream_coordinator.swift:42 stream started"
/// ```
///
/// The wrapper is `Sendable`: it owns only an `os.Logger` (itself thread-safe)
/// and a string category, so it crosses concurrency boundaries freely.
public struct Logger: Sendable {
    /// The category tag the underlying `os.Logger` was created with. Surfaced
    /// in Console.app and in the file sink prefix so multiple subsystems can
    /// be filtered independently.
    public let category: String

    private let osLogger: os.Logger

    /// Build a logger bound to the given subsystem and category.
    ///
    /// - Parameters:
    ///   - subsystem: Reverse-DNS subsystem identifier; defaults to the app's
    ///     bundle identifier, falling back to `com.stengo.DeskPad` when the
    ///     bundle identifier is unavailable (e.g. inside unit-test hosts).
    ///   - category: Free-form category name used to scope log queries.
    public init(
        subsystem: String = Bundle.main.bundleIdentifier ?? "com.stengo.DeskPad",
        category: String
    ) {
        self.category = category
        osLogger = os.Logger(subsystem: subsystem, category: category)
    }

    /// Emit a `debug`-level line. See `log(_:level:file:line:)` for parameter
    /// semantics; the convenience methods exist purely so call sites do not
    /// have to pass the level enum explicitly.
    public func debug(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        log(message(), level: .debug, file: file, line: line)
    }

    /// Emit an `info`-level line. See `debug(_:file:line:)`.
    public func info(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        log(message(), level: .info, file: file, line: line)
    }

    /// Emit a `notice`-level line. See `debug(_:file:line:)`.
    public func notice(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        log(message(), level: .notice, file: file, line: line)
    }

    /// Emit a `warning`-level line. See `debug(_:file:line:)`.
    public func warning(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        log(message(), level: .warning, file: file, line: line)
    }

    /// Emit an `error`-level line. See `debug(_:file:line:)`.
    public func error(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        log(message(), level: .error, file: file, line: line)
    }

    /// Emit a `fault`-level line. See `debug(_:file:line:)`.
    public func fault(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        log(message(), level: .fault, file: file, line: line)
    }

    /// Core emission path. Builds the `filename:line` prefix, forwards the
    /// composed line to the unified logging system at the requested severity,
    /// and tees the same line into the rotating file sink. The `filename`
    /// portion is the file basename (the trailing component of `#fileID`,
    /// which has the form `Module/Path/File.swift`) so the prefix matches
    /// the project's logging standard.
    public func log(
        _ message: String,
        level: LogLevel,
        file: String = #fileID,
        line: Int = #line
    ) {
        let filename = Self.basename(of: file)
        let composed = "\(filename):\(line) [\(category)] \(message)"
        osLogger.log(level: level.osLogType, "\(composed, privacy: .public)")
        LogFileSink.shared.write(composed, level: level)
    }

    /// Extract the trailing path component from a `#fileID` string. Returns
    /// the substring after the final `/`, or the input unchanged if no slash
    /// is present (e.g. when tests pass an already-bare filename).
    static func basename(of fileID: String) -> String {
        guard let slash = fileID.lastIndex(of: "/") else { return fileID }
        return String(fileID[fileID.index(after: slash)...])
    }

    /// Format a log line exactly as `log(_:level:file:line:)` would write it
    /// to the file sink, without emitting anything. Test-only entry point so
    /// the format contract can be asserted without touching disk or the
    /// unified logging system.
    static func formatted(
        message: String,
        category: String,
        file: String,
        line: Int
    ) -> String {
        let filename = basename(of: file)
        return "\(filename):\(line) [\(category)] \(message)"
    }
}
