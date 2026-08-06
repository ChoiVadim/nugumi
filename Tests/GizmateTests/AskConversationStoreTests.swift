import AppKit
import XCTest
@testable import Gizmate

/// The rules that decide what one Ask turn actually sends and keeps.
///
/// None of this was reachable by a test before. Both submit paths lived inside
/// `GizmateApp+AskGizmate.swift` as two near-copies, each holding its own
/// answer inside whichever panel happened to be on screen, so "does turning the
/// camera off stop the screenshot" could only be answered by running the app
/// and watching. `AskEngine` is a struct of closures for exactly this: the
/// store is driven here with no network, no screen and no window.
@MainActor
final class AskConversationStoreTests: XCTestCase {
    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AskConversationStoreTests.\(UUID().uuidString)")!
    }

    private func fakeCapture() -> AskGizmateScreenCapture {
        AskGizmateScreenCapture(
            image: ImageInput(data: Data([0x01]), mediaType: "image/jpeg"),
            imagePixelSize: CGSize(width: 100, height: 100),
            screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
    }

    /// Records what the store asked the app to do. A class so the closures
    /// handed to `AskEngine` can write into it while the store holds the
    /// engine by value.
    private final class Recorder {
        var captureCalls = 0
        var sentImages: [ImageInput?] = []
        var sentQuestions: [String] = []
        var sentHistories: [[AskGizmateTurn]] = []
        var shownAnnotations: [[AskGizmateAnnotation]] = []
        var clearCalls = 0
        var beginDrawingCalls = 0
        var endDrawingCalls = 0
        var strokes: [[NSPoint]] = []
        var setupProblem: String?
        var lastNeedsImage: Bool?
        var answer = "an answer"
        var annotations: [AskGizmateAnnotation] = []
        var partials: [String] = []
    }

    private func makeStore(
        _ recorder: Recorder,
        defaults: UserDefaults
    ) -> AskConversationStore {
        let capture = fakeCapture()
        let engine = AskEngine(
            capture: {
                recorder.captureCalls += 1
                return capture
            },
            ask: { history, question, image, onPartial in
                recorder.sentHistories.append(history)
                recorder.sentQuestions.append(question)
                recorder.sentImages.append(image)
                for partial in recorder.partials {
                    onPartial(partial)
                    // Real streaming has gaps, and the store's partial handler
                    // reaches the main actor through a hop. Delivering every
                    // partial in one synchronous burst would let all the hops
                    // run after the answer commits, which is a property of this
                    // fake rather than of the store.
                    await Task.yield()
                }
                return AskGizmateResponse(
                    message: recorder.answer, annotations: recorder.annotations
                )
            },
            setupError: { needsImage in
                recorder.lastNeedsImage = needsImage
                return recorder.setupProblem
            },
            showAnnotations: { annotations, _ in
                recorder.shownAnnotations.append(annotations)
            },
            clearAnnotations: { recorder.clearCalls += 1 },
            beginDrawing: {
                recorder.beginDrawingCalls += 1
                return capture
            },
            endDrawing: {
                recorder.endDrawingCalls += 1
                return recorder.strokes
            }
        )
        return AskConversationStore(engine: engine, defaults: defaults)
    }

    /// Waits for the turn `send` started. Bounded rather than unbounded: a
    /// store that never finishes should fail an assertion, not hang the suite.
    /// Yields alone are not enough — compositing strokes into a frame runs in a
    /// detached task, which needs a real suspension to come back from.
    private func settle(_ store: AskConversationStore? = nil) async {
        for _ in 0..<200 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
            if let store, !store.isRunning { return }
        }
    }

    // MARK: - The camera

    func testTheCameraOnSendsAScreenshot() async {
        let recorder = Recorder()
        let store = makeStore(recorder, defaults: scratchDefaults())

        store.send("what is this")
        await settle(store)

        XCTAssertEqual(recorder.captureCalls, 1)
        XCTAssertNotNil(recorder.sentImages.first ?? nil)
    }

    /// The point of the toggle. Off, no screen is captured at all, so an
    /// always-open chat is not photographing the desktop on every message.
    func testTheCameraOffCapturesNothingAndSendsNoImage() async {
        let recorder = Recorder()
        let store = makeStore(recorder, defaults: scratchDefaults())
        store.attachesScreen = false

        store.send("just a text question")
        await settle(store)

        XCTAssertEqual(recorder.captureCalls, 0)
        XCTAssertNil(recorder.sentImages.first ?? nil)
    }

    /// The vision requirement is a property of the message, not of Ask. Both
    /// submit paths used to refuse on a text-only model even for a question
    /// carrying no picture.
    func testTheVisionGateIsAskedAboutThisMessageNotAboutAsk() async {
        let recorder = Recorder()
        let store = makeStore(recorder, defaults: scratchDefaults())

        store.attachesScreen = false
        store.send("text only")
        await settle(store)
        XCTAssertEqual(recorder.lastNeedsImage, false)

        store.attachesScreen = true
        store.send("about my screen")
        await settle(store)
        XCTAssertEqual(recorder.lastNeedsImage, true)
    }

    func testASetupProblemFailsTheTurnWithoutSpendingARequest() async {
        let recorder = Recorder()
        recorder.setupProblem = "Add an API key first."
        let store = makeStore(recorder, defaults: scratchDefaults())

        store.send("hello")
        await settle(store)

        XCTAssertEqual(store.pending?.failure, "Add an API key first.")
        XCTAssertTrue(recorder.sentQuestions.isEmpty)
        XCTAssertEqual(recorder.captureCalls, 0)
    }

    // MARK: - The pencil

    /// Arming is what takes the shot. The press has to be the capture, because
    /// strokes are composited into a frame taken earlier and only line up with
    /// what is under them while the two are moments apart.
    func testThePencilCapturesOnPressNotOnSend() async {
        let recorder = Recorder()
        let store = makeStore(recorder, defaults: scratchDefaults())

        await store.toggleDrawing()

        XCTAssertEqual(recorder.beginDrawingCalls, 1)
        XCTAssertNotNil(store.armed)

        store.send("what is this bit")
        await settle(store)

        // The armed frame is used, so nothing is captured a second time.
        XCTAssertEqual(recorder.captureCalls, 0)
        XCTAssertNotNil(recorder.sentImages.first ?? nil)
        XCTAssertNil(store.armed)
    }

    func testPressingThePencilAgainDropsTheFrameAndTheCanvas() async {
        let recorder = Recorder()
        let store = makeStore(recorder, defaults: scratchDefaults())

        await store.toggleDrawing()
        await store.toggleDrawing()

        XCTAssertNil(store.armed)
        XCTAssertEqual(recorder.endDrawingCalls, 1)
    }

    /// Strokes have to be announced or the model reads red marks as part of
    /// the screen it is being shown.
    func testStrokesAddTheirNoteToTheQuestionAndNothingElseDoes() async {
        let recorder = Recorder()
        let store = makeStore(recorder, defaults: scratchDefaults())

        store.send("no strokes here")
        await settle(store)
        XCTAssertEqual(recorder.sentQuestions.first, "no strokes here")

        recorder.strokes = [[NSPoint(x: 0, y: 0), NSPoint(x: 5, y: 5)]]
        await store.toggleDrawing()
        store.send("circled thing")
        await settle(store)
        XCTAssertTrue(recorder.sentQuestions.last?.hasPrefix("circled thing\n\n(The red marks") == true)
    }

    // MARK: - The conversation

    func testAFinishedTurnJoinsTheHistoryAndSurvivesANewStore() async {
        let defaults = scratchDefaults()
        let recorder = Recorder()
        let store = makeStore(recorder, defaults: defaults)

        store.send("first")
        await settle(store)

        XCTAssertEqual(store.turns, [AskGizmateTurn(question: "first", answer: "an answer")])
        XCTAssertNil(store.pending)

        let reopened = makeStore(Recorder(), defaults: defaults)
        XCTAssertEqual(reopened.turns, store.turns)
    }

    func testTheNextTurnCarriesEverythingBeforeItAsHistory() async {
        let recorder = Recorder()
        let store = makeStore(recorder, defaults: scratchDefaults())

        store.send("first")
        await settle(store)
        store.send("second")
        await settle(store)

        XCTAssertEqual(recorder.sentHistories.first?.count, 0)
        XCTAssertEqual(recorder.sentHistories.last?.count, 1)
        XCTAssertEqual(recorder.sentHistories.last?.first?.question, "first")
    }

    /// The machine block must never be shown, and a stream reaches its opening
    /// fence long before its closing one.
    func testAStreamingAnswerNeverShowsTheAnnotationsBlock() async {
        let recorder = Recorder()
        recorder.partials = [
            "Click the",
            "Click the button.\n\n```annotations\n[{\"type\":\"rect\""
        ]
        var seen: [String] = []
        let store = makeStore(recorder, defaults: scratchDefaults())
        let watcher = store.$pending.sink { pending in
            if let answer = pending?.answer, !answer.isEmpty { seen.append(answer) }
        }
        defer { watcher.cancel() }

        store.send("where do I click")
        await settle(store)

        XCTAssertFalse(
            seen.contains { $0.contains("```annotations") },
            "the machine block leaked into the visible answer: \(seen)"
        )
        XCTAssertTrue(seen.contains("Click the button."))
    }

    func testClearingStartsOverAndTakesTheShapesWithIt() async {
        let defaults = scratchDefaults()
        let recorder = Recorder()
        let store = makeStore(recorder, defaults: defaults)

        store.send("first")
        await settle(store)
        let clearsBefore = recorder.clearCalls

        store.clear()

        XCTAssertTrue(store.turns.isEmpty)
        XCTAssertEqual(recorder.clearCalls, clearsBefore + 1)
        XCTAssertTrue(makeStore(Recorder(), defaults: defaults).turns.isEmpty)
    }
}
