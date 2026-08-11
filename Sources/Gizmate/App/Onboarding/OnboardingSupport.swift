import Foundation

// MARK: - Permission model

enum PermissionKind {
    case accessibility
    case screenRecording
    case fullDiskAccess

    var analyticsValue: String {
        switch self {
        case .accessibility: return "accessibility"
        case .screenRecording: return "screen_recording"
        case .fullDiskAccess: return "full_disk_access"
        }
    }
}

// MARK: - Full Disk Access probe

/// No macOS API reports Full Disk Access status directly. Probe by attempting
/// to list the KakaoTalk container (what the chat-summary feature actually
/// needs to read): success ⇒ granted, failure ⇒ missing.
enum FullDiskAccessProbe {
    static func isGranted() async -> Bool {
        await Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let container = "\(home)/Library/Containers/com.kakao.KakaoTalkMac/Data/Library/Application Support/com.kakao.KakaoTalkMac"
            // If KakaoTalk isn't installed, fall back to a generic TCC-gated path.
            let probe = FileManager.default.fileExists(atPath: container)
                ? container
                : "\(home)/Library/Application Support/com.apple.TCC"
            return (try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil
        }.value
    }
}

// MARK: - Feature tour data

struct FeatureTourStep {
    let title: String
    let body: String
    /// Dead-simple "how to use" as a 1·2·3 list — plain language, no jargon.
    let steps: [String]
    let videoURL: URL

    static var all: [FeatureTourStep] {
        let askShortcut = GlobalShortcutStore.shortcut(for: .askGizmate)

        return [
            FeatureTourStep(
                title: "Ask Gizmate anything",
                body: "Confused by something on your screen? Ask Gizmate - it looks and answers.",
                steps: askSteps(for: askShortcut),
                videoURL: videoURL(named: "ask", remote: "https://df41nzkzrv2ws.cloudfront.net/nugumi/demo.mp4")
            ),
            FeatureTourStep(
                title: "Understand anything you read",
                body: "Stuck on a word or a sentence? Gizmate explains it in simple words - and you can keep asking.",
                steps: [
                    "Select the text you don't get.",
                    "Click the Gizmate that pops up and pick Explain.",
                    "Read the answer. Ask more if you want.",
                ],
                videoURL: videoURL(named: "understand", remote: "https://df41nzkzrv2ws.cloudfront.net/nugumi/translate.mp4")
            ),
            FeatureTourStep(
                title: "Write it rough, send it clean",
                body: "Write however it comes out. Gizmate makes it clean and natural - in a style you pick for each app.",
                steps: [
                    "Write your message.",
                    "Select it.",
                    "Click the Gizmate that pops up and pick Rewrite.",
                ],
                videoURL: videoURL(named: "fix", remote: "https://df41nzkzrv2ws.cloudfront.net/nugumi/make-native.mp4")
            ),
            FeatureTourStep(
                title: "Replies that know the answer",
                body: "Gizmate reads the message you got and writes the reply for you.",
                steps: [
                    "Select the message you got.",
                    "Click the Gizmate that pops up.",
                    "Pick Reply.",
                ],
                videoURL: videoURL(named: "reply", remote: "https://df41nzkzrv2ws.cloudfront.net/nugumi/reply.mp4")
            )
        ]
    }

    /// Bundled clip first (works offline); CloudFront only as a safety net if
    /// the resource is somehow missing from the bundle.
    private static func videoURL(named name: String, remote: String) -> URL {
        if let url = GizmateResources.bundle.url(forResource: name, withExtension: "MOV", subdirectory: "Onboarding")
            ?? GizmateResources.bundle.url(forResource: name, withExtension: "MOV") {
            return url
        }
        return URL(string: remote)!
    }

    /// Ask's first step depends on the user's configured shortcut.
    private static func askSteps(for shortcut: GlobalShortcut) -> [String] {
        let trigger: String
        switch shortcut.kind {
        case .doubleTap:
            let glyph = shortcut.displayString
            let single = String(glyph.prefix(glyph.count / 2))
            trigger = "Press \(modifierName(forGlyph: single)) twice."
        case .combo:
            trigger = "Press \(shortcut.displayString)."
        case .mouseButton:
            trigger = "Click \(shortcut.displayString) on your mouse."
        }
        return [trigger, "Type your question.", "Press Return."]
    }

    private static func modifierName(forGlyph glyph: String) -> String {
        switch glyph {
        case "⌃": return "Control"
        case "⌥": return "Option"
        case "⇧": return "Shift"
        case "⌘": return "Command"
        default: return glyph
        }
    }
}

// MARK: - Intro video

/// First-run intro clip. Optional so a missing resource simply skips the page.
enum OnboardingIntroVideo {
    static let url: URL? = GizmateResources.bundle.url(forResource: "intro", withExtension: "mov", subdirectory: "Onboarding")
        ?? GizmateResources.bundle.url(forResource: "intro", withExtension: "mov")
}
