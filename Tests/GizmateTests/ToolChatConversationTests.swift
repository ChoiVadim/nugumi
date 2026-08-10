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
        let store = ToolChatConversation { _, _, _, _ in "an answer" }

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
        let store = ToolChatConversation { history, _, _, onPartial in
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
        let store = ToolChatConversation { _, _, _, _ in throw Boom() }

        store.send("hello")
        await settle(store)

        XCTAssertEqual(store.pending?.failure, "no key")
        XCTAssertTrue(store.turns.isEmpty)
    }

    func testBlankMessagesAndReentryAreIgnored() async {
        var calls = 0
        let store = ToolChatConversation { _, _, _, _ in
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

    /// A reply that was an instruction to the builder is not history. Recording
    /// it would put `BUILD: …` in the transcript, send it back as context on
    /// every later message, and leave the question sitting above an answer the
    /// user was never shown.
    func testAnInterceptedReplyLeavesNoTurnBehind() async {
        let store = ToolChatConversation { _, _, _, _ in "BUILD: a grammar fixer" }
        var handed: String?

        store.send("make me a grammar fixer") { reply in
            handed = reply
            return true
        }
        await settle(store)

        XCTAssertEqual(handed, "BUILD: a grammar fixer")
        XCTAssertTrue(store.turns.isEmpty)
        XCTAssertNil(store.pending)
    }

    /// A picture goes to the model on the turn it was attached to, and stays on
    /// that turn afterwards so the transcript can show what was shown.
    func testAnAttachedPictureIsSentAndKeptOnItsTurn() async {
        var sent: [ImageInput] = []
        let store = ToolChatConversation { _, _, images, _ in
            sent = images
            return "that is a cat"
        }

        store.send("what is this", images: [.stub])
        await settle(store)

        XCTAssertEqual(sent.map(\.mediaType), ["image/jpeg"])
        XCTAssertEqual(store.turns.first?.images.count, 1)
    }

    /// A picture with no words is a message. The composer enables send for it,
    /// so the store must not throw it away for having an empty question.
    func testAPictureWithNoWordsIsStillAMessage() async {
        var asked: String?
        let store = ToolChatConversation { _, question, _, _ in
            asked = question
            return "a cat, again"
        }

        store.send("", images: [.stub])
        await settle(store)

        XCTAssertEqual(asked, "")
        XCTAssertEqual(store.turns.count, 1)
    }

    /// And the emptiest message of all is still nothing.
    func testAMessageWithNeitherWordsNorPicturesIsIgnored() async {
        var calls = 0
        let store = ToolChatConversation { _, _, _, _ in
            calls += 1
            return "should not happen"
        }

        store.send("   ")
        await settle(store)

        XCTAssertEqual(calls, 0)
        XCTAssertTrue(store.turns.isEmpty)
    }

    /// And the common case is untouched: a reply nobody intercepts is an answer.
    func testAReplyNobodyClaimsIsRecordedAsUsual() async {
        let store = ToolChatConversation { _, _, _, _ in "Ollama runs models locally." }

        store.send("what is ollama") { _ in false }
        await settle(store)

        XCTAssertEqual(store.turns.map(\.answer), ["Ollama runs models locally."])
    }
}
