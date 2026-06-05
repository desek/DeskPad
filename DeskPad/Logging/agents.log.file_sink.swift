//
//  agents.log.file_sink.swift
//  DeskPad
//
//  @agents-index Rotating file sink that tees log lines from the project's
//  Logger wrapper into ~/Library/Logs/DeskPad/deskpad.log (sandbox-redirected
//  to the app container's Logs directory at runtime). Rotation is size-based:
//  when the current file reaches the configured threshold it is renamed to
//  deskpad.log.1 and a new file is opened. A small bounded number of rotated
//  files are kept; older ones are discarded.
//
//  The sink is a process-wide singleton because the on-disk file is itself a
//  process-wide resource: serializing writes through one actor avoids
//  interleaved partial lines without forcing every call site to share a
//  reference. Writes are dispatched asynchronously so logger call sites are
//  never blocked on I/O.
//

import Foundation

/// Process-wide rotating file sink. Lines arrive from the `Logger` wrapper
/// and are appended to `~/Library/Logs/DeskPad/deskpad.log` with size-based
/// rotation. Failures are swallowed silently (logged once to stderr) because
/// the unified logging system remains the primary observability channel; the
/// file sink is a convenience tee for post-hoc grep.
/// Test-only seam: parameterizes the rotation threshold, retained rotations,
/// and target directory so unit tests can drive rotation against a temp
/// directory in milliseconds without touching production `~/Library/Logs`.
/// Production constructs the singleton with the defaults via `init()`.
public struct LogFileSinkConfiguration: Sendable {
    public let rotationThreshold: Int
    public let retainedRotations: Int
    /// When non-nil, the sink writes here instead of resolving the user
    /// Library logs directory. Used by `file_sink_rotation_tests.swift`.
    public let overrideDirectory: URL?

    public static let productionDefault = LogFileSinkConfiguration(
        rotationThreshold: 5 * 1024 * 1024,
        retainedRotations: 3,
        overrideDirectory: nil
    )

    public init(rotationThreshold: Int, retainedRotations: Int, overrideDirectory: URL?) {
        self.rotationThreshold = rotationThreshold
        self.retainedRotations = retainedRotations
        self.overrideDirectory = overrideDirectory
    }
}

public final class LogFileSink: @unchecked Sendable {
    /// Singleton entry point. Lazily resolves the log directory on first use
    /// so the sink does not perform I/O at app launch unless something logs.
    public static let shared = LogFileSink()

    /// Maximum file size in bytes before rotation triggers. 5 MiB chosen so a
    /// typical session fits in one file without rotation while pathological
    /// per-frame logging still cannot grow the file unbounded.
    private let rotationThreshold: Int

    /// Number of rotated files retained alongside the active log. With one
    /// active file plus three rotations the on-disk footprint is bounded at
    /// roughly 4 * rotationThreshold = 20 MiB.
    private let retainedRotations: Int

    /// Optional directory override; when nil, the sink resolves
    /// `~/Library/Logs/DeskPad/` via `FileManager`.
    private let overrideDirectory: URL?

    /// Serial queue funnelling all writes so the on-disk file cannot be
    /// interleaved across concurrent loggers.
    private let queue = DispatchQueue(label: "com.stengo.DeskPad.LogFileSink")

    /// Cached URL of the active log file. Resolved lazily inside `directory`.
    private var fileURL: URL?

    /// One-shot guard so a permanent failure (e.g. read-only filesystem) only
    /// produces a single stderr message rather than spamming every call site.
    private var hasReportedFailure = false

    private convenience init() {
        self.init(configuration: .productionDefault)
    }

    /// Test-only initializer accepting an explicit configuration so unit
    /// tests can drive rotation against a temp directory with a small
    /// threshold. Production must go through `LogFileSink.shared`.
    internal init(configuration: LogFileSinkConfiguration) {
        rotationThreshold = configuration.rotationThreshold
        retainedRotations = configuration.retainedRotations
        overrideDirectory = configuration.overrideDirectory
    }

    /// Append a single log line. The call is non-blocking: the line is queued
    /// and written on the sink's serial queue. A trailing newline is appended
    /// by the sink so call sites pass the bare line.
    ///
    /// - Parameters:
    ///   - line: The already-formatted line (including the `filename:line`
    ///     prefix and category tag) as composed by `Logger.log`.
    ///   - level: Severity, included in the on-disk line as `[LEVEL]` so
    ///     grep can filter without re-parsing the os.log mirror.
    public func write(_ line: String, level: LogLevel) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let composed = "\(timestamp) [\(level.rawValue.uppercased())] \(line)\n"
        queue.async { [weak self] in
            self?.appendSync(composed)
        }
    }

    /// Resolve, and create if missing, the directory the log file lives in.
    /// Sandboxed apps see `~/Library/Logs/DeskPad/` redirected into the
    /// container automatically, so the same URL works in both sandboxed and
    /// non-sandboxed contexts without conditional code.
    private func logDirectoryURL() throws -> URL {
        let fm = FileManager.default
        if let override = overrideDirectory {
            if !fm.fileExists(atPath: override.path) {
                try fm.createDirectory(at: override, withIntermediateDirectories: true)
            }
            return override
        }
        // FileManager.url(for: .libraryDirectory ...) returns the container's
        // Library when sandboxed and the user's Library otherwise. Append
        // "Logs/DeskPad" to land in the standard macOS app-logs location.
        let library = try fm.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = library.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("DeskPad", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Serial-queue write step. Opens the file (creating if necessary),
    /// rotates if the current size plus the pending line would cross the
    /// threshold, then appends. All I/O failures are coalesced behind
    /// `hasReportedFailure` so a broken filesystem cannot spam stderr.
    private func appendSync(_ line: String) {
        do {
            let url = try resolvedFileURL()
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            // Rotation check: stat the file each time so external truncation
            // (e.g. a developer deleting the file mid-run) is tolerated.
            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int,
               size + line.utf8.count > rotationThreshold
            {
                try rotate(currentURL: url)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } catch {
            reportFailureOnce(error)
        }
    }

    /// Resolve and cache the active log file URL. Cached only when the parent
    /// directory exists; if directory resolution fails we surface the error
    /// to the caller so `appendSync` can log it once.
    private func resolvedFileURL() throws -> URL {
        if let cached = fileURL { return cached }
        let dir = try logDirectoryURL()
        let url = dir.appendingPathComponent("deskpad.log", isDirectory: false)
        fileURL = url
        return url
    }

    /// Perform size-based rotation. Shifts deskpad.log.{N-1} -> deskpad.log.N
    /// for retained slots, then renames the active file to deskpad.log.1 and
    /// allows the next write to recreate the active file. Files beyond
    /// `retainedRotations` are deleted.
    private func rotate(currentURL: URL) throws {
        let fm = FileManager.default
        let dir = currentURL.deletingLastPathComponent()
        let base = currentURL.lastPathComponent
        // Walk from the oldest retained slot down so we never overwrite an
        // existing slot before its previous occupant has moved.
        for index in stride(from: retainedRotations, through: 1, by: -1) {
            let from = dir.appendingPathComponent("\(base).\(index)")
            let to = dir.appendingPathComponent("\(base).\(index + 1)")
            if fm.fileExists(atPath: from.path) {
                if index == retainedRotations {
                    try? fm.removeItem(at: from)
                } else {
                    try? fm.moveItem(at: from, to: to)
                }
            }
        }
        let rotated = dir.appendingPathComponent("\(base).1")
        if fm.fileExists(atPath: rotated.path) {
            try? fm.removeItem(at: rotated)
        }
        try? fm.moveItem(at: currentURL, to: rotated)
    }

    /// Emit a single stderr line describing a sink failure, then suppress
    /// further reports. Keeps the unified logging system unaffected.
    private func reportFailureOnce(_ error: Error) {
        guard !hasReportedFailure else { return }
        hasReportedFailure = true
        FileHandle.standardError.write(
            Data("LogFileSink failure (further failures suppressed): \(error)\n".utf8)
        )
    }

    /// ISO-8601 timestamp formatter shared across writes. Recreating the
    /// formatter per call would dominate the write cost on a hot logging
    /// path.
    private nonisolated(unsafe) static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Test hooks

    /// Test-only: synchronously flush any queued writes. Call from tests that
    /// need to assert on file contents after a `Logger.log` call returned.
    /// Production code never needs this; the queue drains naturally.
    func _flushForTesting() {
        queue.sync {}
    }

    /// Test-only: returns the current active log file URL, resolving and
    /// creating the directory if necessary. Used by tests to read back
    /// emitted lines.
    func _activeFileURLForTesting() throws -> URL {
        return try queue.sync { try resolvedFileURL() }
    }
}
