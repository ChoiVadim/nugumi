import GizmateToolAgentCore
import XCTest
@testable import Gizmate

@MainActor
final class ToolBuilderChatTests: XCTestCase {
    /// A session opens with the line it was given, and with nothing when it was
    /// given nothing. The default used to be a greeting, which meant Home's
    /// chat could never show an empty screen.
    func testASessionOpensWithWhateverItWasGiven() {
        XCTAssertTrue(ToolBuilderChatSession().messages.isEmpty)

        let greeted = ToolBuilderChatSession(greeting: "Nothing is saved until you press Save.")

        XCTAssertEqual(greeted.messages.count, 1)
        XCTAssertEqual(greeted.messages[0].role, .assistant)
        XCTAssertTrue(greeted.messages[0].text.contains("Save"))
        XCTAssertFalse(greeted.isAwaitingAnswer)
        XCTAssertNil(greeted.readyMessage)
    }

    func testCandidateReadyProducesInlineSaveMessageUntilRevisionStarts() {
        let session = ToolBuilderChatSession()

        session.appendError("The previous build failed.")
        XCTAssertTrue(session.hasError)
        XCTAssertEqual(
            session.currentActivity,
            "Stopped before a verified gizmo was ready."
        )
        let messageCount = session.messages.count

        session.candidateReady("Send to Notes")

        XCTAssertFalse(session.hasError)
        XCTAssertEqual(
            session.readyMessage,
            "Send to Notes is ready. Review it, ask for a change, or save the gizmo."
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
            questions: [.init(question: "Which app should receive the text?")]
        )
        let responseTask = Task { try await session.ask(request) }
        await gate.waitUntilPaused()
        XCTAssertTrue(session.isAwaitingAnswer)
        // The question is the card's, not the transcript's: drawing it as prose
        // as well would say it twice and leave the second copy unanswerable.
        XCTAssertEqual(
            session.pendingQuestions?.current?.question,
            "Which app should receive the text?"
        )
        XCTAssertFalse(session.messages.contains { $0.text.hasPrefix("Which app") })

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
        XCTAssertEqual(response.answers, ["Notes"])
        // What the transcript keeps once the card is gone: one line pairing the
        // question with the answer, so the record survives without the control.
        XCTAssertEqual(session.messages.last?.role, .assistant)
        XCTAssertEqual(
            session.messages.last?.text,
            "**Which app should receive the text?** Notes"
        )
        XCTAssertNil(session.pendingQuestions)
        XCTAssertFalse(session.isAwaitingAnswer)
    }

    /// Every question in one card, and the card is what steps through them.
    func testStepsThroughEveryQuestionBeforeAnsweringTheBuilder() async throws {
        let gate = AnswerRegistrationGate()
        let session = ToolBuilderChatSession(
            beforeAnswerWaitRegistration: { await gate.pause() }
        )
        let request = try ToolAgentAskUserRequestV1(questions: [
            .init(question: "What should it read?", options: ["My selection", "A screenshot"]),
            .init(question: "Where should the answer go?", options: ["A panel"]),
            .init(question: "What should it be called?"),
        ])
        let responseTask = Task { try await session.ask(request) }
        await gate.waitUntilPaused()

        XCTAssertEqual(session.pendingQuestions?.step, 1)
        XCTAssertEqual(session.pendingQuestions?.total, 3)
        await session.answer("My selection")
        XCTAssertEqual(session.pendingQuestions?.step, 2)
        XCTAssertEqual(session.pendingQuestions?.current?.question, "Where should the answer go?")
        await session.answer("A panel")
        // ✕ on the last one. Skipping is not cancelling, so the builder still
        // gets a full set and still finishes the gizmo.
        await session.skipQuestions()
        await gate.release()

        let response = try await responseTask.value
        XCTAssertEqual(response.answers, ["My selection", "A panel", ""])
        XCTAssertNil(session.pendingQuestions)
        XCTAssertFalse(session.isAwaitingAnswer)
        XCTAssertEqual(
            session.messages.last?.text,
            "**What should it read?** My selection\n\n**Where should the answer go?** A panel"
        )
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
            questions: [.init(question: "Where should I save it?")]
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
            questions: [.init(question: "Where should I save it?")]
        )
        let firstTask = Task { try await session.ask(firstRequest) }
        await gate.waitUntilPaused()
        _ = await session.submit("Desktop")
        await session.cancel()
        await gate.release()
        _ = await firstTask.result
        await gate.reset()

        let retryRequest = try ToolAgentAskUserRequestV1(
            questions: [.init(question: "Which folder should I use?")]
        )
        let retryTask = Task { try await session.ask(retryRequest) }
        await gate.waitUntilPaused()
        _ = await session.submit("Downloads")
        await gate.release()
        let response = try await retryTask.value

        XCTAssertEqual(response.answers, ["Downloads"])
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
        await broker.answer(["stale"], for: firstGeneration)

        let retryGeneration = try await broker.begin()
        let retryWait = Task {
            try await broker.wait(for: retryGeneration)
        }
        await retryGate.waitUntilPaused()
        await broker.answer(["fresh"], for: retryGeneration)
        await retryGate.release()
        let response = try await retryWait.value

        XCTAssertEqual(response, ["fresh"])
    }

    func testSubmissionWithoutQuestionBecomesBuildRequest() async {
        let session = ToolBuilderChatSession()

        let result = await session.submit("  Save selected text to Notes  ")

        XCTAssertEqual(result, .buildRequest("Save selected text to Notes"))
        XCTAssertEqual(session.messages.last?.role, .user)
        XCTAssertEqual(session.messages.last?.text, "Save selected text to Notes")
    }

    func testSecretRequestParksTheBuildUntilTheKeyRowAnswers() async {
        let session = ToolBuilderChatSession()

        let asked = Task { await session.requestSecret("GEMINI_API_KEY") }
        while session.pendingSecret == nil { await Task.yield() }

        XCTAssertEqual(session.pendingSecret, "GEMINI_API_KEY")
        XCTAssertEqual(session.messages.last?.role, .assistant)
        XCTAssertEqual(session.messages.last?.text.contains("GEMINI_API_KEY"), true)

        session.resolveSecret(true)

        let stored = await asked.value
        XCTAssertTrue(stored)
        XCTAssertNil(session.pendingSecret)
    }

    /// The whole point of the continuation is that something is suspended on it.
    /// A panel closed while the key row is up must not leave the validation
    /// handler waiting for an answer that can never arrive.
    func testCancelReleasesAPendingKeyRequest() async {
        let session = ToolBuilderChatSession()

        let asked = Task { await session.requestSecret("GEMINI_API_KEY") }
        while session.pendingSecret == nil { await Task.yield() }

        await session.cancel()

        let stored = await asked.value
        XCTAssertFalse(stored)
        XCTAssertNil(session.pendingSecret)
    }

    /// A candidate may declare two keys. The second request must not strand the
    /// first waiter, or the build hangs with no row on screen.
    func testASecondKeyRequestReleasesTheFirst() async {
        let session = ToolBuilderChatSession()

        let first = Task { await session.requestSecret("GEMINI_API_KEY") }
        while session.pendingSecret == nil { await Task.yield() }
        let second = Task { await session.requestSecret("TELEGRAM_BOT_TOKEN") }
        while session.pendingSecret != "TELEGRAM_BOT_TOKEN" { await Task.yield() }

        let firstAnswer = await first.value
        XCTAssertFalse(firstAnswer)

        session.resolveSecret(true)
        let secondAnswer = await second.value
        XCTAssertTrue(secondAnswer)
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
