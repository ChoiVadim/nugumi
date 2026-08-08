import AppKit
import Foundation

/// Everything `AskConversationStore` needs from the app to run one turn.
///
/// A struct of closures rather than a protocol: there is one implementation
/// (`GizmateApp`) and one stub (the tests), and a protocol with one conformer
/// is a shape waiting for a second, the same call `DockItem` records.
@MainActor
struct AskEngine {
    /// A shot of the screen under the cursor, with every Gizmate window hidden
    /// from it first.
    var capture: () async throws -> AskGizmateScreenCapture
    var ask: (
        _ history: [AskGizmateTurn],
        _ question: String,
        _ image: ImageInput?,
        _ onPartial: @escaping (String) -> Void
    ) async throws -> AskGizmateResponse
    /// A reason this turn cannot run, reported before a request is spent: no
    /// API key for the chosen model, or a text-only model handed a screenshot.
    ///
    /// `needsImage` is what moves the vision requirement off Ask and onto the
    /// message. Both submit paths used to demand `model.supportsImages`
    /// unconditionally, so a plain text question refused to run on a text
    /// model for a picture it was never going to send.
    var setupError: (_ needsImage: Bool) -> String?
    var showAnnotations: ([AskGizmateAnnotation], AskGizmateScreenCapture) -> Void
    var clearAnnotations: () -> Void
    /// Pins the current frame and raises the stroke canvas over it. `nil` when
    /// the capture failed, in which case nothing is armed and no canvas rises.
    var beginDrawing: () async -> AskGizmateScreenCapture?
    /// Takes the canvas down and hands back what was drawn on it, in AppKit
    /// global screen points, which is what `annotated(with:)` expects.
    var endDrawing: () -> [[NSPoint]]
}

/// One Ask conversation, and the only place a turn is started.
///
/// Ask used to keep its dialog as `askHistory` on the app delegate and its
/// answer inside a `TranslationPanelController`. That works while the answer is
/// a modal: the panel *is* the conversation, and when it closes so does the
/// state. A chat that sits on a screen edge and never closes needs the
/// conversation to be its own thing, driven by both surfaces, so the capsule at
/// the cursor and the docked chat write one history instead of two.
@MainActor
final class AskConversationStore: ObservableObject {
    /// A turn that has been asked and not yet answered. `answer` grows as the
    /// model streams into it; `failure` replaces it when the request dies.
    struct Pending: Equatable {
        let question: String
        /// Whether this turn is sending a picture. The composer says which of
        /// the two waits is happening rather than showing one spinner for both:
        /// a named step buys far more patience than an animation, and "reading
        /// your screen" is a different wait from "thinking".
        let usesScreen: Bool
        var answer: String = ""
        var failure: String?
    }

    @Published private(set) var turns: [AskGizmateTurn] = []
    @Published private(set) var pending: Pending?
    /// The frame the pencil pinned, while the canvas is up. Published so the
    /// composer can show the pencil lit.
    @Published private(set) var armed: AskGizmateScreenCapture?
    /// Sticky, and on by default: answering about what is on screen is what
    /// Ask is for. Off makes this an ordinary text chat, including dropping the
    /// vision-model requirement, since there is no longer a picture to look at.
    @Published var attachesScreen = true

    var isRunning: Bool { pending != nil && pending?.failure == nil }

    /// Appended to the question when strokes are riding along, or the model
    /// reads the red marks as part of the screen it is being shown.
    private static let strokeNote = "\n\n(The red marks on the screenshot are my "
        + "annotations pointing at what I'm asking about.)"

    private let engine: AskEngine
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    /// Which turn a streamed partial belongs to. A partial arrives off the
    /// backend's thread and reaches the main actor through a hop, so one can
    /// land after its own turn has committed or after the next has started.
    /// Matching on the question text would let a user who asks the same thing
    /// twice have turn one's tail typed into turn two.
    private var turn = 0

    init(engine: AskEngine, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
        turns = AskGizmateHistoryStore.load(defaults: defaults)
    }

    // MARK: - The pencil

    /// Pressing the pencil pins the frame **now** and raises the canvas;
    /// pressing it again drops both.
    ///
    /// It has to be the press rather than the send. Strokes are composited into
    /// a shot taken earlier, so they line up with what is underneath them only
    /// while the two are moments apart; a shot taken at send would be of a
    /// screen the strokes were never drawn on. Arming is what pins the frame,
    /// and it is the whole answer to "when is the screenshot taken" on this
    /// path.
    func toggleDrawing() async {
        if armed != nil {
            _ = engine.endDrawing()
            armed = nil
            return
        }
        // The last answer's shapes point at a frame that is about to stop being
        // the current one, and they would end up composited into the new shot.
        engine.clearAnnotations()
        armed = await engine.beginDrawing()
    }

    /// Pins a frame someone else already took.
    ///
    /// `startAskGizmatePrompt` uses this: its shot has to precede the capsule
    /// appearing, because activating Gizmate closes the very menu the user is
    /// asking about, and the pencil's capture-now would be one focus change too
    /// late. Same armed state either way, so `send` needs no second path.
    func arm(_ capture: AskGizmateScreenCapture) {
        armed = capture
    }

    // MARK: - Asking

    func send(_ question: String) {
        let clean = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !isRunning else { return }

        let armedFrame = armed
        let strokes = armedFrame == nil ? [] : engine.endDrawing()
        armed = nil
        let wantsImage = armedFrame != nil || attachesScreen

        if let problem = engine.setupError(wantsImage) {
            pending = Pending(question: clean, usesScreen: wantsImage, failure: problem)
            return
        }

        engine.clearAnnotations()
        pending = Pending(question: clean, usesScreen: wantsImage)
        turn += 1
        let token = turn
        let history = turns
        let asked = strokes.isEmpty ? clean : clean + Self.strokeNote
        let engine = engine

        task?.cancel()
        task = Task { [weak self] in
            do {
                let capture = try await Self.frame(
                    armed: armedFrame, strokes: strokes, wantsImage: wantsImage, engine: engine
                )
                try Task.checkCancellation()
                let response = try await UserActivity.run("Answering an Ask question") {
                    try await engine.ask(history, asked, capture?.image) { partial in
                        Task { @MainActor [weak self] in
                            guard let self, self.turn == token, self.pending != nil else { return }
                            self.pending?.answer = AskGizmateResponse.streamingMessage(partial)
                        }
                    }
                }
                try Task.checkCancellation()
                self?.commit(question: clean, response: response, capture: capture)
            } catch is CancellationError {
                self?.pending = nil
            } catch {
                self?.pending?.failure = error.localizedDescription
            }
        }
    }

    /// Records a turn that ran through the capsule's own submit path rather
    /// than through `send`.
    ///
    /// Two paths exist while the floating capsule still presents its answer in
    /// a `TranslationPanelController` and this store presents it in a
    /// transcript. They must not become two conversations, which is what this
    /// prevents: whichever surface asked, the turn lands in one history and the
    /// other reads it as context.
    func record(question: String, answer: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !answer.isEmpty else { return }
        turns = AskGizmatePromptBuilder.appending(
            AskGizmateTurn(question: question, answer: answer), to: turns
        )
        AskGizmateHistoryStore.save(turns, defaults: defaults)
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }

    /// Starts a new conversation. The last answer's shapes go with it: they
    /// point at a screen this conversation no longer refers to.
    func clear() {
        cancel()
        turns = []
        AskGizmateHistoryStore.save([], defaults: defaults)
        engine.clearAnnotations()
    }

    // MARK: - Private

    /// The picture this turn sends, or nil when it sends none.
    private static func frame(
        armed: AskGizmateScreenCapture?,
        strokes: [[NSPoint]],
        wantsImage: Bool,
        engine: AskEngine
    ) async throws -> AskGizmateScreenCapture? {
        guard wantsImage else { return nil }
        // Written long rather than as `armed ?? engine.capture()`: `??`'s right
        // side is an autoclosure, which cannot carry an `await`.
        let capture: AskGizmateScreenCapture
        if let armed {
            capture = armed
        } else {
            capture = try await engine.capture()
        }
        guard !strokes.isEmpty else { return capture }
        // Compositing decodes and re-encodes a JPEG; off the main actor, the
        // same call `submitAskGizmatePrompt` already made for the same reason.
        return await Task.detached(priority: .userInitiated) {
            capture.annotated(with: strokes)
        }.value
    }

    private func commit(
        question: String,
        response: AskGizmateResponse,
        capture: AskGizmateScreenCapture?
    ) {
        turns = AskGizmatePromptBuilder.appending(
            AskGizmateTurn(question: question, answer: response.message),
            to: turns
        )
        AskGizmateHistoryStore.save(turns, defaults: defaults)
        pending = nil
        guard !response.annotations.isEmpty, let capture else {
            engine.clearAnnotations()
            return
        }
        engine.showAnnotations(response.annotations, capture)
    }
}
