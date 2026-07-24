import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreServices
import CoreText
import CryptoKit
import Darwin
import Foundation
import ServiceManagement
import Sparkle
import SwiftUI
import UserNotifications
import Vision

enum ScreenshotTranslationError: LocalizedError {
    case captureCancelled
    case captureFailed(Int32)
    case captureFailedDetail(String)
    case noTextRecognized
    case screenRecordingPermissionDenied

    var errorDescription: String? {
        switch self {
        case .captureCancelled:
            "Screenshot selection was cancelled."
        case .captureFailed(let status):
            "Screenshot capture failed with exit code \(status)."
        case .captureFailedDetail(let message):
            "Screenshot capture failed: \(message)"
        case .noTextRecognized:
            "No readable text was found in the selected area."
        case .screenRecordingPermissionDenied:
            "Nugumi needs Screen Recording permission to capture screenshots. Open settings to enable it, then choose Quit & Reopen to apply the change."
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        guard let screenshotError = error as? ScreenshotTranslationError else {
            return false
        }

        if case .captureCancelled = screenshotError {
            return true
        }
        return false
    }
}

struct AskNugumiScreenCapture {
    let image: ImageInput
    let imagePixelSize: CGSize
    // AppKit global coordinates in points.
    let screenFrame: CGRect
    let visibleFrame: CGRect
}

extension AskNugumiScreenCapture {
    /// Burns user-drawn strokes (AppKit global screen points) into the
    /// screenshot as red marks so the vision model can see what the user is
    /// pointing at. Best-effort: any decode/encode failure returns `self`
    /// unannotated — the request is never blocked on annotation.
    func annotated(with strokes: [[NSPoint]]) -> AskNugumiScreenCapture {
        guard strokes.contains(where: { $0.count > 1 }),
              screenFrame.width > 0, screenFrame.height > 0,
              let cgImage = NSBitmapImageRep(data: image.data)?.cgImage
        else { return self }

        let width = cgImage.width
        let height = cgImage.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return self }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // AppKit global coordinates and CGContext both use a bottom-left
        // origin, so the mapping is pure scale + offset — no y flip.
        let scaleX = CGFloat(width) / screenFrame.width
        let scaleY = CGFloat(height) / screenFrame.height
        context.setStrokeColor(CGColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1))
        // 4 pt on screen scaled to image pixels, floored so marks stay
        // visible on screenshots downscaled to the 2048 px vision edge.
        context.setLineWidth(max(3, 4 * scaleX))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for stroke in strokes where stroke.count > 1 {
            let mapped = stroke.map { point in
                CGPoint(
                    x: (point.x - screenFrame.minX) * scaleX,
                    y: (point.y - screenFrame.minY) * scaleY
                )
            }
            let path = CGMutablePath()
            path.move(to: mapped[0])
            for point in mapped.dropFirst() {
                path.addLine(to: point)
            }
            context.addPath(path)
            context.strokePath()
        }

        guard let composited = context.makeImage() else { return self }
        let bitmap = NSBitmapImageRep(cgImage: composited)
        let jpegProps: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: 0.85]
        guard let jpeg = bitmap.representation(using: .jpeg, properties: jpegProps)
        else { return self }

        return AskNugumiScreenCapture(
            image: ImageInput(data: jpeg, mediaType: "image/jpeg"),
            imagePixelSize: imagePixelSize,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )
    }
}

enum ScreenshotCapture {
    @MainActor
    static func captureActiveScreen(containing point: NSPoint = NSEvent.mouseLocation) async throws -> AskNugumiScreenCapture {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenshotTranslationError.screenRecordingPermissionDenied
        }

        let screen = NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen else {
            throw ScreenshotTranslationError.captureFailedDetail("No screen is available.")
        }

        guard let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw ScreenshotTranslationError.captureFailedDetail("Could not capture the active screen.")
        }
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame

        let imagePayload = try await Task.detached(priority: .userInitiated) {
            guard let captured = CGDisplayCreateImage(screenID) else {
                throw ScreenshotTranslationError.captureFailedDetail("Could not capture the active screen.")
            }

            // Retina/5K screenshots as lossless PNG routinely exceed the
            // 5 MB cloud-backend limit. Cloud vision models (OpenAI 4o/4.1,
            // etc.) fit images to 2048² before tiling, so downscaling here
            // is lossless w.r.t. the model and JPEG keeps payload small.
            let cgImage = ScreenshotCapture.downscaledForVision(captured)
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let jpegProps: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: 0.85]
            let encoded: (data: Data, mediaType: String)
            if let jpeg = bitmap.representation(using: .jpeg, properties: jpegProps) {
                encoded = (jpeg, "image/jpeg")
            } else if let png = bitmap.representation(using: .png, properties: [:]) {
                encoded = (png, "image/png")
            } else {
                throw ScreenshotTranslationError.captureFailedDetail("Could not encode the active screen.")
            }

            return (
                image: ImageInput(data: encoded.data, mediaType: encoded.mediaType),
                pixelSize: CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
            )
        }.value

        return AskNugumiScreenCapture(
            image: imagePayload.image,
            imagePixelSize: imagePayload.pixelSize,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )
    }

    // Matches the tile boundary cloud vision models snap to; sending larger
    // is bandwidth waste plus risks tripping client-side size guards.
    private static let visionMaxEdge: CGFloat = 2048

    fileprivate static func downscaledForVision(_ image: CGImage) -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let longest = max(width, height)
        guard longest > visionMaxEdge else { return image }
        let scale = visionMaxEdge / longest
        let targetWidth = Int((width * scale).rounded())
        let targetHeight = Int((height * scale).rounded())
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? image
    }

    static func captureInteractiveArea() async throws -> URL {
        // Permission is requested once at launch (requestScreenRecordingPermissionIfNeeded),
        // which is what registers Nugumi in System Settings. Calling CGRequestScreenCaptureAccess
        // here would stack Apple's system prompt on top of our NugumiAlertController.
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenshotTranslationError.screenRecordingPermissionDenied
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let outputURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("nugumi-screenshot-\(UUID().uuidString)")
                    .appendingPathExtension("png")

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-i", "-x", outputURL.path]
                let stderrPipe = Pipe()
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let stderrText = String(data: stderrData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let fileExists = FileManager.default.fileExists(atPath: outputURL.path)

                    if !fileExists {
                        // If `screencapture` produced no file and the system
                        // says the app isn't trusted for screen capture, the
                        // failure is almost certainly a permission denial —
                        // independent of how Apple phrased the stderr message.
                        let permissionDenied = !CGPreflightScreenCaptureAccess()
                            || stderrText.localizedCaseInsensitiveContains("could not create image")
                        if stderrText.isEmpty && !permissionDenied {
                            continuation.resume(throwing: ScreenshotTranslationError.captureCancelled)
                        } else if permissionDenied {
                            continuation.resume(throwing: ScreenshotTranslationError.screenRecordingPermissionDenied)
                        } else {
                            continuation.resume(throwing: ScreenshotTranslationError.captureFailedDetail(stderrText))
                        }
                        return
                    }

                    if process.terminationStatus != 0 {
                        continuation.resume(throwing: ScreenshotTranslationError.captureFailed(process.terminationStatus))
                        return
                    }

                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
                          let fileSize = attributes[.size] as? NSNumber,
                          fileSize.intValue > 0
                    else {
                        continuation.resume(throwing: ScreenshotTranslationError.captureCancelled)
                        return
                    }

                    continuation.resume(returning: outputURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

}

enum ImageTextRecognizer {
    private struct RecognizedLine {
        let text: String
        let boundingBox: CGRect
    }

    static func recognizeText(in imageURL: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    request.automaticallyDetectsLanguage = true

                    let supportedLanguages = (try? request.supportedRecognitionLanguages()) ?? []
                    if !supportedLanguages.isEmpty {
                        request.recognitionLanguages = supportedLanguages
                    }

                    let handler = VNImageRequestHandler(url: imageURL, options: [:])
                    try handler.perform([request])

                    let lines = (request.results ?? []).compactMap { observation -> RecognizedLine? in
                        guard let candidate = observation.topCandidates(1).first else {
                            return nil
                        }

                        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else {
                            return nil
                        }

                        return RecognizedLine(text: text, boundingBox: observation.boundingBox)
                    }

                    let rowTolerance: CGFloat = 0.025
                    let orderedLines = lines.sorted { lhs, rhs in
                        let lhsMidY = lhs.boundingBox.midY
                        let rhsMidY = rhs.boundingBox.midY

                        if abs(lhsMidY - rhsMidY) <= rowTolerance {
                            return lhs.boundingBox.minX < rhs.boundingBox.minX
                        }

                        return lhsMidY > rhsMidY
                    }

                    let recognizedText = Self.joinedTextPreservingParagraphs(
                        from: orderedLines,
                        rowTolerance: rowTolerance
                    )
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                    guard !recognizedText.isEmpty else {
                        continuation.resume(throwing: ScreenshotTranslationError.noTextRecognized)
                        return
                    }

                    continuation.resume(returning: recognizedText)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Joins OCR lines using their geometry. Same-row lines join with a space.
    /// Stacked lines use `\n` for ordinary line wraps and `\n\n` when the
    /// vertical gap between them is meaningfully larger than the median line
    /// height — that gap corresponds to a deliberate paragraph break in the
    /// source. Without this signal the downstream LLM cannot distinguish a
    /// word-wrap from a paragraph boundary and collapses everything into one
    /// block.
    private static func joinedTextPreservingParagraphs(
        from lines: [RecognizedLine],
        rowTolerance: CGFloat
    ) -> String {
        guard let first = lines.first else { return "" }
        guard lines.count > 1 else { return first.text }

        let heights = lines.map(\.boundingBox.height).sorted()
        let medianHeight = heights[heights.count / 2]
        let paragraphGapThreshold = max(medianHeight * 0.65, 0.005)

        var result = first.text
        for index in 1..<lines.count {
            let previous = lines[index - 1]
            let current = lines[index]
            let sameRow = abs(previous.boundingBox.midY - current.boundingBox.midY) <= rowTolerance
            if sameRow {
                result += " " + current.text
                continue
            }

            let gap = previous.boundingBox.minY - current.boundingBox.maxY
            let separator = gap > paragraphGapThreshold ? "\n\n" : "\n"
            result += separator + current.text
        }
        return result
    }
}

final class ScreenshotDragTracker {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var startLocation: NSPoint?
    private var lastLocation: NSPoint?
    private var currentPanelSide: TranslationPanelController.Side?
    private let onUpdate: @MainActor (NSPoint?, NSPoint?, TranslationPanelController.Side?) -> Void

    init(onUpdate: @escaping @MainActor (NSPoint?, NSPoint?, TranslationPanelController.Side?) -> Void) {
        self.onUpdate = onUpdate
    }

    func enable() {
        guard eventTap == nil else { return }

        let mask =
            CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }

                let tracker = Unmanaged<ScreenshotDragTracker>.fromOpaque(userInfo).takeUnretainedValue()
                tracker.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPointer
        ) else {
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func disable() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        startLocation = nil
        lastLocation = nil
        currentPanelSide = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let location = event.location
        switch type {
        case .leftMouseDown:
            startLocation = location
            lastLocation = location
            currentPanelSide = nil
            notify(startLocation: location, endLocation: nil, panelSide: nil)
        case .leftMouseDragged, .leftMouseUp:
            let referenceLocation = startLocation ?? lastLocation
            if let panelSide = Self.meaningfulPanelSideForDrag(from: referenceLocation, to: location) {
                currentPanelSide = panelSide
            }
            notify(startLocation: startLocation, endLocation: location, panelSide: currentPanelSide)
            lastLocation = location
            if type == .leftMouseUp {
                startLocation = nil
                lastLocation = nil
            }
        default:
            break
        }
    }

    private func notify(
        startLocation: NSPoint?,
        endLocation: NSPoint?,
        panelSide: TranslationPanelController.Side?
    ) {
        Task { @MainActor in
            onUpdate(startLocation, endLocation, panelSide)
        }
    }

    private static func meaningfulPanelSideForDrag(
        from startLocation: NSPoint?,
        to endLocation: NSPoint
    ) -> TranslationPanelController.Side? {
        guard let startLocation else { return nil }

        let dx = endLocation.x - startLocation.x
        let dy = endLocation.y - startLocation.y
        guard abs(dx) >= 5, abs(dx) > abs(dy) else { return nil }
        return dx > 0 ? .right : .left
    }

    deinit {
        disable()
    }
}

