import XCTest
@testable import Nugumi

final class ModelGroupingTests: XCTestCase {
    private func model(_ id: String) -> LLMModel {
        LLMModel(id: id, shortName: id, displayName: id,
                 backend: .ollama(requiresAccount: false), supportsImages: false)
    }

    func testReadyModelsFloatUpAndRestStayGrouped() {
        let a = model("a"), b = model("b"), c = model("c"), d = model("d")
        let groups = [
            ModelGrouping.Group(title: "Local", models: [a, b]),
            ModelGrouping.Group(title: "OpenAI", models: [c, d])
        ]
        let result = ModelGrouping.partition(groups: groups, readyIDs: ["a", "c"])

        XCTAssertEqual(result.ready.map(\.id), ["a", "c"], "usable models float into Ready, in input order")
        XCTAssertEqual(result.rest.map(\.title), ["Local", "OpenAI"])
        XCTAssertEqual(result.rest[0].models.map(\.id), ["b"])
        XCTAssertEqual(result.rest[1].models.map(\.id), ["d"])
    }

    func testFullyReadyGroupIsDropped() {
        let a = model("a"), b = model("b")
        let result = ModelGrouping.partition(
            groups: [ModelGrouping.Group(title: "Local", models: [a, b])],
            readyIDs: ["a", "b"])
        XCTAssertEqual(result.ready.map(\.id), ["a", "b"])
        XCTAssertTrue(result.rest.isEmpty, "a group with nothing left over is not shown")
    }

    func testNothingReadyKeepsEveryGroup() {
        let a = model("a"), b = model("b")
        let result = ModelGrouping.partition(
            groups: [ModelGrouping.Group(title: "Local", models: [a, b])],
            readyIDs: [])
        XCTAssertTrue(result.ready.isEmpty)
        XCTAssertEqual(result.rest, [ModelGrouping.Group(title: "Local", models: [a, b])])
    }
}
