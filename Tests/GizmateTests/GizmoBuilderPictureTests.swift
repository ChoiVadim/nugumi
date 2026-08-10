import Foundation
import GizmateToolAgentCore
import XCTest
@testable import Gizmate

/// What happens to a picture between the composer and the model.
///
/// The defect these exist for shipped once already and was invisible: a
/// message with a reference screenshot reached the builder as words alone, and
/// nothing anywhere said the picture had been dropped.
@MainActor
final class GizmoBuilderPictureTests: XCTestCase {
    private func picture() -> ChatImage {
        ChatImage(
            id: UUID(),
            input: ImageInput(data: Data([0xFF, 0xD8]), mediaType: "image/jpeg"),
            thumbnail: Data([0xFF, 0xD8])
        )
    }

    /// Records what each stubbed call was handed, so a case can assert on the
    /// pictures rather than on a build that never runs here.
    ///
    /// The expectation is not ceremony: `GizmoBuilder.run` starts a `Task`, so
    /// the agent closure has not been called yet when `startNew` returns and a
    /// direct read of these would always see `nil`.
    private final class Seen {
        var generated: [ChatImage]?
        var revised: [ChatImage]?
        let called = XCTestExpectation(description: "the agent was called")
    }

    private func makeBuilder(
        seesPictures: Bool,
        seen: Seen
    ) -> GizmoBuilder {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GizmoBuilderPictureTests.\(UUID().uuidString)")
        return GizmoBuilder(
            tools: ToolsStore(directoryURL: dir, migrateLegacy: false),
            runner: { _, _, _ in .idle },
            agent: GizmoBuilder.Agent(
                generate: { _, images, _, _, _, _ in
                    seen.generated = images
                    seen.called.fulfill()
                    return .failure(ToolGeneratorError.emptyDescription)
                },
                revise: { _, _, _, images, _, _, _, _ in
                    seen.revised = images
                    seen.called.fulfill()
                    return .failure(ToolGeneratorError.emptyDescription)
                },
                repair: { _, _, _, _, _, _, _ in fatalError("unused") },
                seesPictures: { seesPictures }
            )
        )
    }

    func testAPictureReachesTheModelAndTheTranscript() {
        let seen = Seen()
        let builder = makeBuilder(seesPictures: true, seen: seen)
        let shown = picture()

        builder.startNew("a stats panel", asking: "make me this", showing: [shown])
        wait(for: [seen.called], timeout: 2)

        XCTAssertEqual(seen.generated, [shown])
        XCTAssertEqual(builder.chat.messages.first?.images, [shown])
    }

    /// The path that used to be the black hole: `@Mac Usage` skips the model
    /// call entirely, so anything not handed to `startEdit` here was gone.
    func testAPictureSurvivesAnEditOfAnExistingGizmo() {
        let seen = Seen()
        let builder = makeBuilder(seesPictures: true, seen: seen)
        let shown = picture()

        builder.startEdit(UUID(), instruction: "like this", asking: "like this", showing: [shown])
        wait(for: [seen.called], timeout: 2)

        XCTAssertEqual(seen.revised, [shown])
        XCTAssertEqual(builder.chat.messages.first?.images, [shown])
    }

    /// A model that cannot look at pictures gets none, and the person is told
    /// so in the transcript rather than left to wonder why the reference had
    /// no effect. The clients throw on a picture a blind model can't take, so
    /// the alternative is losing the whole build over an attachment.
    func testABlindModelIsSentNoPictureAndSaysSo() {
        let seen = Seen()
        let builder = makeBuilder(seesPictures: false, seen: seen)

        builder.startNew("a stats panel", asking: "make me this", showing: [picture()])
        wait(for: [seen.called], timeout: 2)

        XCTAssertEqual(seen.generated, [])
        XCTAssertTrue(
            builder.chat.messages.contains { $0.role == .assistant && $0.text.contains("pictures") },
            "the transcript should say the picture went unused"
        )
    }

    /// No note when there was nothing to lose: a build started without a
    /// picture must not explain that it didn't use one. Asserted on the
    /// subject rather than on the message count, because the stubbed build
    /// fails on purpose and its failure is a message too.
    func testAModelWithoutVisionSaysNothingWhenNoPictureWasShown() {
        let seen = Seen()
        let builder = makeBuilder(seesPictures: false, seen: seen)

        builder.startNew("a stats panel", asking: "make me this")
        wait(for: [seen.called], timeout: 2)

        XCTAssertFalse(builder.chat.messages.contains { $0.text.contains("pictures") })
    }
}
