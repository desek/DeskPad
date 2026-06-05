//
//  file_sink_rotation_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0003 Phase 1 closure for `agents.log.file_sink.swift`.
//  Drives a `LogFileSink` against a temp directory with a tiny rotation
//  threshold so the rotation, retention, and first-write branches are
//  exercised without touching `~/Library/Logs/DeskPad/`.
//

import Foundation
import XCTest

@testable import DeskPad

final class FileSinkRotationTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "deskpad-file-sink-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    private func makeSink(threshold: Int = 256, retained: Int = 3) -> LogFileSink {
        return LogFileSink(configuration: LogFileSinkConfiguration(
            rotationThreshold: threshold,
            retainedRotations: retained,
            overrideDirectory: tempDir
        ))
    }

    /// First write creates the active file at the override path.
    func testFirstWriteCreatesActiveFile() throws {
        let sink = makeSink()
        sink.write("hello", level: .info)
        sink._flushForTesting()
        let url = try sink._activeFileURLForTesting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.lastPathComponent, "deskpad.log")
    }

    /// Writes that cross the threshold rotate the active file to .1 and
    /// open a fresh active file.
    func testRotationAtThreshold() throws {
        let sink = makeSink(threshold: 128)
        let line = String(repeating: "x", count: 80)
        sink.write(line, level: .info)
        sink.write(line, level: .info)
        sink.write(line, level: .info)
        sink._flushForTesting()
        let url = try sink._activeFileURLForTesting()
        let rotated = url.deletingLastPathComponent()
            .appendingPathComponent("deskpad.log.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path))
    }

    /// After enough rotations only retained + 1 files exist; the oldest
    /// is discarded.
    func testRetainedRotationsCapped() throws {
        let sink = makeSink(threshold: 64, retained: 2)
        let line = String(repeating: "y", count: 50)
        for _ in 0 ..< 10 {
            sink.write(line, level: .info)
        }
        sink._flushForTesting()
        let url = try sink._activeFileURLForTesting()
        let dir = url.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("deskpad.log") }
        // Active log plus at most `retained` rotations.
        XCTAssertLessThanOrEqual(files.count, 3)
    }
}
