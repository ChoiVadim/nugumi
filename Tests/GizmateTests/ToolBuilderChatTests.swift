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
