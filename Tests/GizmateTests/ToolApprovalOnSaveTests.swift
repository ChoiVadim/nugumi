import XCTest

@testable import Gizmate

/// The first-run gate is worth showing exactly once per piece of code nobody has
/// run. Getting this wrong in either direction is bad in a different way: too
/// strict and every gizmo the user just watched Gizmate build asks again anyway,
/// too loose and code that never executed runs unannounced.
final class ToolApprovalOnSaveTests: XCTestCase {
    private let fingerprint = "abc123"

    /// The build validates a candidate by running it, so a gizmo that arrived
    /// from the chat already executed in front of the user. This is the case
    /// that used to ask anyway — `apply` reset the test state, and saving
    /// revoked.
    func testCodeTheBuildAlreadyRanNeedsNoSecondConsent() {
        for kind in [ToolKind.python, .agent] {
            XCTAssertTrue(
                ToolEditorDraftVerification.savingApproves(
                    kind: kind,
                    ranFingerprint: fingerprint,
                    current: fingerprint
                ),
                "\(kind.rawValue) that already ran should save as approved"
            )
        }
    }

    /// A candidate Gizmate refused to run during the build — the ones whose real
    /// effects it would have caused — reaches save with nothing behind it.
    func testNeverRunCodeStillMeetsTheGate() {
        XCTAssertFalse(
            ToolEditorDraftVerification.savingApproves(
                kind: .python,
                ranFingerprint: nil,
                current: fingerprint
            )
        )
    }

    /// The run counts for the code that ran, not for the name it ran under.
    func testEditingAfterTheRunTakesTheApprovalBack() {
        XCTAssertFalse(
            ToolEditorDraftVerification.savingApproves(
                kind: .python,
                ranFingerprint: fingerprint,
                current: "edited-since"
            )
        )
    }

    /// A prompt and a native action execute nothing of their own, so they never
    /// had a gate to skip and must not be handed a standing approval.
    func testKindsWithNothingToApproveAreNotApproved() {
        for kind in [ToolKind.prompt, .native] {
            XCTAssertFalse(
                ToolEditorDraftVerification.savingApproves(
                    kind: kind,
                    ranFingerprint: fingerprint,
                    current: fingerprint
                ),
                "\(kind.rawValue) has no run gate to approve"
            )
        }
    }
}
