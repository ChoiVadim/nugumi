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

enum TextNormalizer {
    static func cleanedSelection(_ text: String) -> String {
        var cleaned = normalizedBaseText(text)

        cleaned = cleaned.replacingOccurrences(
            of: #"(?<=\p{L})-\n(?=\p{L})"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?<=[.!?。！？])\s*(?=[▶•●▪▸])"#,
            with: "\n",
            options: .regularExpression
        )
        return cleanedStructuredSource(cleaned)
    }

    static func cleanedTranslation(_ text: String) -> String {
        var cleaned = normalizedBaseText(text)

        // Rule #1: the em dash (—) is banned everywhere, unconditionally — every
        // style, every mode, every backend, gen-z on or off. This is the single
        // chokepoint all output flows through, so stripping here covers all paths.
        cleaned = removingEmDashes(cleaned)

        cleaned = cleaned.replacingOccurrences(
            of: #"[ \t]+\n"#,
            with: "\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\n[ \t]+"#,
            with: "\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s+([,.;:!?…])"#,
            with: "$1",
            options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func looksMeaningful(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var letterCount = 0
        var hasIdeographOrKana = false
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                letterCount += 1
            }
            switch scalar.value {
            case 0x3040...0x30FF,     // Hiragana + Katakana
                 0x3400...0x4DBF,     // CJK Unified Ideographs Extension A
                 0x4E00...0x9FFF,     // CJK Unified Ideographs
                 0xAC00...0xD7AF,     // Hangul Syllables
                 0xF900...0xFAFF:     // CJK Compatibility Ideographs
                hasIdeographOrKana = true
            default:
                break
            }
        }

        if hasIdeographOrKana { return true }
        return letterCount >= 2
    }

    static func cleanedDraftMessage(_ text: String) -> String {
        var cleaned = normalizedBaseText(text)

        cleaned = cleaned.replacingOccurrences(
            of: #"[ \t]+\n"#,
            with: "\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\n[ \t]+"#,
            with: "\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\n{4,}"#,
            with: "\n\n\n",
            options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedBaseText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
    }

    /// Deterministic backstop for the universal em-dash ban (rule #1). Replaces
    /// the em dash (—) / horizontal bar (―), and a space-padded en dash (–) used
    /// as a clause separator, with a comma. An unspaced en dash inside a numeric
    /// range (2020–2021) is left untouched. Runs on every `cleanedTranslation`
    /// call, so it applies to all styles, modes, and backends without exception.
    private static func removingEmDashes(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: #"\s*[\x{2014}\x{2015}]\s*"#,
            with: ", ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\s\x{2013}\s"#,
            with: ", ",
            options: .regularExpression
        )
        // Heal artifacts: a comma the source already had adjacent to the dash,
        // and a dash that sat at the end of a line or the whole message.
        result = result.replacingOccurrences(
            of: #",\s*,"#,
            with: ",",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #",(\s*(?:\n|$))"#,
            with: "$1",
            options: .regularExpression
        )
        return result
    }

    private static func cleanedStructuredSource(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var resultLines: [String] = []
        var currentLine = ""

        func flushCurrentLine() {
            guard !currentLine.isEmpty else { return }
            resultLines.append(currentLine)
            currentLine = ""
        }

        for rawLine in lines {
            let line = cleanedInlineText(rawLine)
            if line.isEmpty {
                flushCurrentLine()
                if resultLines.last != "" {
                    resultLines.append("")
                }
                continue
            }

            if isStructuralLine(line) {
                flushCurrentLine()
                currentLine = line
                continue
            }

            if currentLine.isEmpty {
                currentLine = line
            } else {
                currentLine += joiningTextBetween(currentLine, and: line) + line
            }
        }

        flushCurrentLine()

        while resultLines.last == "" {
            resultLines.removeLast()
        }

        return resultLines
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanedInlineText(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        cleaned = cleaned.replacingOccurrences(
            of: #"\s+([,.;:!?…])"#,
            with: "$1",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"([(])\s+"#,
            with: "$1",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s+([)])"#,
            with: "$1",
            options: .regularExpression
        )
        return cleaned
    }

    private static func isStructuralLine(_ text: String) -> Bool {
        text.range(
            of: #"^\s*(?:[▶•●▪▸◆◇○◦\-–—*]|\d+[.)]|[A-Za-z][.)])\s*"#,
            options: .regularExpression
        ) != nil
    }

    private static func joiningTextBetween(_ left: String, and right: String) -> String {
        guard let last = left.unicodeScalars.last, let first = right.unicodeScalars.first else {
            return " "
        }

        let noSpaceBefore = CharacterSet(charactersIn: ",.;:!?…)]}）】」』")
        let noSpaceAfter = CharacterSet(charactersIn: "([{（【「『")
        if noSpaceBefore.contains(first) || noSpaceAfter.contains(last) {
            return ""
        }

        return " "
    }
}

struct CompositionSettings: Equatable {
    let style: WritingStyle
    let cleanup: CleanupLevel
    let snippets: [Snippet]
    /// The user's saved email voice sample — a representative email whose
    /// greeting, rhythm, and sign-off the model mirrors. Only populated for the
    /// `email` category; `nil`/empty elsewhere, so the prompt section vanishes.
    let voiceSample: String?

    /// The writing-style directive injected into compose prompts.
    func writingStyleDirective(for languageID: String) -> String {
        style.promptDescription(for: languageID)
    }
}

final class TranslationCache {
    private let maxEntries: Int
    private var entries: [String: String] = [:]
    private var keysByRecentUse: [String] = []

    init(maxEntries: Int = 200) {
        self.maxEntries = maxEntries
    }

    func translation(for text: String, targetLanguage: TranslationLanguage, thinkingLevel: ThinkingLevel) -> String? {
        let key = cacheKey(for: text, targetLanguage: targetLanguage, thinkingLevel: thinkingLevel)
        guard let translation = entries[key] else {
            return nil
        }

        markRecentlyUsed(key)
        return translation
    }

    func store(_ translation: String, for text: String, targetLanguage: TranslationLanguage, thinkingLevel: ThinkingLevel) {
        let key = cacheKey(for: text, targetLanguage: targetLanguage, thinkingLevel: thinkingLevel)
        guard !key.isEmpty, !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        entries[key] = translation
        markRecentlyUsed(key)
        trimIfNeeded()
    }

    private func cacheKey(for text: String, targetLanguage: TranslationLanguage, thinkingLevel: ThinkingLevel) -> String {
        "\(targetLanguage.id):\(thinkingLevel.rawValue):\(TextNormalizer.cleanedSelection(text))"
    }

    private func markRecentlyUsed(_ key: String) {
        keysByRecentUse.removeAll { $0 == key }
        keysByRecentUse.append(key)
    }

    private func trimIfNeeded() {
        while keysByRecentUse.count > maxEntries, let oldestKey = keysByRecentUse.first {
            keysByRecentUse.removeFirst()
            entries.removeValue(forKey: oldestKey)
        }
    }
}

