import AppKit
import AVFoundation
import Foundation

/// Maps Nugumi's target-language setting to the ISO code the Realtime
/// translation API expects in `session.audio.output.language`.
enum LiveTranslationLanguage {
    static func apiCode(for language: TranslationLanguage) -> String {
        switch language.id {
        case "zh-Hans": return "zh"
        default: return language.id
        }
    }
}

enum CaptionSpeaker: Equatable {
    case them   // system audio
    case me     // microphone

    var label: String {
        switch self {
        case .them: return "Them"
        case .me: return "Me"
        }
    }
}

struct CaptionLine: Equatable {
    let speaker: CaptionSpeaker
    var text: String
    var isFinalized: Bool
}

/// Ordered caption lines. Output deltas append to the current open line; a
/// speaker change or an explicit finalize closes it and opens a new one.
struct LiveTranscript {
    private(set) var lines: [CaptionLine] = []

    mutating func appendDelta(speaker: CaptionSpeaker, text: String) {
        if let last = lines.last, !last.isFinalized, last.speaker == speaker {
            lines[lines.count - 1].text += text
        } else {
            if !lines.isEmpty, lines[lines.count - 1].isFinalized == false {
                lines[lines.count - 1].isFinalized = true
            }
            lines.append(CaptionLine(speaker: speaker, text: text, isFinalized: false))
        }
    }

    mutating func finalizeCurrent() {
        guard let last = lines.last, !last.isFinalized else { return }
        lines[lines.count - 1].isFinalized = true
    }
}

/// Typed view over the Realtime translation socket's server events. Unknown or
/// malformed payloads decode to `.ignored` so a protocol drift can never crash
/// the receive loop.
enum RealtimeServerEvent: Equatable {
    case translatedDelta(String)
    case sourceDelta(String)
    case closed
    case error(String)
    case ignored

    init(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String else {
            self = .ignored
            return
        }
        switch type {
        case "session.output_transcript.delta":
            self = (root["delta"] as? String).map(RealtimeServerEvent.translatedDelta) ?? .ignored
        case "session.input_transcript.delta":
            self = (root["delta"] as? String).map(RealtimeServerEvent.sourceDelta) ?? .ignored
        case "session.closed":
            self = .closed
        case "error":
            let message = (root["error"] as? [String: Any])?["message"] as? String
            self = .error(message ?? "Realtime session error")
        default:
            self = .ignored
        }
    }
}
