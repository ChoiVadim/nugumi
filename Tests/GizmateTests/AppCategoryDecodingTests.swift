import XCTest
@testable import Gizmate

/// Retiring a category must not cost the user the assignments they made for the
/// ones that stayed. `CustomAppAssignment` is persisted as a single JSON array,
/// so one unknown `category` throwing would take the whole list with it.
final class AppCategoryDecodingTests: XCTestCase {

    func testRetiredCategoryDecodesAsOtherInsteadOfThrowing() throws {
        let json = Data(#"["workMessages","custom","email"]"#.utf8)
        let decoded = try JSONDecoder().decode([AppCategory].self, from: json)
        XCTAssertEqual(decoded, [.workMessages, .other, .email])
    }

    /// The whole point: the surviving entries are still there afterwards.
    func testOneUnknownCategoryDoesNotDropTheRestOfTheList() throws {
        let json = Data("""
        [{"bundleID":"com.tinyspeck.slackmacgap","name":"Slack","category":"workMessages"},
         {"bundleID":"com.example.legacy","name":"Legacy","category":"custom"}]
        """.utf8)
        let decoded = try JSONDecoder().decode([CustomAppAssignment].self, from: json)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded.first?.category, .workMessages)
        XCTAssertEqual(decoded.last?.category, .other)
    }
}
