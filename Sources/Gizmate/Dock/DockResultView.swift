import AppKit
import SwiftUI

/// What a docked result is showing: what the tool did so far, the line it is
/// on now, and then its answer or its failure.
///
/// Driven from `TranslationPanelController`, on the main thread like it. The
/// answer is rendered to an attributed string once, here, so the view's body
/// never re-parses a long report: the same `NSAttributedString` instance is
/// what lets `MarkdownLabel` reuse its measured height across scroll frames.
final class DockResultModel: ObservableObject {
    let title: String
    /// Settled lines of the agent's trace, in order: each step it ran.
    @Published private(set) var trace: [String] = []
    /// The line breathing right now, nil once the run is over.
    @Published private(set) var working: String?
    @Published private(set) var failure: String?
    @Published private(set) var rendered: NSAttributedString?
    private(set) var text = ""

    /// A generic wait is not part of the trace; a step's purpose is.
    static let thinking = "Thinking"

    init(title: String) {
        self.title = title
    }

    func beginLoading(_ line: String) {
        trace = []
        failure = nil
        rendered = nil
        text = ""
        working = line
    }

    func updateLoading(_ line: String) {
        settleWorking()
        working = line
    }

    func finish(answer: String) {
        settleWorking()
        working = nil
        text = answer
        rendered = TranslationContentView.renderedMarkdownText(
            answer,
            font: .systemFont(ofSize: 12.5),
            color: NSColor(calibratedWhite: 1, alpha: 0.9)
        )
    }

    func fail(_ message: String) {
        settleWorking()
        working = nil
        failure = message
    }

    private func settleWorking() {
        guard let working, working != Self.thinking else { return }
        trace.append(working)
    }
}

/// A result on an edge, as its own component: the Ask dock's transcript with
/// one exchange in it. The bubble is the gizmo that was asked, the trace under
/// it is what the agent did (each script it ran, by its own one-line purpose),
/// the breathing line is where it is now, and the answer follows in the chat's
/// markdown at the chat's size.
///
/// No title row and no close button: the dock already has both ways out (the
/// handle and Escape), and a row of chrome above the first line costs every
/// reading of the answer. Copy rides in the top fade the way Ask's new-chat
/// disc does, and only once there is something to copy.
struct DockResultView: View {
    @ObservedObject var model: DockResultModel
    let onCopy: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                ChatQuestionBubble(text: model.title)
                ForEach(Array(model.trace.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let working = model.working {
                    ChatThinkingText(text: working)
                }
                if let failure = model.failure {
                    ChatProblemText(message: failure)
                }
                if let rendered = model.rendered {
                    MarkdownLabel(text: rendered)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 14)
            // DESIGN.md §8: thin overlay scroller, never a legacy track.
            .background(ScrollerConfigurator())
        }
        .scrollIndicators(.automatic)
        .mask(AskChatView.topFade)
        .overlay(alignment: .topTrailing) {
            if model.rendered != nil {
                ResetDiscButton(symbol: "doc.on.doc", label: "", accessibilityTitle: "Copy", action: onCopy)
                    .help("Copy")
                    .padding(.trailing, 6)
            }
        }
        .foregroundStyle(FlowTheme.ink)
    }
}
