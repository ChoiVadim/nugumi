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
