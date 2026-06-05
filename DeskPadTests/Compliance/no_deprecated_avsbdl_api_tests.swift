//
//  no_deprecated_avsbdl_api_tests.swift
//  DeskPadTests
//
//  @agents-index CR-0002 Phase 4 Compliance grep guard: verifies no
//  Swift source under `DeskPad/Backend/Render/` references the
//  deprecated layer-level `AVSampleBufferDisplayLayer` API surface
//  (`AVSampleBufferDisplayLayer.h` lines 94..226). The only permitted
//  path is the modern `sampleBufferRenderer`
//  (`AVSampleBufferVideoRenderer`) per CR-0002 FR-7 and AC-8. The
//  regex used here is intentionally identical to the one documented in
//  the CR's Quality Standards Compliance / Verification Commands
//  section so the build and the test guard share one expression.
//

import Foundation
import XCTest

final class NoDeprecatedAVSBDLAPITests: XCTestCase {
    func testNoDirectDeprecatedAVSBDLAPIs() throws {
        let renderDir = try Self.renderSourceDirectory()
        let pattern = #"AVSampleBufferDisplayLayer[^.]*\.(enqueueSampleBuffer|flush|flushAndRemoveImage|status|error|timebase|readyForMoreMediaData|requiresFlushToResumeDecoding)\b"#
        let regex = try NSRegularExpression(pattern: pattern)

        var violations: [String] = []
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: renderDir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            XCTFail("Could not enumerate \(renderDir.path)")
            return
        }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            // Strip line comments and block comments so docstrings that
            // legitimately name the deprecated methods (e.g. to document
            // that they are forbidden) do not trip the guard.
            let stripped = Self.stripComments(source)
            let range = NSRange(stripped.startIndex ..< stripped.endIndex, in: stripped)
            if regex.firstMatch(in: stripped, options: [], range: range) != nil {
                violations.append(url.lastPathComponent)
            }
        }
        XCTAssertTrue(violations.isEmpty, "Deprecated AVSBDL layer-level API used in: \(violations)")
    }

    /// Resolves `DeskPad/Backend/Render/` from this test file's location
    /// so the guard works regardless of where the test bundle runs from.
    private static func renderSourceDirectory() throws -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        // .../DeskPadTests/Compliance/no_deprecated_avsbdl_api_tests.swift
        // -> .../DeskPad/Backend/Render
        let repoRoot = thisFile
            .deletingLastPathComponent() // Compliance
            .deletingLastPathComponent() // DeskPadTests
            .deletingLastPathComponent() // repo root
        return repoRoot
            .appendingPathComponent("DeskPad")
            .appendingPathComponent("Backend")
            .appendingPathComponent("Render")
    }

    /// Removes `//` line comments and `/* ... */` block comments so the
    /// regex only inspects executable Swift code.
    private static func stripComments(_ source: String) -> String {
        var output = ""
        output.reserveCapacity(source.count)
        var index = source.startIndex
        let end = source.endIndex
        var inBlockComment = false
        while index < end {
            let remaining = source[index ..< end]
            if inBlockComment {
                if let close = remaining.range(of: "*/") {
                    index = close.upperBound
                    inBlockComment = false
                } else {
                    break
                }
                continue
            }
            if remaining.hasPrefix("/*") {
                inBlockComment = true
                index = source.index(index, offsetBy: 2)
                continue
            }
            if remaining.hasPrefix("//") {
                if let newline = remaining.firstIndex(of: "\n") {
                    output.append("\n")
                    index = source.index(after: newline)
                } else {
                    break
                }
                continue
            }
            output.append(source[index])
            index = source.index(after: index)
        }
        return output
    }
}
