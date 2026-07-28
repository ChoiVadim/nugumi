import GizmateToolAgentCore
import XCTest
@testable import Gizmate

@MainActor
final class ToolBuilderChatTests: XCTestCase {
    func testSessionStartsWithAssistantSaveBoundary() {
        let session = ToolBuilderChatSession()

        XCTAssertEqual(session.messages.count, 1)
        XCTAssertEqual(session.messages[0].role, .assistant)
        XCTAssertTrue(session.messages[0].text.contains("describe"))
        XCTAssertTrue(session.messages[0].text.contains("Save"))
        XCTAssertFalse(session.isAwaitingAnswer)
        XCTAssertNil(session.readyMessage)
    }

    func testCandidateReadyProducesInlineSaveMessageUntilRevisionStarts() {
        let session = ToolBuilderChatSession()

        session.appendError("The previous build failed.")
        XCTAssertTrue(session.hasError)
        XCTAssertEqual(
            session.currentActivity,
            "Stopped before a verified tool was ready."
        )
        let messageCount = session.messages.count

        session.candidateReady("Send to Notes")

        XCTAssertFalse(session.hasError)
        XCTAssertEqual(
            session.readyMessage,
            "Send to Notes is ready. Review it, ask for a change, or save the tool."
        )
        XCTAssertEqual(session.messages.count, messageCount)

        session.markCandidateStale()

        XCTAssertNil(session.readyMessage)
        XCTAssertFalse(session.hasError)
    }

    func testAnswerBeforeBrokerRegistrationIsNotDropped() async throws {
        let gate = AnswerRegistrationGate()
        let session = ToolBuilderChatSession(
            beforeAnswerWaitRegistration: { await gate.pause() }
        )
        let request = try ToolAgentAskUserRequestV1(
            question: "Which app should receive the text?"
        )
        let responseTask = Task { try await session.ask(request) }
        await gate.waitUntilPaused()
        XCTAssertTrue(session.isAwaitingAnswer)

        let submission = await session.submit("Notes")
        await gate.release()
        let watchdog = Task {
            do {
                try await Task.sleep(for: .seconds(1))
                await session.cancel()
            } catch {}
        }
        let response = try await responseTask.value
        watchdog.cancel()

        XCTAssertEqual(submission, .answeredClarification)
        XCTAssertEqual(response.answer, "Notes")
        XCTAssertEqual(
            session.messages.suffix(2).map(\.role),
            [.assistant, .user]
        )
        XCTAssertEqual(
            session.messages.suffix(2).map(\.text),
            ["Which app should receive the text?", "Notes"]
        )
        XCTAssertFalse(session.isAwaitingAnswer)
    }

    func testActivityIsDeduplicatedAndBounded() {
        let session = ToolBuilderChatSession(activityLimit: 3)

        session.recordActivity("Understanding your request…")
        session.recordActivity("Understanding your request…")
        session.recordActivity("Building the tool…")
        session.recordActivity("Testing it in the sandbox…")
        session.recordActivity("Building the tool…")
        session.recordActivity("Finishing the tool…")

        XCTAssertEqual(
            session.activity,
            [
                "Testing it in the sandbox…",
                "Building the tool…",
                "Finishing the tool…",
            ]
        )
        XCTAssertEqual(session.currentActivity, "Finishing the tool…")
    }

    func testCancellationBeforeRegistrationResumesAsk() async throws {
        let gate = AnswerRegistrationGate()
        let session = ToolBuilderChatSession(
            beforeAnswerWaitRegistration: { await gate.pause() }
        )
        let request = try ToolAgentAskUserRequestV1(
            question: "Where should I save it?"
        )
        let responseTask = Task { try await session.ask(request) }
        await gate.waitUntilPaused()

        await session.cancel()
        await gate.release()
        let result = await responseTask.result

        guard case .failure(let error) = result else {
            return XCTFail("Expected cancellation")
        }
        XCTAssertTrue(error is CancellationError)
        XCTAssertFalse(session.isAwaitingAnswer)
    }

    func testCancellationDoesNotPoisonNextBuildAttempt() async throws {
        let gate = AnswerRegistrationGate()
        let session = ToolBuilderChatSession(
            beforeAnswerWaitRegistration: { await gate.pause() }
        )
        let firstRequest = try ToolAgentAskUserRequestV1(
            question: "Where should I save it?"
        )
        let firstTask = Task { try await session.ask(firstRequest) }
        await gate.waitUntilPaused()
        _ = await session.submit("Desktop")
        await session.cancel()
        await gate.release()
        _ = await firstTask.result
        await gate.reset()

        let retryRequest = try ToolAgentAskUserRequestV1(
            question: "Which folder should I use?"
        )
        let retryTask = Task { try await session.ask(retryRequest) }
        await gate.waitUntilPaused()
        _ = await session.submit("Downloads")
        await gate.release()
        let response = try await retryTask.value

        XCTAssertEqual(response.answer, "Downloads")
    }

    func testLateAnswerAfterRegisteredCancellationIsDropped() async throws {
        let retryGate = TargetedAnswerRegistrationGate(targetCall: 2)
        let (registrations, registration) = AsyncStream<Void>.makeStream()
        let broker = ToolBuilderAnswerBroker(
            beforeWaitRegistration: { await retryGate.pauseOnTargetCall() },
            onWaitRegistered: { registration.yield(()) }
        )
        var registrationIterator = registrations.makeAsyncIterator()
        let firstGeneration = try await broker.begin()
        let firstWait = Task {
            try await broker.wait(for: firstGeneration)
        }
        _ = await registrationIterator.next()

        await broker.cancel(firstGeneration)
        _ = await firstWait.result
        await broker.answer("stale", for: firstGeneration)

        let retryGeneration = try await broker.begin()
        let retryWait = Task {
            try await broker.wait(for: retryGeneration)
        }
        await retryGate.waitUntilPaused()
        await broker.answer("fresh", for: retryGeneration)
        await retryGate.release()
        let response = try await retryWait.value

        XCTAssertEqual(response, "fresh")
    }

    func testSubmissionWithoutQuestionBecomesBuildRequest() async {
        let session = ToolBuilderChatSession()

        let result = await session.submit("  Save selected text to Notes  ")

        XCTAssertEqual(result, .buildRequest("Save selected text to Notes"))
        XCTAssertEqual(session.messages.last?.role, .user)
        XCTAssertEqual(session.messages.last?.text, "Save selected text to Notes")
    }

}

private actor AnswerRegistrationGate {
    private var isPaused = false
    private var isReleased = false
    private var pauseObserver: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        isPaused = true
        pauseObserver?.resume()
        pauseObserver = nil
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilPaused() async {
        guard !isPaused else { return }
        await withCheckedContinuation { pauseObserver = $0 }
    }

    func release() {
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func reset() {
        isPaused = false
        isReleased = false
        pauseObserver = nil
        releaseWaiter = nil
    }
}

private actor TargetedAnswerRegistrationGate {
    private let targetCall: Int
    private var callCount = 0
    private var isPaused = false
    private var isReleased = false
    private var pauseObserver: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(targetCall: Int) {
        self.targetCall = targetCall
    }

    func pauseOnTargetCall() async {
        callCount += 1
        guard callCount == targetCall else { return }
        isPaused = true
        pauseObserver?.resume()
        pauseObserver = nil
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilPaused() async {
        guard !isPaused else { return }
        await withCheckedContinuation { pauseObserver = $0 }
    }

    func release() {
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
