import AppKit
import SwiftUI

/// What a docked result is showing: the wait, the answer, or the failure.
/// Driven from `TranslationPanelController`, on the main thread like it.
final class DockResultModel: ObservableObject {
    enum Stage: Equatable {
        case loading(String)
        case answer(String)
        case failure(String)
    }

    let title: String
    @Published var stage: Stage

    init(title: String, stage: Stage = .loading("Thinking")) {
        self.title = title
        self.stage = stage
    }

    var text: String {
        if case .answer(let text) = stage { return text }
        return ""
    }
}

/// A result on an edge, as its own component.
///
/// It used to be the floating panel's content view laid into the dock
/// "chromeless": the layout, fonts and buttons built for a card beside the
/// cursor, squeezed into a 380pt column on the bezel. The two are different
/// things. A floating answer is glanced at and dismissed; a docked one is read
/// beside whatever you are doing, at the size the Ask dock already reads at.
/// So this speaks the Ask dock's language: a title row, the chat's markdown
/// text, and a line that breathes while the tool works, naming the agent's
/// current step.
struct DockResultView: View {
    @ObservedObject var model: DockResultModel
    let onCopy: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider().background(FlowTheme.hairline)
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                    .padding(.bottom, 4)
                    // DESIGN.md §8: thin overlay scroller, never a legacy track.
                    .background(ScrollerConfigurator())
            }
            .scrollIndicators(.automatic)
        }
        // No padding of its own: the panel holds it off the glass by
        // `DockGeometry.contentMargin`, the same as every resident.
        .foregroundStyle(FlowTheme.ink)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(model.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FlowTheme.inkSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if !model.text.isEmpty {
                ResetDiscButton(symbol: "doc.on.doc", label: "", accessibilityTitle: "Copy", action: onCopy)
                    .help("Copy")
            }
            ResetDiscButton(symbol: "xmark", label: "", accessibilityTitle: "Close", action: onClose)
                .help("Close")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .loading(let text):
            ChatThinkingText(text: text)
        case .answer(let text):
            ChatAnswerText(markdown: text)
        case .failure(let message):
            ChatProblemText(message: message)
        }
    }
}
