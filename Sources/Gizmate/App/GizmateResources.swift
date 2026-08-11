import Foundation

/// The app's own resources: the wordmark, the ring glyphs, the Pixelify font,
/// the onboarding videos. Everything reads them through here, never through
/// `Bundle.module`.
///
/// `Bundle.module` is code SwiftPM generates, and for an executable target it
/// searches exactly two paths:
///
///     Bundle.main.bundleURL/Gizmate_Gizmate.bundle
///     <an absolute .build path baked in at compile time>
///
/// Neither can hold the bundle in a shipped app. `Bundle.main.bundleURL` is the
/// `.app` itself, and codesign refuses to seal an app bundle with anything
/// sitting outside `Contents/` ("unsealed contents present in the bundle root").
/// The `.build` path exists on the machine that ran the build and nowhere else.
///
/// So on the build machine the second path resolves and everything works, and on
/// every other Mac `Bundle.module` hits its `fatalError` instead. That is what
/// 0.1.0 shipped: the crash landed before `setupStatusItem()`, so there was not
/// even a menu bar icon to suggest the app had ever been running.
///
/// `GizmateToolWorker` never had the bug because it resolves its own bundle by
/// hand off `Bundle.main.resourceURL` (`ToolWorkerRuntime.bundled`). This is the
/// same move for the app, and `Scripts/build-app-bundle.sh` fails the build if
/// anything under `Sources/Gizmate` reaches for `Bundle.module` again.
enum GizmateResources {
    /// Only ever used as a handle for `Bundle(for:)`, which is what locates the
    /// bundle when `Bundle.main` is somebody else's executable.
    private final class Anchor {}

    static let bundle: Bundle = {
        let name = "Gizmate_Gizmate.bundle"
        let anchor = Bundle(for: Anchor.self)
        let searched = [
            // Contents/Resources of a shipped .app. This is the one that matters.
            Bundle.main.resourceURL,
            // The build products directory under `swift run`, where SwiftPM
            // leaves the bundle beside the executable.
            Bundle.main.bundleURL,
            // Under `swift test` Bundle.main is the xctest runner, so neither of
            // the above is ours. The anchor resolves to GizmatePackageTests.xctest
            // and its parent is the build products directory. BrandMarkTests is
            // what fails when this line is missing, which makes those two tests
            // the standing guard on this whole resolver.
            anchor.resourceURL,
            anchor.bundleURL.deletingLastPathComponent(),
        ]
        for base in searched.compactMap({ $0 }) {
            let candidate = base.appendingPathComponent(name, isDirectory: true)
            if let found = Bundle(url: candidate) {
                return found
            }
        }
        // Degrade instead of trapping: every caller already treats a missing
        // resource as nil, so a wrong build loses artwork rather than the app.
        return .main
    }()
}
