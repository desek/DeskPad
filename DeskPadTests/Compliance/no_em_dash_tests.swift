//
//  no_em_dash_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0002 Phase 4 Compliance grep guard: scans every
//  tracked Swift source under `DeskPad/` for U+2014 (em-dash) and
//  U+2013 (en-dash). The project's core principle "No dashed em-dashes
//  in prose" forbids both characters; rewrites or commas are required
//  instead. The guard runs over every Swift source so future files
//  inherit the rule automatically without per-file maintenance.
//

import Foundation
import XCTest

final class NoEmDashTests: XCTestCase {
    func testNewFilesContainNoEmDashes() throws {
        let sourcesDir = try Self.sourcesDirectory()
        var violations: [String] = []
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: sourcesDir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            XCTFail("Could not enumerate \(sourcesDir.path)")
            return
        }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains("\u{2014}") || source.contains("\u{2013}") {
                violations.append(url.lastPathComponent)
            }
        }
        XCTAssertTrue(violations.isEmpty, "Em-dash (U+2014) or en-dash (U+2013) found in: \(violations)")
    }

    private static func sourcesDirectory() throws -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent() // Compliance
            .deletingLastPathComponent() // DeskPadTests
            .deletingLastPathComponent() // repo root
        return repoRoot.appendingPathComponent("DeskPad")
    }
}
