import XCTest
@testable import Gizmate

/// `FlowTheme.accent` is a light grey, so it works as a foreground colour and
/// fails as a background under white text — the label lands at near-zero
/// contrast. That mistake shipped twice while the palette was being reworked
/// and both times it was caught by eye, from a screenshot, rather than by
/// anything in the build.
///
/// Raised surfaces belong to the elevation ladder (`raised`, `raisedStrong`),
/// which is dark enough to keep white legible. This scans the sources for the
/// old shape so the next one fails here instead of in someone's window.
final class PaletteRuleTests: XCTestCase {
    func testAccentIsNeverUsedAsASolidFill() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GizmateTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/Gizmate")

        let files = try FileManager.default
            .subpathsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(files.isEmpty, "Source scan found nothing — the path above is wrong.")

        var violations: [String] = []
        for file in files {
            let path = sources.appendingPathComponent(file)
            let lines = try String(contentsOf: path, encoding: .utf8)
                .components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Direct: .fill(FlowTheme.accent)
                let direct = trimmed.contains("fill(FlowTheme.accent)")
                // Wrapped over lines:
                //     .fill(
                //         condition ? FlowTheme.accent : …
                let wrapped = (trimmed == "FlowTheme.accent" || trimmed == "? FlowTheme.accent")
                    && lines[max(0, index - 3)..<index].contains { $0.contains(".fill(") }
                guard direct || wrapped else { continue }
                // Escape hatch for fills that carry no content — a status dot
                // has nothing to contrast against, so the rule does not apply.
                let exempt = lines[max(0, index - 3)...index]
                    .contains { $0.contains("palette-ok") }
                if !exempt {
                    violations.append("\(file):\(index + 1)  \(trimmed)")
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            FlowTheme.accent used as a solid fill — white text on it has no contrast.
            Use FlowTheme.raised (surfaces) or FlowTheme.raisedStrong (primary
            actions), both with a FlowTheme.edge border:
            \(violations.joined(separator: "\n"))
            """
        )
    }
}
