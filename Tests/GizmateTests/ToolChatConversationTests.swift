import XCTest
@testable import Gizmate

/// Home's plain conversation — the half of its chat that builds nothing.
@MainActor
final class ToolChatConversationTests: XCTestCase {
    private func settle(_ store: ToolChatConversation) async {
        for _ in 0..<200 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
            if !store.isRunning { return }
        }
    }

    func testAFinishedTurnJoinsTheHistory() async {
        let store = ToolChatConversation { _, _, _ in "an answer" }

        store.send("hello")
        await settle(store)

        XCTAssertEqual(store.turns.map(\.question), ["hello"])
        XCTAssertEqual(store.turns.map(\.answer), ["an answer"])
        XCTAssertNil(store.pending)
    }

    /// The reason `pending` is not just an appended turn: a half-arrived answer
    /// is not history, and carrying one as history means the next question is
    /// sent with an empty answer above it.
    func testAnUnfinishedTurnIsNotCarriedAsHistory() async {
        var seen: [[ToolChatConversation.Turn]] = []
        let store = ToolChatConversation { history, _, onPartial in
            seen.append(history)
            onPartial("half")
            await Task.yield()
            return "whole"
        }

        store.send("first")
        await settle(store)
        store.send("second")
        await settle(store)

        XCTAssertEqual(seen.first?.count, 0)
        XCTAssertEqual(seen.last?.count, 1)
        XCTAssertEqual(seen.last?.first?.answer, "whole")
    }

    func testAFailureIsShownOnItsOwnTurnRatherThanLost() async {
        struct Boom: LocalizedError { var errorDescription: String? { "no key" } }
        let store = ToolChatConversation { _, _, _ in throw Boom() }

        store.send("hello")
        await settle(store)

        XCTAssertEqual(store.pending?.failure, "no key")
        XCTAssertTrue(store.turns.isEmpty)
    }

    func testBlankMessagesAndReentryAreIgnored() async {
        var calls = 0
        let store = ToolChatConversation { _, _, _ in
            calls += 1
            try await Task.sleep(nanoseconds: 30_000_000)
            return "done"
        }

        store.send("   ")
        store.send("real")
        store.send("while the first is still running")
        await settle(store)

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.turns.map(\.question), ["real"])
    }
}
