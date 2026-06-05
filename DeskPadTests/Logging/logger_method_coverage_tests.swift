//
//  logger_method_coverage_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0003 Phase 1 closure for `agents.log.logger.swift`.
//  Direct-calls every log-level convenience method so the per-level
//  branches and the `osLogType` mapping all execute.
//

import XCTest

@testable import DeskPad

final class LoggerMethodCoverageTests: XCTestCase {
    func testAllLogLevelsRouteThroughFormatter() {
        let log = Logger(subsystem: "com.stengo.DeskPad.tests", category: "coverage")
        log.debug("d")
        log.info("i")
        log.notice("n")
        log.warning("w")
        log.error("e")
        log.fault("f")
        let formatted = Logger.formatted(
            message: "msg",
            category: "cat",
            file: "Module/Path/File.swift",
            line: 7
        )
        XCTAssertTrue(formatted.contains("File.swift:7"))
        XCTAssertTrue(formatted.contains("[cat]"))
    }

    func testBasenameHandlesAllInputs() {
        XCTAssertEqual(Logger.basename(of: "a/b/c.swift"), "c.swift")
        XCTAssertEqual(Logger.basename(of: "Bare.swift"), "Bare.swift")
        XCTAssertEqual(Logger.basename(of: ""), "")
    }
}
