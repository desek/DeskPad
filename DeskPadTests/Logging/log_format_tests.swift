//
//  log_format_tests.swift
//  DeskPadTests
//
//  @agents-index Phase 1 logging contract tests. Verifies that every line
//  composed by the Logger wrapper carries the `filename:line` tag derived
//  from #fileID/#line, and that the LogFileSink tees lines to the on-disk
//  log file. Lives in the DeskPadTests target bootstrapped in Phase 1; later
//  phases add Capture/Render/Integration tests alongside this file.
//

@testable import DeskPad
import XCTest

final class LogFormatTests: XCTestCase {
    /// Verifies that the formatted log line contains a `filename:line` tag
    /// where `filename` is the trailing path component of `#fileID` and
    /// `line` is the integer line number passed in. This is the contract
    /// referenced by the CR-0001 Test Strategy row
    /// `testLogLineCarriesFilenameAndLine`.
    func testLogLineCarriesFilenameAndLine() throws {
        // Simulate a known call site: pass an explicit #fileID-shaped value
        // and a line number, so the assertion is independent of where this
        // test method itself lives in the source file.
        let formatted = Logger.formatted(
            message: "stream started",
            category: "capture",
            file: "DeskPad/Backend/Capture/SomeFile.swift",
            line: 123
        )

        // The CR specifies the regex \bSomeFile\.swift:\d+\b. Build it here
        // exactly so a future regex relaxation is a deliberate edit.
        let pattern = #"\bSomeFile\.swift:\d+\b"#
        let range = formatted.range(of: pattern, options: .regularExpression)
        XCTAssertNotNil(
            range,
            "Formatted line '\(formatted)' must match \(pattern)"
        )

        // Belt-and-suspenders: the exact line number we passed must appear
        // next to the filename, so the prefix is not just structurally
        // matching but semantically faithful to the call site.
        XCTAssertTrue(
            formatted.contains("SomeFile.swift:123"),
            "Formatted line '\(formatted)' must contain 'SomeFile.swift:123'"
        )
    }

    /// Verifies the basename extraction handles the canonical
    /// `Module/Path/File.swift` shape that `#fileID` produces, as well as
    /// the degenerate already-bare-filename case used by test stubs.
    func testBasenameExtractsTrailingComponent() {
        XCTAssertEqual(
            Logger.basename(of: "DeskPad/Logging/agents.log.logger.swift"),
            "agents.log.logger.swift"
        )
        XCTAssertEqual(Logger.basename(of: "Bare.swift"), "Bare.swift")
    }

    /// Verifies that a real `Logger` invocation tees a line into the file
    /// sink. The on-disk file is the project's persisted observability
    /// channel, so this test asserts both that the file is created and that
    /// it contains the `filename:line` prefix as written by `Logger.log`.
    func testFileSinkReceivesFormattedLine() throws {
        let log = Logger(subsystem: "com.stengo.DeskPad.tests", category: "phase1")
        let marker = "phase1-sink-marker-\(UUID().uuidString)"
        log.info(marker)

        LogFileSink.shared._flushForTesting()
        let url = try LogFileSink.shared._activeFileURLForTesting()

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(
            contents.contains(marker),
            "Active log file at \(url.path) must contain the marker line"
        )
        // The line must carry this test file's basename plus a colon and a
        // digit, proving the filename:line prefix survived the round-trip.
        let prefixPattern = #"\blog_format_tests\.swift:\d+\b"#
        let range = contents.range(of: prefixPattern, options: .regularExpression)
        XCTAssertNotNil(
            range,
            "Active log file must contain a line matching \(prefixPattern)"
        )
    }
}
