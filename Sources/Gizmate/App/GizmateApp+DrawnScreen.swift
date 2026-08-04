import AppKit
import Carbon.HIToolbox
import Foundation

/// The two halves of drawing as a gizmo's input and as its result: the user
/// marks up the screen before the run, and the model marks it up after.
///
/// Both overlays already existed for Ask. What is here is the part Ask never
/// needed — an input that ends on its own keystroke instead of a prompt field's
/// submit, and an annotation layer that stands alone instead of following a
/// panel's lifetime.
extension GizmateApp {
    /// Captures the screen, lets the user draw on it, and returns the marked-up
    /// image. nil means Esc: a gizmo the user walked away from is cancelled, not
    /// failed — the same contract `.screenshot` and `.ask` already use. Throws
    /// only for a capture that could not be taken at all, which is a real error
    /// worth reporting (usually missing Screen Recording permission).
    @MainActor
    func captureDrawnScreen() async throws -> AskGizmateScreenCapture? {
        let sharingSnapshot = Self.hideAppWindowsFromScreenCapture()
        let capture: AskGizmateScreenCapture
        do {
            capture = try await ScreenshotCapture.captureActiveScreen(containing: NSEvent.mouseLocation)
        } catch {
            Self.restoreAppWindowSharing(sharingSnapshot)
            throw error
        }
        Self.restoreAppWindowSharing(sharingSnapshot)

        let strokes = await withCheckedContinuation { (cont: CheckedContinuation<[[NSPoint]]?, Never>) in
            var resumed = false
            // Closed before the replacement is built: the new canvas takes key
            // focus in its own init, and a stale one's teardown relinquishes it.
            gizmoDrawingOverlay?.close()
            let overlay = AskDrawingOverlayController(
                screenFrame: capture.screenFrame,
                hint: "Mark what you mean, then press ⏎"
            ) { [weak self] submitted in
                guard !resumed else { return }
                resumed = true
                // Read the strokes before closing: `close()` tears down the
                // canvas that owns them.
                let drawn = submitted ? self?.gizmoDrawingOverlay?.strokes ?? [] : nil
                self?.gizmoDrawingOverlay?.close()
                self?.gizmoDrawingOverlay = nil
                cont.resume(returning: drawn)
            }
            gizmoDrawingOverlay = overlay
        }
        guard let strokes else { return nil }
        guard !strokes.isEmpty else { return capture }
        // Compositing decodes and re-encodes a JPEG; keep it off the main actor
        // exactly as Ask does.
        return await Task.detached(priority: .userInitiated) {
            capture.annotated(with: strokes)
        }.value
    }

    /// A dragged region, as something a model can look at rather than a path it
    /// can only read aloud. `.screenshot` has always handed prompt gizmos the
    /// filename and called it an image input; this is what makes the picture
    /// actually arrive.
    ///
    /// The frame is the screen the drag happened on, not the region: it is only
    /// used to place `.annotate` shapes, and those belong on the screen rather
    /// than inside somebody's crop.
    /// The file a capture left on disk, as something a model can be shown.
    ///
    /// Media type comes off the extension rather than being assumed: a dragged
    /// region is written as PNG by `screencapture`, and a marked-up screen is
    /// re-encoded as JPEG when the strokes are burned in.
    static func imageInput(for shot: ToolScreenshot) -> ImageInput? {
        guard let data = try? Data(contentsOf: shot.imageURL) else { return nil }
        let type = shot.imageURL.pathExtension.lowercased() == "png"
            ? "image/png"
            : "image/jpeg"
        return ImageInput(data: data, mediaType: type)
    }

    @MainActor
    static func captureForModel(_ shot: ToolScreenshot) -> AskGizmateScreenCapture? {
        guard let image = imageInput(for: shot),
              let rep = NSBitmapImageRep(data: image.data)
        else { return nil }
        let frame = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.frame
            ?? NSScreen.main?.frame
            ?? .zero
        return AskGizmateScreenCapture(
            image: image,
            imagePixelSize: CGSize(width: rep.pixelsWide, height: rep.pixelsHigh),
            screenFrame: frame,
            visibleFrame: frame
        )
    }

    /// Writes the capture where a script or a native action can reach it. Only
    /// prompt gizmos take the image itself; everything else has always been
    /// handed a path, and an agent's model never sees one at all.
    static func writeDrawnScreenFile(_ capture: AskGizmateScreenCapture) throws -> ToolScreenshot {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "gizmate-drawn-\(UUID().uuidString).jpg", directoryHint: .notDirectory)
        try capture.image.data.write(to: url)
        return ToolScreenshot(imageURL: url, text: "")
    }

    /// Renders a `.annotate` gizmo's answer over the screen. Replaces whatever
    /// the last one drew, and clears when the model returned no usable shapes —
    /// which for this result mode means the run produced nothing, so say so
    /// rather than leaving the user staring at an unchanged screen.
    @MainActor
    func presentGizmoAnnotations(_ answer: String, screenFrame: NSRect, toolName: String) {
        let shapes = AskGizmateResponse.parse(answer).annotations.filter(\.isValid)
        guard !shapes.isEmpty else {
            closeGizmoAnnotations()
            ToastHUD.shared.show(text: "\(toolName) — nothing to draw")
            return
        }
        if let existing = gizmoAnnotationOverlay, existing.screenFrame == screenFrame {
            existing.show(shapes)
        } else {
            gizmoAnnotationOverlay?.close()
            let overlay = AskAnnotationOverlayController(screenFrame: screenFrame)
            overlay.show(shapes)
            gizmoAnnotationOverlay = overlay
        }
        installGizmoAnnotationDismissMonitor()
    }

    @MainActor
    func closeGizmoAnnotations() {
        gizmoAnnotationOverlay?.close()
        gizmoAnnotationOverlay = nil
        if let monitor = gizmoAnnotationDismissMonitor {
            NSEvent.removeMonitor(monitor)
            gizmoAnnotationDismissMonitor = nil
        }
    }

    /// Ask's annotation layer is torn down with the panel that produced it.
    /// Standing alone it needs its own way out, and it ignores mouse events by
    /// design, so the dismissal is a key watcher: Esc anywhere clears it.
    ///
    /// Global rather than local, because the shapes sit over the user's app and
    /// Gizmate is not frontmost by the time they appear. Global monitors cannot
    /// consume the event, which is right here — Esc keeps working in whatever
    /// the user is actually using.
    @MainActor
    private func installGizmoAnnotationDismissMonitor() {
        guard gizmoAnnotationDismissMonitor == nil else { return }
        gizmoAnnotationDismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard Int(event.keyCode) == kVK_Escape else { return }
            Task { @MainActor in self?.closeGizmoAnnotations() }
        }
    }
}
