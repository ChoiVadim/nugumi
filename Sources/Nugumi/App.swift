import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreText
import Darwin
import Foundation
import Sparkle
import UserNotifications
import Vision

private enum MenuItemTag: Int {
    case permissionNotice = 100
    case accessibilitySettings = 101
    case permissionSeparator = 102
    case targetLanguage = 103
    case quit = 104
    case bootstrapNotice = 105
    case bootstrapAction = 106
    case bootstrapSeparator = 107
    case screenshotArea = 108
    case translateSelection = 109
    case draftTargetLanguage = 110
    case floatingDefaultMode = 111
    case thinkingLevel = 112
    case selectedModel = 113
    case checkForUpdates = 114
    case selectionDisplayMode = 115
    case usageStatsSummary = 116
    case writingStyle = 117
    case cleanupLevel = 118
    case snippets = 119
    case replacementMode = 120
    case keyboardShortcuts = 121
    case translateOrReplySelection = 122
    case resetSettings = 123
    case invisibilityMode = 124
    case contactSupport = 125
    case permissionsOnboarding = 126
}

enum InvisibilityState {
    static let defaultsKey = "invisibilityModeEnabled"
    static let firstRunShownKey = "invisibilityModeFirstRunShown"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static var currentSharingType: NSWindow.SharingType {
        isEnabled ? .none : .readOnly
    }

    static func apply(to window: NSWindow) {
        window.sharingType = currentSharingType
    }

    @MainActor
    static func applyToAllOpenWindows() {
        let type = currentSharingType
        for window in NSApp.windows {
            window.sharingType = type
        }
    }
}

enum BackendKind: Equatable {
    case ollama(requiresAccount: Bool)
    case cloud(CloudProvider)
}

struct LLMModel: Equatable {
    let id: String
    let shortName: String
    let displayName: String
    let backend: BackendKind
    let supportsImages: Bool

    var isCloud: Bool {
        if case .ollama(let requiresAccount) = backend { return requiresAccount }
        return false
    }

    var isOllama: Bool {
        if case .ollama = backend { return true }
        return false
    }

    var cloudProvider: CloudProvider? {
        if case .cloud(let provider) = backend { return provider }
        return nil
    }

    static let all: [LLMModel] = [
        // Ollama
        .init(id: "gpt-oss:120b-cloud", shortName: "Online",  displayName: "Online (Ollama Cloud, needs sign-in)", backend: .ollama(requiresAccount: true),  supportsImages: false),
        .init(id: "gpt-oss:20b",        shortName: "Offline", displayName: "Offline (Ollama local)",                backend: .ollama(requiresAccount: false), supportsImages: false),
        // OpenAI (GPT-5 family, all vision-capable)
        .init(id: "gpt-5.4-mini", shortName: "GPT-5.4 mini", displayName: "GPT-5.4 mini (OpenAI, fast)",  backend: .cloud(.openAI), supportsImages: true),
        .init(id: "gpt-5.4",      shortName: "GPT-5.4",      displayName: "GPT-5.4 (OpenAI, affordable)", backend: .cloud(.openAI), supportsImages: true),
        .init(id: "gpt-5.5",      shortName: "GPT-5.5",      displayName: "GPT-5.5 (OpenAI, flagship)",   backend: .cloud(.openAI), supportsImages: true),
        // Anthropic
        .init(id: "claude-haiku-4-5-20251001", shortName: "Claude Haiku 4.5",  displayName: "Claude Haiku 4.5 (Anthropic, fast)",  backend: .cloud(.anthropic), supportsImages: true),
        .init(id: "claude-sonnet-4-6",         shortName: "Claude Sonnet 4.6", displayName: "Claude Sonnet 4.6 (Anthropic)",       backend: .cloud(.anthropic), supportsImages: true),
        .init(id: "claude-opus-4-7",           shortName: "Claude Opus 4.7",   displayName: "Claude Opus 4.7 (Anthropic, top)",    backend: .cloud(.anthropic), supportsImages: true),
        // Gemini
        .init(id: "gemini-2.5-flash-lite", shortName: "Gemini 2.5 Flash Lite", displayName: "Gemini 2.5 Flash Lite (Google, fastest)", backend: .cloud(.gemini), supportsImages: true),
        .init(id: "gemini-2.5-flash",      shortName: "Gemini 2.5 Flash",      displayName: "Gemini 2.5 Flash (Google)",               backend: .cloud(.gemini), supportsImages: true),
        .init(id: "gemini-2.5-pro",        shortName: "Gemini 2.5 Pro",        displayName: "Gemini 2.5 Pro (Google, top)",            backend: .cloud(.gemini), supportsImages: true),
    ]

    static let ollamaModels = all.filter(\.isOllama)
    static let apiKeyModels = all.filter { $0.cloudProvider != nil }
    static let apiKeyMenuTitle = "API key models"

    static let defaultModel = all[0]

    static func option(id: String) -> LLMModel {
        all.first { $0.id == id } ?? defaultModel
    }

    static var modeMenuEntries: [LLMModelMenuEntry] {
        ollamaModels.map(LLMModelMenuEntry.model)
            + [.apiKeyModels(title: apiKeyMenuTitle, models: apiKeyModels)]
    }
}

enum LLMModelMenuEntry: Equatable {
    case model(LLMModel)
    case apiKeyModels(title: String, models: [LLMModel])
}

enum ModelUseScope: String, CaseIterable {
    case textActions
    case askNugumi

    var defaultsKey: String {
        switch self {
        case .textActions:
            return "textModelID"
        case .askNugumi:
            return "askNugumiModelID"
        }
    }

    func defaultModelID(legacySelectedModelID: String?) -> String {
        switch self {
        case .textActions:
            if let legacySelectedModelID,
               LLMModel.all.contains(where: { $0.id == legacySelectedModelID }) {
                return legacySelectedModelID
            }
            return LLMModel.defaultModel.id
        case .askNugumi:
            if let flagship = LLMModel.all.first(where: { $0.id == "gpt-5.5" && $0.supportsImages }) {
                return flagship.id
            }
            return LLMModel.all.first(where: \.supportsImages)?.id ?? LLMModel.defaultModel.id
        }
    }

    func menuTitle(for model: LLMModel) -> String {
        switch self {
        case .textActions:
            return "Everyday text: \(model.shortName)"
        case .askNugumi:
            return "Ask Nugumi: \(model.shortName)"
        }
    }

    func availableModels(from models: [LLMModel] = LLMModel.all) -> [LLMModel] {
        switch self {
        case .textActions:
            return models
        case .askNugumi:
            return models.filter(\.supportsImages)
        }
    }
}

private final class ModelMenuSelection: NSObject {
    let scope: ModelUseScope
    let modelID: String

    init(scope: ModelUseScope, modelID: String) {
        self.scope = scope
        self.modelID = modelID
    }
}

typealias OllamaModelOption = LLMModel

enum ThinkingLevel: String, CaseIterable {
    case low
    case medium
    case high

    var menuTitle: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var settingsTitle: String {
        "Thinking: \(rawValue)"
    }
}

extension ModelUseScope {
    var thinkingDefaultsKey: String {
        switch self {
        case .textActions:
            return "textThinkingLevel"
        case .askNugumi:
            return "askNugumiThinkingLevel"
        }
    }

    func defaultThinkingLevel(legacyThinkingRawValue: String?) -> ThinkingLevel {
        switch self {
        case .textActions:
            return legacyThinkingRawValue
                .flatMap(ThinkingLevel.init(rawValue:))
                ?? .low
        case .askNugumi:
            return .high
        }
    }

    func thinkingMenuTitle(for level: ThinkingLevel) -> String {
        switch self {
        case .textActions:
            return "Everyday text: \(level.menuTitle)"
        case .askNugumi:
            return "Ask Nugumi: \(level.menuTitle)"
        }
    }
}

private final class ThinkingMenuSelection: NSObject {
    let scope: ModelUseScope
    let level: ThinkingLevel

    init(scope: ModelUseScope, level: ThinkingLevel) {
        self.scope = scope
        self.level = level
    }
}

private enum FloatingButtonDefaultMode: String {
    case translate
    case smartReply

    static func storedMode(rawValue: String?) -> FloatingButtonDefaultMode {
        guard let rawValue else { return .translate }
        if rawValue == "selection" {
            return .translate
        }
        return FloatingButtonDefaultMode(rawValue: rawValue) ?? .translate
    }

    var translationMode: TranslationMode {
        switch self {
        case .translate: return .selection
        case .smartReply: return .smartReply
        }
    }

    var menuTitle: String {
        switch self {
        case .translate: return "Main mode: translate"
        case .smartReply: return "Main mode: reply"
        }
    }
}

private enum SelectionDisplayMode: String, CaseIterable {
    case floatingBar
    case pet
    case off

    var menuTitle: String {
        switch self {
        case .floatingBar: return "Floating bar"
        case .pet: return "Pet mode"
        case .off: return "Off"
        }
    }

    var settingsTitle: String {
        switch self {
        case .floatingBar: return "Display: floating bar"
        case .pet: return "Display: pet mode"
        case .off: return "Display: off"
        }
    }
}

private enum ReplacementMode: String, CaseIterable {
    case instantInsert
    case showPanel

    var menuTitle: String {
        switch self {
        case .instantInsert: return "Insert without preview"
        case .showPanel: return "Show preview panel"
        }
    }

    var settingsTitle: String {
        switch self {
        case .instantInsert: return "Replace action: insert without preview"
        case .showPanel: return "Replace action: show preview panel"
        }
    }
}

private struct GlobalHotKeyDefinition {
    static let signature = OSType(0x54524E53) // TRNS

    let id: UInt32
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let modifierFlags: NSEvent.ModifierFlags
    let displayString: String

    init(action: GlobalShortcutAction, shortcut: GlobalShortcut) {
        id = action.id
        keyCode = shortcut.keyCode
        carbonModifiers = shortcut.carbonModifiers
        modifierFlags = shortcut.modifiers
        displayString = shortcut.displayString
    }
}

private final class GlobalHotKey {
    private let definition: GlobalHotKeyDefinition

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var fallbackMonitor: Any?
    private let onPressed: @MainActor () -> Void

    init(definition: GlobalHotKeyDefinition, onPressed: @escaping @MainActor () -> Void) {
        self.definition = definition
        self.onPressed = onPressed
    }

    func register() {
        unregister()

        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef, let userData else {
                    return OSStatus(eventNotHandledErr)
                }

                var hotKeyID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                let registrar = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                guard parameterStatus == noErr,
                      hotKeyID.signature == GlobalHotKeyDefinition.signature,
                      hotKeyID.id == registrar.definition.id
                else {
                    return OSStatus(eventNotHandledErr)
                }

                Task { @MainActor in
                    registrar.onPressed()
                }
                return noErr
            },
            1,
            &eventSpec,
            selfPointer,
            &eventHandlerRef
        )

        guard handlerStatus == noErr else {
            installFallbackMonitor()
            return
        }

        let hotKeyID = EventHotKeyID(
            signature: GlobalHotKeyDefinition.signature,
            id: definition.id
        )
        let hotKeyStatus = RegisterEventHotKey(
            definition.keyCode,
            definition.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard hotKeyStatus == noErr else {
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
                self.eventHandlerRef = nil
            }
            installFallbackMonitor()
            return
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }

        if let fallbackMonitor {
            NSEvent.removeMonitor(fallbackMonitor)
            self.fallbackMonitor = nil
        }
    }

    private func installFallbackMonitor() {
        fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard self.matches(event) else {
                return
            }

            Task { @MainActor in
                self.onPressed()
            }
        }
    }

    private func matches(_ event: NSEvent) -> Bool {
        guard event.keyCode == UInt16(definition.keyCode) else {
            return false
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers.intersection(GlobalShortcut.supportedModifiers) == definition.modifierFlags
    }
}

struct TranslationLanguage: Equatable {
    let id: String
    let displayName: String
    let promptName: String

    static let all: [TranslationLanguage] = [
        .init(id: "ru", displayName: "Russian", promptName: "Russian"),
        .init(id: "en", displayName: "English (US)", promptName: "English"),
        .init(id: "ko", displayName: "Korean", promptName: "Korean"),
        .init(id: "ja", displayName: "Japanese", promptName: "Japanese"),
        .init(id: "zh-Hans", displayName: "Chinese Simplified", promptName: "Simplified Chinese"),
        .init(id: "es", displayName: "Spanish", promptName: "Spanish"),
        .init(id: "fr", displayName: "French", promptName: "French"),
        .init(id: "de", displayName: "German", promptName: "German")
    ]

    static let defaultLanguage = all.first { $0.id == "en" } ?? all[0]
    static let defaultDraftLanguage = all.first { $0.id == "ko" } ?? defaultLanguage

    static func language(id: String) -> TranslationLanguage {
        all.first { $0.id == id } ?? defaultLanguage
    }
}

private enum TextNormalizer {
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
}

@MainActor
private final class TranslationPrefetch {
    private enum State {
        case pending
        case running
        case completed(String)
        case failed(Error)
        case cancelled
    }

    let text: String
    let images: [ImageInput]
    let targetLanguage: TranslationLanguage
    let thinkingLevel: ThinkingLevel
    let appCategory: AppCategory
    private let backend: any LLMBackend
    private var task: Task<Void, Never>?
    private var state: State = .pending
    private var partialTranslation = ""
    private var subscribers: [(String) -> Void] = []
    private var completionSubscribers: [(String) -> Void] = []
    private var failureSubscribers: [(Error) -> Void] = []
    private let onComplete: (String, TranslationLanguage, ThinkingLevel, String) -> Void

    init(
        text: String,
        images: [ImageInput] = [],
        targetLanguage: TranslationLanguage,
        thinkingLevel: ThinkingLevel,
        appCategory: AppCategory,
        backend: any LLMBackend,
        onComplete: @escaping (String, TranslationLanguage, ThinkingLevel, String) -> Void
    ) {
        self.text = text
        self.images = images
        self.targetLanguage = targetLanguage
        self.thinkingLevel = thinkingLevel
        self.appCategory = appCategory
        self.backend = backend
        self.onComplete = onComplete
    }

    func startAfterDelay(milliseconds: UInt64) {
        guard task == nil else { return }

        task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
                try Task.checkCancellation()
                await self?.start()
            } catch {
                self?.markCancelled()
            }
        }
    }

    func subscribe(
        onPartial: @escaping (String) -> Void,
        onCompletion: @escaping (String) -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        if !partialTranslation.isEmpty {
            onPartial(partialTranslation)
        }

        switch state {
        case .completed(let translation):
            onPartial(translation)
            onCompletion(translation)
        case .failed(let error):
            onFailure(error)
        default:
            subscribers.append(onPartial)
            completionSubscribers.append(onCompletion)
            failureSubscribers.append(onFailure)
        }
    }

    func ensureStartedNow() {
        switch state {
        case .pending:
            task?.cancel()
            task = Task { [weak self] in
                await self?.start()
            }
        default:
            break
        }
    }

    func cancel() {
        task?.cancel()
        state = .cancelled
        subscribers.removeAll()
        completionSubscribers.removeAll()
        failureSubscribers.removeAll()
    }

    private func start() async {
        guard case .pending = state else { return }
        state = .running

        do {
            let finalTranslation = try await backend.translate(
                text,
                images: images,
                to: targetLanguage,
                mode: .selection,
                appCategory: appCategory,
                composition: nil,
                thinkingLevel: thinkingLevel
            ) { [weak self] partial in
                Task { @MainActor in
                    self?.publishPartial(partial)
                }
            }
            state = .completed(finalTranslation)
            onComplete(text, targetLanguage, thinkingLevel, finalTranslation)
            publishPartial(finalTranslation)
            completionSubscribers.forEach { $0(finalTranslation) }
            subscribers.removeAll()
            completionSubscribers.removeAll()
            failureSubscribers.removeAll()
        } catch is CancellationError {
            markCancelled()
        } catch {
            state = .failed(error)
            failureSubscribers.forEach { $0(error) }
            subscribers.removeAll()
            completionSubscribers.removeAll()
            failureSubscribers.removeAll()
        }
    }

    private func publishPartial(_ partial: String) {
        partialTranslation = partial
        subscribers.forEach { $0(partial) }
    }

    private func markCancelled() {
        state = .cancelled
        subscribers.removeAll()
        completionSubscribers.removeAll()
        failureSubscribers.removeAll()
    }
}

private final class TranslationCache {
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

@main
@MainActor
final class NugumiApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var mouseMonitor: Any?
    private var lastLeftMouseDownLocation: NSPoint?
    private let selectionReader = SelectionReader()
    private let ollamaBaseURL = URL(string: "http://127.0.0.1:11434")!
    private var currentBackend: any LLMBackend {
        backend(for: textModelID)
    }
    private var askBackend: any LLMBackend {
        backend(for: askNugumiModelID)
    }

    private func backend(for modelID: String) -> any LLMBackend {
        let model = LLMModel.option(id: modelID)
        switch model.backend {
        case .ollama:
            return OllamaClient(baseURL: ollamaBaseURL, model: model.id)
        case .cloud(let provider):
            let key = KeychainStore.apiKey(for: provider) ?? ""
            return OpenAIChatClient(provider: provider, apiKey: key, model: model.id)
        }
    }

    private var translateButtonController: FloatingTranslateButtonController?
    private var floatingLoadingBar: FloatingTranslateButtonController?
    private var floatingTargetButton: FloatingTranslateButtonController?
    private var petController: PetController?
    private var translationPanelController: TranslationPanelController?
    private var askPromptController: AskPromptController?
    private var askNugumiTask: Task<Void, Never>?
    private var askNugumiRequestID: UUID?
    private var askHistory: [AskNugumiTurn] = []
    private var translationPrefetch: TranslationPrefetch?
    private var isScreenshotTranslationRunning = false
    private var isAskNugumiRunning = false
    private var screenshotDragStartLocation: NSPoint?
    private var screenshotDragEndLocation: NSPoint?
    private var screenshotPanelSide: TranslationPanelController.Side?
    private var screenshotDragTracker: ScreenshotDragTracker?
    private var globalHotKeys: [GlobalHotKey] = []
    private var doubleControlDetector: DoubleControlPressDetector?
    private var shortcutRecorderWindowController: ShortcutRecorderWindowController?
    private var lastReplacementSourcePID: pid_t?
    private var translationCache = TranslationCache()
    private let usageStatsStore = UsageStatsStore()
    private let analyticsClient = AnalyticsClient()
    private var shouldReopenStatusMenuAfterClose = false
    private let snippetsStore = SnippetsStore()
    private lazy var bootstrap: OllamaBootstrap = OllamaBootstrap(
        baseURL: ollamaBaseURL,
        models: LLMModel.ollamaModels
    )
    private var onboardingWindowController: OnboardingWindowController?
    private var snippetsWindowController: SnippetsWindowController?
    private var accessibilityTrustTimer: Timer?
    private var screenRecordingTrustTimer: Timer?

    private struct WindowSharingSnapshot {
        let window: NSWindow
        let sharingType: NSWindow.SharingType
    }
    private var permissionsWindowController: PermissionsWindowController?
    private var lastObservedModelReadyState: [String: BootstrapStepStatus] = [:]
    private lazy var updaterController: SPUStandardUpdaterController? = {
        guard isRunningFromAppBundle else { return nil }
        return SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }()
    private var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }
    private var targetLanguage: TranslationLanguage {
        get {
            TranslationLanguage.language(
                id: UserDefaults.standard.string(forKey: "targetLanguageID") ?? TranslationLanguage.defaultLanguage.id
            )
        }
        set {
            UserDefaults.standard.set(newValue.id, forKey: "targetLanguageID")
        }
    }
    private var draftTargetLanguage: TranslationLanguage {
        get {
            TranslationLanguage.language(
                id: UserDefaults.standard.string(forKey: "draftTargetLanguageID") ?? TranslationLanguage.defaultDraftLanguage.id
            )
        }
        set {
            UserDefaults.standard.set(newValue.id, forKey: "draftTargetLanguageID")
        }
    }
    private var floatingDefaultMode: FloatingButtonDefaultMode {
        get {
            FloatingButtonDefaultMode.storedMode(
                rawValue: UserDefaults.standard.string(forKey: "floatingButtonDefaultMode")
            )
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "floatingButtonDefaultMode")
        }
    }
    private var selectionDisplayMode: SelectionDisplayMode {
        get {
            let raw = UserDefaults.standard.string(forKey: "selectionDisplayMode") ?? SelectionDisplayMode.pet.rawValue
            return SelectionDisplayMode(rawValue: raw) ?? .pet
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "selectionDisplayMode")
        }
    }
    private var legacySelectedModelID: String? {
        UserDefaults.standard.string(forKey: "selectedOllamaModel")
    }
    private var textModelID: String {
        get {
            UserDefaults.standard.string(forKey: ModelUseScope.textActions.defaultsKey)
                ?? ModelUseScope.textActions.defaultModelID(legacySelectedModelID: legacySelectedModelID)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: ModelUseScope.textActions.defaultsKey)
        }
    }
    private var askNugumiModelID: String {
        get {
            UserDefaults.standard.string(forKey: ModelUseScope.askNugumi.defaultsKey)
                ?? ModelUseScope.askNugumi.defaultModelID(legacySelectedModelID: legacySelectedModelID)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: ModelUseScope.askNugumi.defaultsKey)
        }
    }
    private func modelID(for scope: ModelUseScope) -> String {
        switch scope {
        case .textActions:
            return textModelID
        case .askNugumi:
            return askNugumiModelID
        }
    }
    private func setModelID(_ modelID: String, for scope: ModelUseScope) {
        switch scope {
        case .textActions:
            textModelID = modelID
        case .askNugumi:
            askNugumiModelID = modelID
        }
    }
    private var legacyThinkingRawValue: String? {
        UserDefaults.standard.string(forKey: "thinkingLevel")
    }
    private var textThinkingLevel: ThinkingLevel {
        get {
            UserDefaults.standard.string(forKey: ModelUseScope.textActions.thinkingDefaultsKey)
                .flatMap(ThinkingLevel.init(rawValue:))
                ?? ModelUseScope.textActions.defaultThinkingLevel(legacyThinkingRawValue: legacyThinkingRawValue)
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: ModelUseScope.textActions.thinkingDefaultsKey)
        }
    }
    private var askNugumiThinkingLevel: ThinkingLevel {
        get {
            UserDefaults.standard.string(forKey: ModelUseScope.askNugumi.thinkingDefaultsKey)
                .flatMap(ThinkingLevel.init(rawValue:))
                ?? ModelUseScope.askNugumi.defaultThinkingLevel(legacyThinkingRawValue: legacyThinkingRawValue)
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: ModelUseScope.askNugumi.thinkingDefaultsKey)
        }
    }
    private func thinkingLevel(for scope: ModelUseScope) -> ThinkingLevel {
        switch scope {
        case .textActions:
            return textThinkingLevel
        case .askNugumi:
            return askNugumiThinkingLevel
        }
    }
    private func setThinkingLevel(_ level: ThinkingLevel, for scope: ModelUseScope) {
        switch scope {
        case .textActions:
            textThinkingLevel = level
        case .askNugumi:
            askNugumiThinkingLevel = level
        }
    }
    private var cleanupLevel: CleanupLevel {
        get {
            let raw = UserDefaults.standard.string(forKey: "cleanupLevel") ?? CleanupLevel.light.rawValue
            return CleanupLevel(rawValue: raw) ?? .light
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "cleanupLevel")
        }
    }

    private var replacementMode: ReplacementMode {
        get {
            let raw = UserDefaults.standard.string(forKey: "replacementMode") ?? ReplacementMode.instantInsert.rawValue
            return ReplacementMode(rawValue: raw) ?? .instantInsert
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "replacementMode")
        }
    }

    private var invisibilityModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: InvisibilityState.defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: InvisibilityState.defaultsKey) }
    }

    private func writingStyle(for category: AppCategory) -> WritingStyle {
        let key = "writingStyle.\(category.rawValue)"
        if let raw = UserDefaults.standard.string(forKey: key),
           let style = WritingStyle(rawValue: raw) {
            return style
        }
        return Self.defaultStyle(for: category)
    }

    private func setWritingStyle(_ style: WritingStyle, for category: AppCategory) {
        UserDefaults.standard.set(style.rawValue, forKey: "writingStyle.\(category.rawValue)")
    }

    private static func defaultStyle(for category: AppCategory) -> WritingStyle {
        switch category {
        case .personalMessages, .other: return .casual
        case .workMessages: return .polite
        case .email: return .formal
        }
    }

    private let prefetchDelayMilliseconds: UInt64 = 220
    private let prefetchMaxCharacterCount = 1_200

    static func main() {
        let app = NSApplication.shared
        let delegate = NugumiApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // AX default messaging timeout is 6s. Parameterized calls (e.g.
        // kAXBoundsForRangeParameterizedAttribute) can stall the main thread
        // when an unsupported app responds slowly. Cap it.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.5)
        setupStatusItem()
        statusItem?.isVisible = !invisibilityModeEnabled
        InvisibilityState.applyToAllOpenWindows()
        requestAccessibilityPermissionIfNeeded()
        requestScreenRecordingPermissionIfNeeded()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            self?.presentPermissionsWindowIfNeeded()
        }
        startMouseMonitor()
        applySelectionDisplayMode()
        setupGlobalHotKeys()
        setupDoubleControlDetector()
        setupBootstrap()
        _ = updaterController
        analyticsClient.track(.appLaunched)
    }

    private func shortcut(for action: GlobalShortcutAction) -> GlobalShortcut {
        GlobalShortcutStore.shortcut(for: action)
    }

    private func setupGlobalHotKeys() {
        globalHotKeys.forEach { $0.unregister() }

        let screenshotHotKey = GlobalHotKey(
            definition: GlobalHotKeyDefinition(
                action: .screenshotArea,
                shortcut: shortcut(for: .screenshotArea)
            )
        ) { [weak self] in
            self?.startScreenshotTranslation()
        }
        let translateSelectionHotKey = GlobalHotKey(
            definition: GlobalHotKeyDefinition(
                action: .translateSelection,
                shortcut: shortcut(for: .translateSelection)
            )
        ) { [weak self] in
            self?.startSelectedTextTranslationForReplacement()
        }
        let translateOrReplyHotKey = GlobalHotKey(
            definition: GlobalHotKeyDefinition(
                action: .translateOrReply,
                shortcut: shortcut(for: .translateOrReply)
            )
        ) { [weak self] in
            self?.startSelectionTranslateOrReply()
        }
        let toggleInvisibilityHotKey = GlobalHotKey(
            definition: GlobalHotKeyDefinition(
                action: .toggleInvisibility,
                shortcut: shortcut(for: .toggleInvisibility)
            )
        ) { [weak self] in
            self?.toggleInvisibilityMode()
        }
        globalHotKeys = [
            screenshotHotKey,
            translateSelectionHotKey,
            translateOrReplyHotKey,
            toggleInvisibilityHotKey
        ]
        globalHotKeys.forEach { $0.register() }
    }

    private func setupDoubleControlDetector() {
        let detector = DoubleControlPressDetector { [weak self] in
            self?.startAskNugumiPrompt()
        }
        doubleControlDetector = detector
        detector.start()
    }

    @MainActor
    private func startAskNugumiPrompt() {
        // Double-Control toggles: if any Ask Nugumi UI (prompt, loading,
        // answer, or an in-flight request) is already up, dismiss it instead
        // of opening another one.
        let askUIOpen = isAskNugumiRunning
            || askPromptController?.isVisible == true
            || petController?.isPromptVisible == true
        if askUIOpen {
            dismissAskNugumi()
            return
        }

        translateButtonController?.close()
        translateButtonController = nil
        floatingTargetButton?.close()
        floatingTargetButton = nil
        translationPanelController?.close()
        translationPanelController = nil
        cancelPrefetch()

        if selectionDisplayMode == .pet {
            presentPetAskPrompt()
            return
        }

        let controller = AskPromptController(
            near: NSEvent.mouseLocation,
            onSubmit: { [weak self] prompt in
                self?.submitAskNugumiPrompt(prompt)
            },
            onClose: { [weak self] in
                guard let self else { return }
                self.askPromptController = nil
                if self.isAskNugumiRunning {
                    self.cancelAskNugumiRequest()
                }
            }
        )
        askPromptController = controller
        controller.show()
    }

    @MainActor
    private func submitAskNugumiPrompt(_ prompt: String) {
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty else { return }

        let model = LLMModel.option(id: askNugumiModelID)
        guard model.supportsImages else {
            askPromptController?.showError("Ask Nugumi needs a vision model.")
            petController?.showPromptError("Needs a vision model.")
            return
        }

        if let setupError = askNugumiSetupErrorIfNeeded(for: model) {
            let message = Self.translationPanelErrorMessage(for: setupError)
            askPromptController?.showError(message)
            petController?.showPromptError(message)
            return
        }

        let requestID = UUID()
        askNugumiTask?.cancel()
        askNugumiRequestID = requestID
        isAskNugumiRunning = true
        askPromptController?.setLoading()
        if petController?.isPromptVisible == true {
            petController?.setPromptLoading()
        }

        let cursorLocation = NSEvent.mouseLocation
        let backend = askBackend
        askNugumiTask = Task { [weak self] in
            do {
                let sharingSnapshot = await MainActor.run {
                    Self.hideAppWindowsFromScreenCapture()
                }
                let capture: AskNugumiScreenCapture
                do {
                    capture = try await ScreenshotCapture.captureActiveScreen(containing: cursorLocation)
                } catch {
                    await MainActor.run {
                        Self.restoreAppWindowSharing(sharingSnapshot)
                    }
                    throw error
                }
                await MainActor.run {
                    Self.restoreAppWindowSharing(sharingSnapshot)
                }
                try Task.checkCancellation()

                let shouldContinue = await MainActor.run { () -> Bool in
                    guard let self, self.askNugumiRequestID == requestID else {
                        return false
                    }
                    self.petController?.showThinking()
                    return true
                }
                guard shouldContinue else { return }

                let history = await MainActor.run { self?.askHistory ?? [] }
                let currentThinkingLevel = await MainActor.run { self?.askNugumiThinkingLevel ?? .high }
                let response = try await backend.ask(
                    history: history,
                    question: cleanPrompt,
                    image: capture.image,
                    thinkingLevel: currentThinkingLevel
                ) { _ in }
                try Task.checkCancellation()

                await MainActor.run {
                    self?.presentAskNugumiResult(
                        response,
                        capture: capture,
                        prompt: cleanPrompt,
                        requestID: requestID
                    )
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.clearAskNugumiRequestIfCurrent(requestID)
                }
            } catch {
                await MainActor.run {
                    self?.presentAskNugumiFailure(error, requestID: requestID)
                }
            }
        }
    }

    @MainActor
    private func presentAskNugumiResult(
        _ response: AskNugumiResponse,
        capture: AskNugumiScreenCapture,
        prompt: String,
        requestID: UUID
    ) {
        guard askNugumiRequestID == requestID else { return }
        clearAskNugumiRequestIfCurrent(requestID)
        analyticsClient.track(.askScreenCompleted, properties: [
            "model_id": askNugumiModelID
        ])
        recordAskTurn(question: prompt, answer: response.message)
        askPromptController?.close()
        askPromptController = nil

        translationPanelController?.close()
        translationPanelController = nil

        if selectionDisplayMode == .pet {
            presentPetAskNugumiResult(response, capture: capture)
            return
        }

        petController?.clearPrompt()
        let controller = TranslationPanelController(
            anchor: .point(NSEvent.mouseLocation, panelSide: .right),
            sourceText: prompt,
            targetLanguage: targetLanguage,
            resultLabel: "Answer",
            onClose: { [weak self] in
                self?.translationPanelController = nil
                self?.floatingTargetButton?.close()
                self?.floatingTargetButton = nil
                self?.petController?.clearReady()
            }
        )
        translationPanelController = controller
        let panelRequestID = controller.showLoading(targetLanguage: targetLanguage)
        controller.showTranslation(response.message, requestID: panelRequestID)

        if let target = response.petTarget {
            presentFloatingAskTargetPointer(for: target, capture: capture)
        } else {
            floatingTargetButton?.close()
            floatingTargetButton = nil
        }
    }

    @MainActor
    private func presentFloatingAskTargetPointer(
        for target: AskNugumiPetTarget,
        capture: AskNugumiScreenCapture
    ) {
        let point = AskNugumiCoordinateMapper.exactScreenPoint(
            for: target,
            screenFrame: capture.screenFrame
        )
        let button: FloatingTranslateButtonController
        if let existing = floatingTargetButton {
            button = existing
        } else {
            // Launch the pointer from the pet so it visibly travels from the
            // character to the target; fall back to the cursor if no pet.
            let launchPoint = petController?.petAnchorPoint ?? NSEvent.mouseLocation
            button = FloatingTranslateButtonController(
                screenPoint: launchPoint,
                selectedText: "",
                initialMode: .selection,
                onTranslate: { _ in },
                onRewrite: { _ in },
                onSmartReply: { _ in }
            )
            floatingTargetButton = button
        }
        button.pointAt(point, visibleFrame: capture.visibleFrame)
    }

    @MainActor
    private func presentPetAskNugumiResult(
        _ response: AskNugumiResponse,
        capture: AskNugumiScreenCapture
    ) {
        if petController == nil {
            petController = PetController(initialMode: .selection)
        }

        guard let petController else { return }

        if let target = response.petTarget {
            let presentation = AskNugumiPetAnswerTargetPresentationPolicy.presentation(
                for: target,
                screenFrame: capture.screenFrame
            )
            // The pet stays put; the pixel arrow travels to the target.
            petController.showAnswer(
                response.message,
                emotion: response.emotion,
                markerTarget: presentation.markerTarget
            )
        } else {
            petController.showAnswer(response.message, emotion: response.emotion)
        }
    }

    @MainActor
    private func presentAskNugumiFailure(_ error: Error, requestID: UUID) {
        guard askNugumiRequestID == requestID else { return }
        clearAskNugumiRequestIfCurrent(requestID)

        if let screenshotError = error as? ScreenshotTranslationError,
           case .screenRecordingPermissionDenied = screenshotError {
            analyticsClient.track(.errorOccurred, properties: [
                "error_type": "screen_recording_permission_denied",
                "error_context": "ask_screen"
            ])
            askPromptController?.close()
            askPromptController = nil
            petController?.clearPrompt()
            presentScreenshotTranslationError(screenshotError)
            return
        }

        let routed = handleTranslationFailure(error)
        if routed {
            askPromptController?.close()
            askPromptController = nil
            petController?.clearPrompt()
            return
        }
        analyticsClient.track(.errorOccurred, properties: [
            "error_type": Self.analyticsErrorType(error),
            "error_context": "ask_screen"
        ])
        askPromptController?.showError(error.localizedDescription)
        petController?.showPromptError(error.localizedDescription)
    }

    @MainActor
    private func cancelAskNugumiRequest() {
        askNugumiTask?.cancel()
        askNugumiTask = nil
        askNugumiRequestID = nil
        isAskNugumiRunning = false
        petController?.clearThinking()
        petController?.clearPrompt()
        floatingTargetButton?.close()
        floatingTargetButton = nil
    }

    /// Opens the pet prompt input wired to Ask Nugumi. Reused for the initial
    /// double-Control prompt and for the answer bubble's "continue" button —
    /// `askHistory` persists across the session so follow-ups keep context.
    @MainActor
    private func presentPetAskPrompt() {
        if petController == nil {
            petController = PetController(initialMode: .draftMessage)
        }
        petController?.onContinue = { [weak self] in
            self?.continueAskNugumiDialog()
        }
        petController?.showPrompt(
            onSubmit: { [weak self] prompt in
                self?.submitAskNugumiPrompt(prompt)
            },
            onClose: { [weak self] in
                guard let self else { return }
                if self.isAskNugumiRunning {
                    self.cancelAskNugumiRequest()
                }
            }
        )
    }

    /// "Continue dialog" affordance on the answer bubble: re-open the prompt
    /// for a follow-up question in the same conversation.
    @MainActor
    private func continueAskNugumiDialog() {
        guard !isAskNugumiRunning else { return }
        presentPetAskPrompt()
    }

    /// Tears down every Ask Nugumi surface (pet prompt/answer, standalone
    /// prompt window, in-flight request). Used by the double-Control toggle.
    @MainActor
    private func dismissAskNugumi() {
        if isAskNugumiRunning {
            cancelAskNugumiRequest()
        }
        askPromptController?.close()
        askPromptController = nil
        petController?.clearPrompt()
        floatingTargetButton?.close()
        floatingTargetButton = nil
    }

    @MainActor
    private func recordAskTurn(question: String, answer: String) {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty, !trimmedAnswer.isEmpty else { return }
        let turn = AskNugumiTurn(question: trimmedQuestion, answer: trimmedAnswer)
        askHistory = AskNugumiPromptBuilder.appending(turn, to: askHistory)
    }

    private static func hideAppWindowsFromScreenCapture() -> [WindowSharingSnapshot] {
        let snapshots = NSApp.windows.map { window in
            WindowSharingSnapshot(window: window, sharingType: window.sharingType)
        }
        NSApp.windows.forEach { window in
            window.sharingType = .none
        }
        return snapshots
    }

    private static func restoreAppWindowSharing(_ snapshots: [WindowSharingSnapshot]) {
        snapshots.forEach { snapshot in
            snapshot.window.sharingType = snapshot.sharingType
        }
    }

    @MainActor
    private func clearAskNugumiRequestIfCurrent(_ requestID: UUID) {
        guard askNugumiRequestID == requestID else { return }
        askNugumiTask = nil
        askNugumiRequestID = nil
        isAskNugumiRunning = false
        petController?.clearThinking()
    }

    @MainActor
    private func askNugumiSetupErrorIfNeeded(for model: LLMModel) -> TranslationError? {
        switch model.backend {
        case .ollama:
            return translationErrorIfBootstrapNeedsSetup(for: model.id)
        case .cloud(let provider):
            let apiKey = KeychainStore.apiKey(for: provider)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return apiKey?.isEmpty == false ? nil : .invalidAPIKey(provider)
        }
    }

    @objc private func toggleInvisibilityMode() {
        let now = !invisibilityModeEnabled
        invisibilityModeEnabled = now
        statusItem?.isVisible = !now
        InvisibilityState.applyToAllOpenWindows()
        updateMenuState()
        if now && !UserDefaults.standard.bool(forKey: InvisibilityState.firstRunShownKey) {
            showInvisibilityFirstRunDialog()
            UserDefaults.standard.set(true, forKey: InvisibilityState.firstRunShownKey)
        }
    }

    private func showInvisibilityFirstRunDialog() {
        let chord = shortcut(for: .toggleInvisibility).displayString
        NSApp.activate(ignoringOtherApps: true)
        _ = NugumiAlertController(
            title: "Invisibility mode is on",
            message: "Nugumi is now hidden from screenshots and screen sharing, and the menu-bar icon is gone. Press \(chord) anywhere to bring it back.",
            primaryButtonTitle: "Got it"
        ).showModal()
    }

    private func setupBootstrap() {
        wireBootstrap()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            if !self.bootstrap.isReady(for: self.textModelID) {
                self.presentOnboardingWindow()
            }
        }
    }

    private func wireBootstrap() {
        bootstrap.onChange = { [weak self] state in
            self?.handleBootstrapStateChange(state)
        }
        bootstrap.refresh()
    }

    @MainActor
    private func onModelSelectionChanged(for scope: ModelUseScope) {
        bootstrap.refresh()
        guard scope == .textActions else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            if !self.bootstrap.isReady(for: self.textModelID) {
                self.presentOnboardingWindow()
            }
        }
    }

    @MainActor
    private func handleBootstrapStateChange(_ state: BootstrapState) {
        let currentID = textModelID
        let previous = lastObservedModelReadyState[currentID] ?? .unknown
        let current = state.modelReady(for: currentID)
        lastObservedModelReadyState[currentID] = current
        if case .working = previous,
           case .ok = current,
           onboardingWindowController == nil {
            postTranslatorReadyNotification()
        }
        updateMenuState()
    }

    @MainActor
    private func postTranslatorReadyNotification() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                Self.deliverTranslatorReadyNotification()
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted {
                        Self.deliverTranslatorReadyNotification()
                    }
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated private static func deliverTranslatorReadyNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Nugumi is ready"
        content.body = "The translator finished downloading. Press your shortcut or select text to start."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "nugumi.translator.ready.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    @MainActor
    private func presentOnboardingWindow() {
        if let onboardingWindowController {
            onboardingWindowController.presentAndRefresh()
            return
        }
        let controller = OnboardingWindowController(
            bootstrap: bootstrap,
            onClose: { [weak self] in
                self?.onboardingWindowController = nil
            },
            onCloudPick: { [weak self] provider in
                guard let self else { return }
                if let firstModel = LLMModel.all.first(where: { $0.cloudProvider == provider }) {
                    self.applyModelSelection(firstModel.id, for: .textActions)
                }
            },
            onCloudTest: { [weak self] provider in
                await self?.runCloudTest(for: provider) ?? .failure("Internal error.")
            }
        )
        onboardingWindowController = controller
        controller.presentAndRefresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        petController?.close()
        doubleControlDetector?.stop()
        globalHotKeys.forEach { $0.unregister() }
        accessibilityTrustTimer?.invalidate()
        accessibilityTrustTimer = nil
        screenRecordingTrustTimer?.invalidate()
        screenRecordingTrustTimer = nil
    }

    private func setupStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.length = 24
        if let button = statusItem.button {
            button.title = ""
            button.image = makeStatusBarIcon(for: floatingDefaultMode)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.toolTip = "Nugumi"
        }

        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(makeMenuItem(
            title: "Accessibility permission required",
            tag: .permissionNotice,
            symbolName: "exclamationmark.triangle",
            isEnabled: false
        ))
        menu.addItem(makeMenuItem(
            title: "Open accessibility settings...",
            tag: .accessibilitySettings,
            symbolName: "gearshape",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        ))

        let permissionSeparator = NSMenuItem.separator()
        permissionSeparator.tag = MenuItemTag.permissionSeparator.rawValue
        menu.addItem(permissionSeparator)

        let usageSummaryItem = UsageStatsMenuItem(store: usageStatsStore) { [weak self] in
            self?.shouldReopenStatusMenuAfterClose = true
        }
        usageSummaryItem.tag = MenuItemTag.usageStatsSummary.rawValue
        menu.addItem(usageSummaryItem)

        menu.addItem(makeMenuItem(
            title: "Translator setup needed",
            tag: .bootstrapNotice,
            symbolName: "bolt.badge.clock",
            isEnabled: false
        ))
        menu.addItem(makeMenuItem(
            title: "Open setup...",
            tag: .bootstrapAction,
            symbolName: "wrench.and.screwdriver",
            action: #selector(openOnboardingWindow),
            keyEquivalent: ""
        ))

        let bootstrapSeparator = NSMenuItem.separator()
        bootstrapSeparator.tag = MenuItemTag.bootstrapSeparator.rawValue
        menu.addItem(bootstrapSeparator)

        menu.addItem(makeSectionHeader("Main settings"))
        menu.addItem(makeMenuItem(
            title: "",
            tag: .floatingDefaultMode,
            symbolName: "bolt.circle",
            submenu: makeFloatingDefaultModeMenu()
        ))
        menu.addItem(makeMenuItem(
            title: "",
            tag: .selectionDisplayMode,
            symbolName: "pawprint.fill",
            submenu: makeSelectionDisplayModeMenu()
        ))
        menu.addItem(makeMenuItem(
            title: "",
            tag: .replacementMode,
            symbolName: "return",
            submenu: makeReplacementModeMenu()
        ))
        menu.addItem(makeMenuItem(
            title: "Invisibility mode",
            tag: .invisibilityMode,
            symbolName: "eye.slash",
            action: #selector(toggleInvisibilityMode),
            keyEquivalent: shortcut(for: .toggleInvisibility).menuKeyEquivalent,
            keyEquivalentModifierMask: shortcut(for: .toggleInvisibility).keyEquivalentModifierMask
        ))
        menu.addItem(makeMenuItem(
            title: "How to use Nugumi...",
            tag: .permissionsOnboarding,
            symbolName: "questionmark.circle",
            action: #selector(openPermissionsOnboardingWindow),
            keyEquivalent: ""
        ))

        menu.addItem(makeSectionHeader("Shortcuts"))
        menu.addItem(makeMenuItem(
            title: "Translate selected text...",
            tag: .translateOrReplySelection,
            symbolName: "text.viewfinder",
            action: #selector(translateOrReplySelectionFromMenu),
            keyEquivalent: shortcut(for: .translateOrReply).menuKeyEquivalent,
            keyEquivalentModifierMask: shortcut(for: .translateOrReply).keyEquivalentModifierMask
        ))

        menu.addItem(makeMenuItem(
            title: "Rewrite my text...",
            tag: .translateSelection,
            symbolName: "text.insert",
            action: #selector(translateSelectedTextFromMenu),
            keyEquivalent: shortcut(for: .translateSelection).menuKeyEquivalent,
            keyEquivalentModifierMask: shortcut(for: .translateSelection).keyEquivalentModifierMask
        ))

        menu.addItem(makeMenuItem(
            title: "Translate screen area...",
            tag: .screenshotArea,
            symbolName: "viewfinder",
            action: #selector(translateScreenshotAreaFromMenu),
            keyEquivalent: shortcut(for: .screenshotArea).menuKeyEquivalent,
            keyEquivalentModifierMask: shortcut(for: .screenshotArea).keyEquivalentModifierMask
        ))

        menu.addItem(makeMenuItem(
            title: "",
            tag: .keyboardShortcuts,
            symbolName: "keyboard",
            submenu: makeKeyboardShortcutsMenu()
        ))

        menu.addItem(NSMenuItem.separator())

        menu.addItem(makeSectionHeader("Languages"))
        menu.addItem(makeMenuItem(
            title: "",
            tag: .targetLanguage,
            symbolName: "globe",
            submenu: makeTargetLanguageMenu()
        ))
        menu.addItem(makeMenuItem(
            title: "",
            tag: .draftTargetLanguage,
            symbolName: "text.bubble",
            submenu: makeDraftTargetLanguageMenu()
        ))

        menu.addItem(makeSectionHeader("Output"))
        menu.addItem(makeMenuItem(
            title: "",
            tag: .writingStyle,
            symbolName: "textformat",
            submenu: makeWritingStyleMenu()
        ))
        menu.addItem(makeMenuItem(
            title: "",
            tag: .cleanupLevel,
            symbolName: "sparkles",
            submenu: makeCleanupLevelMenu()
        ))
        menu.addItem(makeMenuItem(
            title: "Snippets & dictionary…",
            tag: .snippets,
            symbolName: "text.append",
            action: #selector(openSnippetsWindow),
            keyEquivalent: ""
        ))

        menu.addItem(makeSectionHeader("AI engine"))
        menu.addItem(makeMenuItem(
            title: "",
            tag: .selectedModel,
            symbolName: "cpu",
            submenu: makeModelSelectionMenu()
        ))
        menu.addItem(makeMenuItem(
            title: "",
            tag: .thinkingLevel,
            symbolName: "brain.head.profile",
            submenu: makeThinkingLevelMenu()
        ))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeMenuItem(
            title: "DM us for bug or request...",
            tag: .contactSupport,
            symbolName: "envelope",
            action: #selector(contactSupport),
            keyEquivalent: ""
        ))
        menu.addItem(makeMenuItem(
            title: "Reset settings...",
            tag: .resetSettings,
            symbolName: "arrow.counterclockwise",
            action: #selector(resetSettings),
            keyEquivalent: ""
        ))
        menu.addItem(makeMenuItem(
            title: "Check for updates...",
            tag: .checkForUpdates,
            symbolName: "arrow.down.circle",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        ))
        menu.addItem(makeMenuItem(
            title: "Quit",
            tag: .quit,
            symbolName: "power",
            action: #selector(quit),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
        self.statusItem = statusItem
        updateMenuState()
    }

    private func makeMenuItem(
        title: String,
        tag: MenuItemTag,
        symbolName: String? = nil,
        action: Selector? = nil,
        keyEquivalent: String = "",
        keyEquivalentModifierMask: NSEvent.ModifierFlags = .command,
        isEnabled: Bool = true,
        submenu: NSMenu? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.tag = tag.rawValue
        item.isEnabled = isEnabled
        item.keyEquivalentModifierMask = keyEquivalentModifierMask
        item.submenu = submenu
        if action != nil {
            item.target = self
        }
        if let symbolName {
            item.image = menuSymbol(symbolName)
        }
        return item
    }

    private func menuSymbol(_ name: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }

        image.isTemplate = true
        return image
    }

    private func makeSectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        let item = NSMenuItem(title: title.uppercased(), action: nil, keyEquivalent: "")
        item.isEnabled = false
        let attributed = NSAttributedString(string: title.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        item.attributedTitle = attributed
        return item
    }

    private func makeStatusBarIcon(for mode: FloatingButtonDefaultMode) -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()

        let backgroundDiameter: CGFloat = 18.5
        let backgroundOrigin = (size.width - backgroundDiameter) / 2
        let backgroundRect = NSRect(
            x: backgroundOrigin,
            y: backgroundOrigin,
            width: backgroundDiameter,
            height: backgroundDiameter
        )
        NSColor(calibratedWhite: 0.12, alpha: 0.92).setFill()
        NSBezierPath(ovalIn: backgroundRect).fill()

        switch mode {
        case .translate:
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraphStyle
            ]
            ("あ" as NSString).draw(
                in: NSRect(x: 0, y: 3.25, width: size.width, height: 16),
                withAttributes: attributes
            )
        case .smartReply:
            if let baseImage = NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
                let symbol = baseImage.withSymbolConfiguration(config) ?? baseImage
                let symbolSize = symbol.size
                let drawRect = NSRect(
                    x: (size.width - symbolSize.width) / 2,
                    y: (size.height - symbolSize.height) / 2,
                    width: symbolSize.width,
                    height: symbolSize.height
                )
                symbol.draw(in: drawRect)
            }
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func refreshStatusBarIcon() {
        statusItem?.button?.image = makeStatusBarIcon(for: floatingDefaultMode)
    }

    private func makeTargetLanguageMenu() -> NSMenu {
        let menu = NSMenu()
        for language in TranslationLanguage.all {
            let item = NSMenuItem(
                title: language.displayName,
                action: #selector(selectTargetLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language.id
            menu.addItem(item)
        }
        return menu
    }

    private func makeDraftTargetLanguageMenu() -> NSMenu {
        let menu = NSMenu()
        for language in TranslationLanguage.all {
            let item = NSMenuItem(
                title: language.displayName,
                action: #selector(selectDraftTargetLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language.id
            menu.addItem(item)
        }
        return menu
    }

    private func makeSelectionDisplayModeMenu() -> NSMenu {
        let menu = NSMenu()
        for mode in SelectionDisplayMode.allCases {
            let item = NSMenuItem(
                title: mode.menuTitle,
                action: #selector(selectSelectionDisplayMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            menu.addItem(item)
        }
        return menu
    }

    private func makeFloatingDefaultModeMenu() -> NSMenu {
        let menu = NSMenu()
        let translateItem = NSMenuItem(
            title: "Translate",
            action: #selector(selectFloatingDefaultMode(_:)),
            keyEquivalent: ""
        )
        translateItem.target = self
        translateItem.representedObject = FloatingButtonDefaultMode.translate.rawValue
        menu.addItem(translateItem)

        let replyItem = NSMenuItem(
            title: "Reply",
            action: #selector(selectFloatingDefaultMode(_:)),
            keyEquivalent: ""
        )
        replyItem.target = self
        replyItem.representedObject = FloatingButtonDefaultMode.smartReply.rawValue
        menu.addItem(replyItem)
        return menu
    }

    private func makeThinkingLevelMenu() -> NSMenu {
        let menu = NSMenu()
        for scope in ModelUseScope.allCases {
            let level = thinkingLevel(for: scope)
            let item = NSMenuItem(
                title: scope.thinkingMenuTitle(for: level),
                action: nil,
                keyEquivalent: ""
            )
            item.representedObject = scope.rawValue
            item.submenu = makeScopedThinkingLevelMenu(for: scope)
            menu.addItem(item)
        }
        return menu
    }

    private func makeScopedThinkingLevelMenu(for scope: ModelUseScope) -> NSMenu {
        let menu = NSMenu()
        for level in ThinkingLevel.allCases {
            let item = NSMenuItem(
                title: level.menuTitle,
                action: #selector(selectThinkingLevel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = ThinkingMenuSelection(scope: scope, level: level)
            menu.addItem(item)
        }
        return menu
    }

    private func makeModelSelectionMenu() -> NSMenu {
        let menu = NSMenu()
        for scope in ModelUseScope.allCases {
            let model = LLMModel.option(id: modelID(for: scope))
            let item = NSMenuItem(
                title: scope.menuTitle(for: model),
                action: nil,
                keyEquivalent: ""
            )
            item.representedObject = scope.rawValue
            item.submenu = makeScopedModelSelectionMenu(for: scope)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(makeConfigureAPIKeysMenuItem())
        return menu
    }

    private func makeScopedModelSelectionMenu(for scope: ModelUseScope) -> NSMenu {
        switch scope {
        case .textActions:
            return makeTextModelSelectionMenu(for: scope)
        case .askNugumi:
            return makeAPIKeyModelMenu(
                models: scope.availableModels(from: LLMModel.apiKeyModels),
                scope: scope
            )
        }
    }

    private func makeTextModelSelectionMenu(for scope: ModelUseScope) -> NSMenu {
        let menu = NSMenu()
        for entry in LLMModel.modeMenuEntries {
            switch entry {
            case .model(let option):
                menu.addItem(makeModelMenuItem(option, scope: scope))
            case .apiKeyModels(let title, let models):
                menu.addItem(.separator())
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = makeAPIKeyModelMenu(
                    models: scope.availableModels(from: models),
                    scope: scope
                )
                menu.addItem(item)
            }
        }
        return menu
    }

    private func makeAPIKeyModelMenu(models: [LLMModel], scope: ModelUseScope) -> NSMenu {
        let menu = NSMenu()
        for provider in CloudProvider.allCases {
            let providerModels = models.filter { $0.cloudProvider == provider }
            guard !providerModels.isEmpty else { continue }
            if !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            for option in providerModels {
                menu.addItem(makeModelMenuItem(option, scope: scope))
            }
        }
        return menu
    }

    private func makeConfigureAPIKeysMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Configure API keys…",
            action: #selector(openOnboardingChooser),
            keyEquivalent: ""
        )
        item.target = self
        return item
    }

    private func makeModelMenuItem(_ option: LLMModel, scope: ModelUseScope) -> NSMenuItem {
        let item = NSMenuItem(
            title: option.displayName,
            action: #selector(selectModel(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = ModelMenuSelection(scope: scope, modelID: option.id)
        return item
    }

    @MainActor
    @objc private func openOnboardingChooser() {
        presentOnboardingWindow()
    }

    private func makeWritingStyleMenu() -> NSMenu {
        let menu = NSMenu()
        for category in AppCategory.allCases {
            let categoryItem = NSMenuItem(title: category.displayName, action: nil, keyEquivalent: "")
            categoryItem.representedObject = category.rawValue
            let submenu = NSMenu()
            for style in WritingStyle.allCases {
                let item = NSMenuItem(
                    title: style.displayName,
                    action: #selector(selectWritingStyle(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = "\(category.rawValue):\(style.rawValue)"
                submenu.addItem(item)
            }
            categoryItem.submenu = submenu
            menu.addItem(categoryItem)
        }
        return menu
    }

    private func makeCleanupLevelMenu() -> NSMenu {
        let menu = NSMenu()
        for level in CleanupLevel.allCases {
            let item = NSMenuItem(
                title: level.displayName,
                action: #selector(selectCleanupLevel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = level.rawValue
            menu.addItem(item)
        }
        return menu
    }

    private func makeReplacementModeMenu() -> NSMenu {
        let menu = NSMenu()
        for mode in ReplacementMode.allCases {
            let item = NSMenuItem(
                title: mode.menuTitle,
                action: #selector(selectReplacementMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            menu.addItem(item)
        }
        return menu
    }

    private func makeKeyboardShortcutsMenu() -> NSMenu {
        let menu = NSMenu()
        for action in GlobalShortcutAction.allCases {
            let shortcut = shortcut(for: action)
            let item = NSMenuItem(
                title: "\(action.menuTitle): \(shortcut.displayString)",
                action: #selector(recordKeyboardShortcut(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = action.rawValue
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let resetItem = NSMenuItem(
            title: "Reset to defaults",
            action: #selector(resetKeyboardShortcuts),
            keyEquivalent: ""
        )
        resetItem.target = self
        menu.addItem(resetItem)
        return menu
    }

    private func startMouseMonitor() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseUp]) { [weak self] event in
            guard let self else { return }
            let mouseLocation = NSEvent.mouseLocation
            if event.type == .leftMouseDown {
                self.lastLeftMouseDownLocation = mouseLocation
                if self.isScreenshotTranslationRunning {
                    self.screenshotDragStartLocation = mouseLocation
                    self.screenshotDragEndLocation = nil
                }
                return
            }

            if event.type == .leftMouseDragged {
                if self.isScreenshotTranslationRunning {
                    self.updateScreenshotDrag(to: mouseLocation)
                }
                return
            }

            if self.isScreenshotTranslationRunning {
                if event.type == .leftMouseUp {
                    self.updateScreenshotDrag(to: mouseLocation)
                }
                return
            }

            self.handleMouseUp(event)
        }
    }

    @MainActor
    private func applySelectionDisplayMode() {
        switch selectionDisplayMode {
        case .floatingBar:
            petController?.close()
            petController = nil
        case .off:
            petController?.close()
            petController = nil
            translateButtonController?.close()
            translateButtonController = nil
            cancelPrefetch()
        case .pet:
            translateButtonController?.close()
            translateButtonController = nil
            if petController == nil {
                petController = PetController(initialMode: floatingDefaultMode.translationMode)
            }
            petController?.show()
        }

        updateMenuState()
    }

    private func handleMouseUp(_ event: NSEvent) {
        guard accessibilityIsTrusted() else {
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        if let controller = translationPanelController,
           controller.isVisible,
           controller.panelFrame.insetBy(dx: -4, dy: -4).contains(mouseLocation) {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            let preferClipboard = self.shouldAttemptClipboardSelectionFallback(for: event)

            self.selectionReader.readSelectedTextContext(
                preferClipboard: preferClipboard,
                allowClipboardFallback: false
            ) { [weak self] selection in
                guard let self else { return }

                guard let selection, !selection.text.isEmpty else {
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    self.petController?.clearReady()
                    self.cancelPrefetch()
                    return
                }

                let cleanedSelection = TextNormalizer.cleanedSelection(selection.text)
                guard !cleanedSelection.isEmpty,
                      TextNormalizer.looksMeaningful(cleanedSelection)
                else {
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    self.petController?.clearReady()
                    self.cancelPrefetch()
                    return
                }

                self.showTranslateButton(
                    for: cleanedSelection,
                    near: mouseLocation,
                    selectionRect: selection.selectionRect,
                    panelSide: self.panelSideForSelectionEnding(at: mouseLocation)
                )
            }
        }
    }

    private func panelSideForSelectionEnding(at mouseLocation: NSPoint) -> TranslationPanelController.Side {
        panelSideForDrag(from: lastLeftMouseDownLocation, to: mouseLocation)
    }

    private func panelSideForScreenshotEnding(at mouseLocation: NSPoint) -> TranslationPanelController.Side {
        screenshotPanelSide ?? panelSideForDrag(from: screenshotDragStartLocation, to: mouseLocation)
    }

    private func panelSideForDrag(from startLocation: NSPoint?, to endLocation: NSPoint) -> TranslationPanelController.Side {
        guard let startLocation else { return .right }

        let dx = endLocation.x - startLocation.x
        let dy = endLocation.y - startLocation.y
        // Need a meaningful horizontal drag — vertical or tiny drags
        // give no reliable direction signal, so default to .right.
        guard abs(dx) >= 5, abs(dx) > abs(dy) else { return .right }
        return dx > 0 ? .right : .left
    }

    private func updateScreenshotDrag(to mouseLocation: NSPoint) {
        screenshotDragEndLocation = mouseLocation
        screenshotPanelSide = panelSideForDrag(from: screenshotDragStartLocation, to: mouseLocation)
    }

    @MainActor
    private func startScreenshotDragTracking() {
        resetScreenshotDragTracking()
        let tracker = ScreenshotDragTracker { [weak self] startLocation, endLocation, panelSide in
            guard let self else { return }
            if let startLocation {
                self.screenshotDragStartLocation = startLocation
            }
            if let endLocation {
                self.screenshotDragEndLocation = endLocation
            }
            if let panelSide {
                self.screenshotPanelSide = panelSide
            }
        }
        screenshotDragTracker = tracker
        tracker.enable()
    }

    @MainActor
    private func resetScreenshotDragTracking() {
        screenshotDragTracker?.disable()
        screenshotDragTracker = nil
        screenshotDragStartLocation = nil
        screenshotDragEndLocation = nil
        screenshotPanelSide = nil
    }

    private func shouldAttemptClipboardSelectionFallback(for event: NSEvent) -> Bool {
        guard event.type == .leftMouseUp else {
            return false
        }

        let isSelectionGesture: Bool
        if event.clickCount >= 2 {
            isSelectionGesture = true
        } else if let downLocation = lastLeftMouseDownLocation {
            let upLocation = NSEvent.mouseLocation
            let distance = hypot(upLocation.x - downLocation.x, upLocation.y - downLocation.y)
            isSelectionGesture = distance >= 15
        } else {
            isSelectionGesture = false
        }

        guard isSelectionGesture else {
            return false
        }

        return !selectionReader.isLikelyEditableElementAtMouseLocation()
    }

    @MainActor
    private func showTranslateButton(
        for selectedText: String,
        near screenPoint: NSPoint,
        selectionRect: NSRect? = nil,
        panelSide: TranslationPanelController.Side = .right
    ) {
        translationPanelController?.close()
        translateButtonController?.close()
        petController?.clearReady()

        guard selectionDisplayMode != .off else {
            cancelPrefetch()
            return
        }

        let primaryMode = floatingDefaultMode.translationMode
        if primaryMode == .selection {
            let language = targetLanguage
            let currentThinkingLevel = textThinkingLevel
            if translationCache.translation(for: selectedText, targetLanguage: language, thinkingLevel: currentThinkingLevel) == nil {
                startPrefetchIfEligible(for: selectedText)
            } else {
                cancelPrefetch()
            }
        } else {
            cancelPrefetch()
        }

        if selectionDisplayMode == .pet {
            if petController == nil {
                petController = PetController(initialMode: primaryMode)
            }
            petController?.show()
            petController?.showReady(
                selectedText: selectedText,
                initialMode: primaryMode,
                onTranslate: { [weak self] text in
                    self?.translate(
                        text,
                        near: screenPoint,
                        selectionRect: selectionRect,
                        panelSide: panelSide,
                        keepPetReadyUntilPanelCloses: true
                    )
                },
                onRewrite: { [weak self] text in
                    self?.rewriteSelectedDraftText(
                        text,
                        near: screenPoint,
                        selectionRect: selectionRect,
                        panelSide: panelSide,
                        keepPetReadyUntilPanelCloses: true
                    )
                },
                onSmartReply: { [weak self] text in
                    self?.replyToSelection(
                        text,
                        near: screenPoint,
                        selectionRect: selectionRect,
                        panelSide: panelSide,
                        keepPetReadyUntilPanelCloses: true
                    )
                }
            )
            return
        }

        let controller = FloatingTranslateButtonController(
            screenPoint: screenPoint,
            selectedText: selectedText,
            initialMode: primaryMode,
            onTranslate: { [weak self] text in
                self?.translateButtonController?.close()
                self?.translateButtonController = nil
                self?.translate(
                    text,
                    near: screenPoint,
                    selectionRect: selectionRect,
                    panelSide: panelSide
                )
            },
            onRewrite: { [weak self] text in
                self?.rewriteSelectedDraftText(
                    text,
                    near: screenPoint,
                    selectionRect: selectionRect,
                    panelSide: panelSide
                )
            },
            onSmartReply: { [weak self] text in
                self?.translateButtonController?.close()
                self?.translateButtonController = nil
                self?.replyToSelection(
                    text,
                    near: screenPoint,
                    selectionRect: selectionRect,
                    panelSide: panelSide
                )
            }
        )

        translateButtonController = controller
        controller.show()
    }

    @MainActor
    private func rewriteSelectedDraftText(
        _ text: String,
        near screenPoint: NSPoint,
        selectionRect: NSRect? = nil,
        panelSide: TranslationPanelController.Side = .right,
        keepPetReadyUntilPanelCloses: Bool = false
    ) {
        cancelPrefetch()
        lastReplacementSourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        let cleanedDraft = TextNormalizer.cleanedDraftMessage(text)
        guard !cleanedDraft.isEmpty else {
            translateButtonController?.close()
            translateButtonController = nil
            petController?.clearReady()
            presentSelectionTranslationError("Select text first, then run Rewrite my text.")
            return
        }

        let language = draftTargetLanguage
        switch replacementMode {
        case .instantInsert:
            runInstantTranslation(cleanedDraft, language: language, near: screenPoint)
        case .showPanel:
            translateButtonController?.close()
            translateButtonController = nil
            translate(
                cleanedDraft,
                near: screenPoint,
                targetLanguage: language,
                mode: .draftMessage,
                useCache: false,
                usageKind: .draftMessage,
                selectionRect: selectionRect,
                panelSide: panelSide,
                keepPetReadyUntilPanelCloses: keepPetReadyUntilPanelCloses,
                onReplace: { [weak self] translation in
                    self?.replaceCurrentSelection(with: translation)
                },
                replaceShortcutSourcePID: lastReplacementSourcePID
            )
        }
    }

    @MainActor
    private func replyToSelection(
        _ text: String,
        near screenPoint: NSPoint,
        selectionRect: NSRect? = nil,
        panelSide: TranslationPanelController.Side = .right,
        keepPetReadyUntilPanelCloses: Bool = false
    ) {
        cancelPrefetch()
        translate(
            text,
            near: screenPoint,
            mode: .smartReply,
            useCache: false,
            usageKind: .smartReply,
            selectionRect: selectionRect,
            panelSide: panelSide,
            keepPetReadyUntilPanelCloses: keepPetReadyUntilPanelCloses
        )
    }

    @MainActor
    private func translate(
        _ text: String,
        near screenPoint: NSPoint,
        targetLanguage explicitTargetLanguage: TranslationLanguage? = nil,
        mode: TranslationMode = .selection,
        useCache: Bool = true,
        usageKind: UsageStatsEventKind = .selection,
        selectionRect: NSRect? = nil,
        panelSide: TranslationPanelController.Side = .right,
        keepPetReadyUntilPanelCloses: Bool = false,
        onReplace: ((String) -> Void)? = nil,
        replaceShortcutSourcePID: pid_t? = nil
    ) {
        if let setupError = translationErrorIfBootstrapNeedsSetup() {
            handleTranslationFailure(setupError)
            return
        }

        let language = explicitTargetLanguage ?? targetLanguage
        let currentThinkingLevel = textThinkingLevel
        let (_, currentAppCategory) = AppCategoryClassifier.detectFrontmost()
        let currentComposition = compositionSettings(for: mode, appCategory: currentAppCategory)
        let anchor: TranslationPanelController.Anchor =
            selectionRect.map(TranslationPanelController.Anchor.selection)
                ?? .point(screenPoint, panelSide: panelSide)
        let controller = TranslationPanelController(
            anchor: anchor,
            sourceText: text,
            targetLanguage: language,
            resultLabel: mode.resultLabel,
            loadingPlaceholder: mode.loadingPlaceholder,
            onTargetLanguageSelected: { [weak self] selectedLanguage in
                self?.retranslateCurrentPanel(
                    text,
                    targetLanguage: selectedLanguage,
                    mode: mode,
                    thinkingLevel: currentThinkingLevel,
                    appCategory: currentAppCategory,
                    composition: currentComposition,
                    useCache: useCache,
                    usageKind: usageKind
                )
            },
            onReplace: onReplace,
            replaceShortcutSourcePID: replaceShortcutSourcePID,
            onClose: { [weak self] in
                self?.translationPanelController = nil
                self?.petController?.clearReady()
            }
        )
        translationPanelController?.close()
        translationPanelController = controller
        if keepPetReadyUntilPanelCloses {
            holdPetReadyUntilActivePanelCloses(mode: mode)
        }
        let requestID = controller.showLoading()
        runTranslation(
            text,
            targetLanguage: language,
            mode: mode,
            thinkingLevel: currentThinkingLevel,
            appCategory: currentAppCategory,
            composition: currentComposition,
            useCache: useCache,
            usageKind: usageKind,
            controller: controller,
            requestID: requestID
        )
    }

    @MainActor
    private func compositionSettings(for mode: TranslationMode, appCategory: AppCategory) -> CompositionSettings? {
        guard mode.usesCompositionSettings else {
            return nil
        }
        return CompositionSettings(
            style: writingStyle(for: appCategory),
            cleanup: cleanupLevel,
            snippets: snippetsStore.usableSnippets()
        )
    }

    @MainActor
    private func holdPetReadyUntilActivePanelCloses(mode: TranslationMode) {
        guard selectionDisplayMode == .pet else {
            return
        }

        if petController == nil {
            petController = PetController(initialMode: mode)
        }
        petController?.show()
        petController?.holdReadyUntilPanelCloses(mode: mode)
    }

    @MainActor
    private func retranslateCurrentPanel(
        _ text: String,
        targetLanguage language: TranslationLanguage,
        mode: TranslationMode,
        thinkingLevel: ThinkingLevel,
        appCategory: AppCategory,
        composition: CompositionSettings?,
        useCache: Bool,
        usageKind: UsageStatsEventKind
    ) {
        guard let controller = translationPanelController else {
            return
        }

        let requestID = controller.showLoading(targetLanguage: language)
        runTranslation(
            text,
            targetLanguage: language,
            mode: mode,
            thinkingLevel: thinkingLevel,
            appCategory: appCategory,
            composition: composition,
            useCache: useCache,
            usageKind: usageKind,
            controller: controller,
            requestID: requestID
        )
    }

    @MainActor
    private func runTranslation(
        _ text: String,
        targetLanguage language: TranslationLanguage,
        mode: TranslationMode,
        thinkingLevel: ThinkingLevel,
        appCategory: AppCategory,
        composition: CompositionSettings?,
        useCache: Bool,
        usageKind: UsageStatsEventKind,
        controller: TranslationPanelController,
        requestID: UUID
    ) {
        if let busyError = translationErrorIfBootstrapBusy() {
            controller.showError(Self.translationPanelErrorMessage(for: busyError), requestID: requestID)
            return
        }

        if useCache, let cachedTranslation = translationCache.translation(for: text, targetLanguage: language, thinkingLevel: thinkingLevel) {
            usageStatsStore.recordUse(
                sourceText: text,
                resultText: cachedTranslation,
                kind: usageKind,
                targetLanguage: language
            )
            analyticsClient.trackCompletedUsage(
                kind: usageKind,
                targetLanguageID: language.id,
                modelID: textModelID
            )
            controller.showTranslation(cachedTranslation, requestID: requestID)
            return
        }

        if useCache,
           let translationPrefetch,
           translationPrefetch.text == text,
           translationPrefetch.targetLanguage == language,
           translationPrefetch.thinkingLevel == thinkingLevel,
           translationPrefetch.appCategory == appCategory {
            translationPrefetch.subscribe { partialTranslation in
                controller.showTranslation(partialTranslation, requestID: requestID)
            } onCompletion: { [weak self] finalTranslation in
                self?.usageStatsStore.recordUse(
                    sourceText: text,
                    resultText: finalTranslation,
                    kind: usageKind,
                    targetLanguage: language
                )
                self?.analyticsClient.trackCompletedUsage(
                    kind: usageKind,
                    targetLanguageID: language.id,
                    modelID: self?.textModelID ?? "unknown"
                )
            } onFailure: { [weak self, weak controller] error in
                guard let self, let controller else { return }
                if self.handleTranslationFailure(error, controller: controller) {
                    return
                }
                controller.showError(Self.translationPanelErrorMessage(for: error), requestID: requestID)
            }
            translationPrefetch.ensureStartedNow()
            return
        }

        let backend = currentBackend
        Task {
            do {
                let translated = try await backend.translate(
                    text,
                    images: [],
                    to: language,
                    mode: mode,
                    appCategory: appCategory,
                    composition: composition,
                    thinkingLevel: thinkingLevel
                ) { partialTranslation in
                    Task { @MainActor in
                        controller.showTranslation(partialTranslation, requestID: requestID)
                    }
                }
                await MainActor.run {
                    if useCache {
                        self.translationCache.store(translated, for: text, targetLanguage: language, thinkingLevel: thinkingLevel)
                    }
                    self.usageStatsStore.recordUse(
                        sourceText: text,
                        resultText: translated,
                        kind: usageKind,
                        targetLanguage: language
                    )
                    self.analyticsClient.trackCompletedUsage(
                        kind: usageKind,
                        targetLanguageID: language.id,
                        modelID: self.textModelID
                    )
                    controller.showTranslation(translated, requestID: requestID)
                }
            } catch {
                await MainActor.run {
                    if self.handleTranslationFailure(error, controller: controller) {
                        return
                    }
                    self.analyticsClient.track(.errorOccurred, properties: [
                        "error_type": Self.analyticsErrorType(error),
                        "error_context": "translation"
                    ])
                    controller.showError(Self.translationPanelErrorMessage(for: error), requestID: requestID)
                }
            }
        }
    }

    @MainActor
    @discardableResult
    private func handleTranslationFailure(_ error: Error, controller: TranslationPanelController? = nil) -> Bool {
        guard let translationError = error as? TranslationError else { return false }
        switch translationError {
        case .serverUnavailable, .modelMissing, .signInRequired:
            controller?.close()
            bootstrap.refresh()
            presentOnboardingWindow()
            return true
        case .invalidAPIKey(let provider):
            controller?.close()
            KeychainStore.setAPIKey(nil, for: provider)
            bootstrap.refresh()
            presentAPIKeySheet(for: provider) { _ in }
            return true
        case .ollama, .emptyResponse, .modelDownloading, .rateLimited, .cloudError:
            return false
        }
    }

    private static func analyticsErrorType(_ error: Error) -> String {
        if let translationError = error as? TranslationError {
            switch translationError {
            case .ollama: return "ollama"
            case .emptyResponse: return "empty_response"
            case .modelDownloading: return "model_downloading"
            case .serverUnavailable: return "server_unavailable"
            case .modelMissing: return "model_missing"
            case .signInRequired: return "sign_in_required"
            case .invalidAPIKey: return "invalid_api_key"
            case .rateLimited: return "rate_limited"
            case .cloudError: return "cloud_error"
            }
        }
        return String(describing: type(of: error))
    }

    private static func translationPanelErrorMessage(for error: Error) -> String {
        guard let translationError = error as? TranslationError else {
            return "Could not translate this.\n\(error.localizedDescription)"
        }

        switch translationError {
        case .ollama(let message):
            return "Could not translate this.\n\(message)"
        case .emptyResponse:
            return "No translation came back. Try again."
        case .modelDownloading(let detail):
            return "Translator is still downloading.\n\(detail)"
        case .serverUnavailable:
            return "Ollama is not running."
        case .modelMissing:
            return "Translator is not downloaded yet."
        case .signInRequired:
            return "Sign in to Ollama to use the online translator."
        case .invalidAPIKey(let provider):
            return "\(provider.displayName) rejected the API key."
        case .rateLimited(let provider):
            return "\(provider.displayName) rate limit reached. Try again in a minute."
        case .cloudError(let provider, let detail):
            return "\(provider.displayName): \(detail)"
        }
    }

    @MainActor
    private func translationErrorIfBootstrapBusy(for modelID: String? = nil) -> TranslationError? {
        let modelID = modelID ?? textModelID
        if case .working(let detail) = bootstrap.state.modelReady(for: modelID) {
            return .modelDownloading(detail)
        }
        return nil
    }

    @MainActor
    private func translationErrorIfBootstrapNeedsSetup(for modelID: String? = nil) -> TranslationError? {
        let modelID = modelID ?? textModelID
        let model = LLMModel.option(id: modelID)
        if let provider = model.cloudProvider {
            if case .needsAction = bootstrap.state.cloudKey(for: provider) {
                return .invalidAPIKey(provider)
            }
            return nil
        }

        if case .needsAction = bootstrap.state.ollamaInstalled {
            return .serverUnavailable
        }
        if case .needsAction = bootstrap.state.serverRunning {
            return .serverUnavailable
        }
        if case .needsAction = bootstrap.state.ollamaSignedIn,
           model.isCloud {
            return .signInRequired
        }
        if case .needsAction = bootstrap.state.modelReady(for: modelID) {
            return .modelMissing(modelID)
        }
        return nil
    }

    @MainActor
    private func startPrefetchIfEligible(for text: String) {
        cancelPrefetch()

        guard text.count <= prefetchMaxCharacterCount else {
            return
        }

        // Don't burn API calls while the translator isn't ready — the request
        // would only surface a 404/connection error inside the prefetch.
        guard bootstrap.isReady(for: textModelID) else {
            return
        }

        let language = targetLanguage
        let currentThinkingLevel = textThinkingLevel
        let (_, appCategory) = AppCategoryClassifier.detectFrontmost()
        let prefetch = TranslationPrefetch(
            text: text,
            targetLanguage: language,
            thinkingLevel: currentThinkingLevel,
            appCategory: appCategory,
            backend: currentBackend
        ) { [weak self] sourceText, targetLanguage, thinkingLevel, translation in
            self?.translationCache.store(translation, for: sourceText, targetLanguage: targetLanguage, thinkingLevel: thinkingLevel)
        }
        translationPrefetch = prefetch
        prefetch.startAfterDelay(milliseconds: prefetchDelayMilliseconds)
    }

    @MainActor
    private func cancelPrefetch() {
        translationPrefetch?.cancel()
        translationPrefetch = nil
    }

    private func requestAccessibilityPermissionIfNeeded() {
        // prompt:false silently registers Nugumi in System Settings → Privacy &
        // Security → Accessibility (so the TCC entry exists and the user can find
        // the toggle), without surfacing macOS's stock "would like to control this
        // computer using accessibility features" dialog. The friendlier prompt
        // lives in PermissionsWindowController.
        let probe = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false] as CFDictionary
        guard !AXIsProcessTrustedWithOptions(probe) else {
            return
        }
        startAccessibilityTrustWatcher()
    }

    private func accessibilityIsTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    private func startAccessibilityTrustWatcher() {
        guard accessibilityTrustTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                if self.accessibilityIsTrusted() {
                    timer.invalidate()
                    self.accessibilityTrustTimer = nil
                    self.updateMenuState()
                    self.presentPermissionsWindowIfNeeded()
                }
            }
        }
        accessibilityTrustTimer = timer
    }

    private func requestScreenRecordingPermissionIfNeeded() {
        // No CGRequestScreenCaptureAccess() at launch — that triggers Apple's
        // stock "would like to record this screen" dialog, which we replace
        // with our own row in PermissionsWindowController. The actual TCC
        // registration happens lazily when the user clicks "Open settings" in
        // that window, or on the first screenshot attempt.
        guard !CGPreflightScreenCaptureAccess() else {
            return
        }
        startScreenRecordingTrustWatcher()
    }

    private func startScreenRecordingTrustWatcher() {
        guard screenRecordingTrustTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                if CGPreflightScreenCaptureAccess() {
                    timer.invalidate()
                    self.screenRecordingTrustTimer = nil
                    self.updateMenuState()
                    self.presentPermissionsWindowIfNeeded()
                }
            }
        }
        screenRecordingTrustTimer = timer
    }

    private func presentPermissionsWindowIfNeeded() {
        presentPermissionsWindow(force: false)
    }

    private func presentPermissionsWindow(force: Bool) {
        let axTrusted = AXIsProcessTrusted()
        let scrTrusted = CGPreflightScreenCaptureAccess()
        guard force || !(axTrusted && scrTrusted) || !PermissionsWindowController.hasCompletedFeatureTour else { return }
        if let permissionsWindowController {
            permissionsWindowController.presentAndActivate()
            return
        }

        let hadCompletedFeatureTour = PermissionsWindowController.hasCompletedFeatureTour
        let controller = PermissionsWindowController(allowsCompletedReview: force) { [weak self] in
            guard let self else { return }
            if !hadCompletedFeatureTour && PermissionsWindowController.hasCompletedFeatureTour {
                self.analyticsClient.track(.onboardingCompleted)
            }
            self.permissionsWindowController = nil
        }
        permissionsWindowController = controller
        controller.presentAndActivate()
    }

    private func updateMenuState() {
        guard let menu = statusItem?.menu else {
            return
        }

        let trusted = accessibilityIsTrusted()
        menu.item(withTag: MenuItemTag.permissionNotice.rawValue)?.isHidden = trusted
        menu.item(withTag: MenuItemTag.accessibilitySettings.rawValue)?.isHidden = trusted
        menu.item(withTag: MenuItemTag.permissionSeparator.rawValue)?.isHidden = trusted

        let bootstrapReady = bootstrap.isReady(for: textModelID)
        menu.item(withTag: MenuItemTag.bootstrapNotice.rawValue)?.isHidden = bootstrapReady
        menu.item(withTag: MenuItemTag.bootstrapAction.rawValue)?.title = bootstrapReady
            ? "Setup..."
            : "Open setup..."
        menu.item(withTag: MenuItemTag.bootstrapSeparator.rawValue)?.isHidden = bootstrapReady
        menu.item(withTag: MenuItemTag.targetLanguage.rawValue)?.title = "Translate selected text to: \(targetLanguage.displayName)"
        menu.item(withTag: MenuItemTag.draftTargetLanguage.rawValue)?.title = "Write / rewrite my text in: \(draftTargetLanguage.displayName)"
        menu.item(withTag: MenuItemTag.selectionDisplayMode.rawValue)?.title = selectionDisplayMode.settingsTitle
        menu.item(withTag: MenuItemTag.floatingDefaultMode.rawValue)?.title = floatingDefaultMode.menuTitle
        menu.item(withTag: MenuItemTag.thinkingLevel.rawValue)?.title = "Thinking"
        menu.item(withTag: MenuItemTag.selectedModel.rawValue)?.title = "Models"
        menu.item(withTag: MenuItemTag.checkForUpdates.rawValue)?.isHidden = !isRunningFromAppBundle
        if let translateSelectionItem = menu.item(withTag: MenuItemTag.translateSelection.rawValue) {
            translateSelectionItem.title = "Rewrite my text in \(draftTargetLanguage.displayName)..."
            applyShortcut(for: .translateSelection, to: translateSelectionItem)
            translateSelectionItem.isEnabled = trusted
        }
        if let screenshotItem = menu.item(withTag: MenuItemTag.screenshotArea.rawValue) {
            let idleTitle: String
            switch floatingDefaultMode {
            case .translate:
                idleTitle = "Translate screen area to \(targetLanguage.displayName)..."
            case .smartReply:
                idleTitle = "Reply to screen area..."
            }
            screenshotItem.title = isScreenshotTranslationRunning
                ? "Selecting screen area..."
                : idleTitle
            applyShortcut(for: .screenshotArea, to: screenshotItem)
            screenshotItem.isEnabled = !isScreenshotTranslationRunning
        }
        if let selectionItem = menu.item(withTag: MenuItemTag.translateOrReplySelection.rawValue) {
            switch floatingDefaultMode {
            case .translate:
                selectionItem.title = "Translate selected text to \(targetLanguage.displayName)..."
            case .smartReply:
                selectionItem.title = "Reply to selected text..."
            }
            applyShortcut(for: .translateOrReply, to: selectionItem)
            selectionItem.isEnabled = trusted
        }

        if let languageMenu = menu.item(withTag: MenuItemTag.targetLanguage.rawValue)?.submenu {
            for item in languageMenu.items {
                guard let languageID = item.representedObject as? String else { continue }
                item.state = languageID == targetLanguage.id ? .on : .off
            }
        }

        if let draftLanguageMenu = menu.item(withTag: MenuItemTag.draftTargetLanguage.rawValue)?.submenu {
            for item in draftLanguageMenu.items {
                guard let languageID = item.representedObject as? String else { continue }
                item.state = languageID == draftTargetLanguage.id ? .on : .off
            }
        }

        if let displayModeMenu = menu.item(withTag: MenuItemTag.selectionDisplayMode.rawValue)?.submenu {
            let activeMode = selectionDisplayMode.rawValue
            for item in displayModeMenu.items {
                guard let raw = item.representedObject as? String else { continue }
                item.state = raw == activeMode ? .on : .off
            }
        }

        if let defaultModeMenu = menu.item(withTag: MenuItemTag.floatingDefaultMode.rawValue)?.submenu {
            let activeMode = floatingDefaultMode.rawValue
            for item in defaultModeMenu.items {
                guard let raw = item.representedObject as? String else { continue }
                item.state = raw == activeMode ? .on : .off
            }
        }

        if let thinkingMenu = menu.item(withTag: MenuItemTag.thinkingLevel.rawValue)?.submenu {
            updateThinkingScopeTitles(in: thinkingMenu)
            updateThinkingSelectionState(in: thinkingMenu)
        }

        if let modelMenu = menu.item(withTag: MenuItemTag.selectedModel.rawValue)?.submenu {
            updateModelScopeTitles(in: modelMenu)
            updateModelSelectionState(in: modelMenu)
        }

        menu.item(withTag: MenuItemTag.writingStyle.rawValue)?.title = "Writing style"
        menu.item(withTag: MenuItemTag.cleanupLevel.rawValue)?.title = "Auto cleanup: \(cleanupLevel.displayName.lowercased())"
        menu.item(withTag: MenuItemTag.keyboardShortcuts.rawValue)?.title = "Edit keyboard shortcuts..."
        if let shortcutsMenu = menu.item(withTag: MenuItemTag.keyboardShortcuts.rawValue)?.submenu {
            updateKeyboardShortcutsMenu(shortcutsMenu)
        }

        if let styleMenu = menu.item(withTag: MenuItemTag.writingStyle.rawValue)?.submenu {
            for categoryItem in styleMenu.items {
                guard let categoryRaw = categoryItem.representedObject as? String,
                      let category = AppCategory(rawValue: categoryRaw),
                      let submenu = categoryItem.submenu
                else { continue }
                let activeStyle = writingStyle(for: category)
                categoryItem.title = "\(category.displayName) — \(activeStyle.displayName)"
                for item in submenu.items {
                    guard let raw = item.representedObject as? String else { continue }
                    let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    item.state = parts[1] == activeStyle.rawValue ? .on : .off
                }
            }
        }

        if let cleanupMenu = menu.item(withTag: MenuItemTag.cleanupLevel.rawValue)?.submenu {
            let activeLevel = cleanupLevel.rawValue
            for item in cleanupMenu.items {
                guard let raw = item.representedObject as? String else { continue }
                item.state = raw == activeLevel ? .on : .off
            }
        }

        menu.item(withTag: MenuItemTag.replacementMode.rawValue)?.title = replacementMode.settingsTitle
        if let replacementMenu = menu.item(withTag: MenuItemTag.replacementMode.rawValue)?.submenu {
            let activeMode = replacementMode.rawValue
            for item in replacementMenu.items {
                guard let raw = item.representedObject as? String else { continue }
                item.state = raw == activeMode ? .on : .off
            }
        }

        if let invisibilityItem = menu.item(withTag: MenuItemTag.invisibilityMode.rawValue) {
            invisibilityItem.state = invisibilityModeEnabled ? .on : .off
            let chord = shortcut(for: .toggleInvisibility)
            invisibilityItem.keyEquivalent = chord.menuKeyEquivalent
            invisibilityItem.keyEquivalentModifierMask = chord.keyEquivalentModifierMask
        }
    }

    private func updateThinkingScopeTitles(in menu: NSMenu) {
        for item in menu.items {
            if let raw = item.representedObject as? String,
               let scope = ModelUseScope(rawValue: raw) {
                item.title = scope.thinkingMenuTitle(for: thinkingLevel(for: scope))
            }
            if let submenu = item.submenu {
                updateThinkingScopeTitles(in: submenu)
            }
        }
    }

    @discardableResult
    private func updateThinkingSelectionState(in menu: NSMenu) -> Bool {
        var containsActiveLevel = false
        for item in menu.items {
            if let submenu = item.submenu {
                let submenuContainsActiveLevel = updateThinkingSelectionState(in: submenu)
                item.state = submenuContainsActiveLevel ? .on : .off
                containsActiveLevel = containsActiveLevel || submenuContainsActiveLevel
                continue
            }

            guard let selection = item.representedObject as? ThinkingMenuSelection else { continue }
            let isActiveLevel = selection.level == thinkingLevel(for: selection.scope)
            item.state = isActiveLevel ? .on : .off
            containsActiveLevel = containsActiveLevel || isActiveLevel
        }
        return containsActiveLevel
    }

    private func updateModelScopeTitles(in menu: NSMenu) {
        for item in menu.items {
            if let raw = item.representedObject as? String,
               let scope = ModelUseScope(rawValue: raw) {
                item.title = scope.menuTitle(for: LLMModel.option(id: modelID(for: scope)))
            }
            if let submenu = item.submenu {
                updateModelScopeTitles(in: submenu)
            }
        }
    }

    @discardableResult
    private func updateModelSelectionState(in menu: NSMenu) -> Bool {
        var containsActiveModel = false
        for item in menu.items {
            if let submenu = item.submenu {
                let submenuContainsActiveModel = updateModelSelectionState(in: submenu)
                item.state = submenuContainsActiveModel ? .on : .off
                containsActiveModel = containsActiveModel || submenuContainsActiveModel
                continue
            }

            guard let selection = item.representedObject as? ModelMenuSelection else { continue }
            let isActiveModel = selection.modelID == modelID(for: selection.scope)
            item.state = isActiveModel ? .on : .off
            containsActiveModel = containsActiveModel || isActiveModel
        }
        return containsActiveModel
    }

    private func applyShortcut(for action: GlobalShortcutAction, to item: NSMenuItem) {
        let shortcut = shortcut(for: action)
        item.keyEquivalent = shortcut.menuKeyEquivalent
        item.keyEquivalentModifierMask = shortcut.keyEquivalentModifierMask
    }

    private func updateKeyboardShortcutsMenu(_ menu: NSMenu) {
        for item in menu.items {
            if let raw = item.representedObject as? String,
               let action = GlobalShortcutAction(rawValue: raw) {
                let shortcut = shortcut(for: action)
                item.title = "\(action.menuTitle): \(shortcut.displayString)"
            } else if item.action == #selector(resetKeyboardShortcuts) {
                item.isEnabled = GlobalShortcutAction.allCases.contains {
                    shortcut(for: $0) != $0.defaultShortcut
                }
            }
        }
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @MainActor
    @objc private func openOnboardingWindow() {
        presentOnboardingWindow()
    }

    @MainActor
    @objc private func openPermissionsOnboardingWindow() {
        presentPermissionsWindow(force: true)
    }

    @MainActor
    @objc private func openSnippetsWindow() {
        if let snippetsWindowController {
            snippetsWindowController.presentAndFocus()
            return
        }
        let controller = SnippetsWindowController(store: snippetsStore) { [weak self] in
            self?.snippetsWindowController = nil
        }
        snippetsWindowController = controller
        controller.presentAndFocus()
    }

    @MainActor
    @objc private func translateScreenshotAreaFromMenu() {
        startScreenshotTranslation()
    }

    @MainActor
    @objc private func translateSelectedTextFromMenu() {
        startSelectedTextTranslationForReplacement()
    }

    @objc private func translateOrReplySelectionFromMenu() {
        startSelectionTranslateOrReply()
    }

    @objc private func contactSupport() {
        let metadata = supportMetadata()
        let confirmation = NSAlert()
        confirmation.messageText = "Open a support email draft?"
        confirmation.informativeText = "Nugumi will open Gmail with editable diagnostics in the draft body. Review, edit, or delete anything before sending.\n\n\(metadata)"
        confirmation.alertStyle = .informational
        confirmation.addButton(withTitle: "Open Draft")
        confirmation.addButton(withTitle: "Cancel")

        guard confirmation.runModal() == .alertFirstButtonReturn else {
            return
        }

        let subject = "Nugumi bug or request"
        let body = """
        Hey Vadim,

        <tell me about your bug or request>

        --

        \(metadata)
        """

        var components = URLComponents(string: "https://mail.google.com/mail/")!
        components.queryItems = [
            URLQueryItem(name: "view", value: "cm"),
            URLQueryItem(name: "fs", value: "1"),
            URLQueryItem(name: "to", value: "tsoivadim97@gmail.com"),
            URLQueryItem(name: "su", value: subject),
            URLQueryItem(name: "body", value: body)
        ]

        if let url = components.url, NSWorkspace.shared.open(url) {
            return
        }

        let errorAlert = NSAlert()
        errorAlert.messageText = "Could not open Gmail"
        errorAlert.informativeText = "Please email Vadim directly at tsoivadim97@gmail.com."
        errorAlert.alertStyle = .warning
        errorAlert.runModal()
    }

    private func supportMetadata() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let architecture = nativeArchitecture
        let screenCount = NSScreen.screens.count

        return """
        App: Nugumi \(version)
        Build: \(build)
        macOS: \(osVersion)
        Mac: \(hardwareModel()) (\(architecture))
        Number of screens: \(screenCount)
        Triggered from: menu bar
        """
    }

    private var nativeArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown Mac"
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            return "unknown Mac"
        }

        return String(cString: buffer)
    }

    @MainActor
    private func startSelectionTranslateOrReply() {
        guard accessibilityIsTrusted() else {
            requestAccessibilityPermissionIfNeeded()
            presentPermissionsWindowIfNeeded()
            return
        }

        translateButtonController?.close()
        translateButtonController = nil
        petController?.clearReady()
        cancelPrefetch()

        let mode = floatingDefaultMode

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }

            self.selectionReader.readSelectedTextContext(allowClipboardFallback: true) { [weak self] selection in
                guard let self else { return }

                let shortcutDisplay = self.shortcut(for: .translateOrReply).displayString

                guard let selection else {
                    self.presentSelectionTranslationError("Select text first, then press \(shortcutDisplay).")
                    return
                }

                let mouseLocation = NSEvent.mouseLocation
                let panelSide = self.panelSideForSelectionEnding(at: mouseLocation)

                switch mode {
                case .smartReply:
                    let cleaned = TextNormalizer.cleanedSelection(selection.text)
                    guard !cleaned.isEmpty else {
                        self.presentSelectionTranslationError("Select text first, then press \(shortcutDisplay).")
                        return
                    }
                    self.replyToSelection(
                        cleaned,
                        near: mouseLocation,
                        selectionRect: selection.selectionRect,
                        panelSide: panelSide
                    )
                case .translate:
                    let cleaned = TextNormalizer.cleanedSelection(selection.text)
                    guard !cleaned.isEmpty else {
                        self.presentSelectionTranslationError("Select text first, then press \(shortcutDisplay).")
                        return
                    }
                    self.translate(
                        cleaned,
                        near: mouseLocation,
                        mode: .selection,
                        usageKind: .selection,
                        selectionRect: selection.selectionRect,
                        panelSide: panelSide
                    )
                }
            }
        }
    }

    @MainActor
    private func startSelectedTextTranslationForReplacement() {
        guard accessibilityIsTrusted() else {
            requestAccessibilityPermissionIfNeeded()
            presentPermissionsWindowIfNeeded()
            return
        }

        cancelPrefetch()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }

            self.selectionReader.readSelectedTextContext(allowClipboardFallback: true) { [weak self] selection in
                guard let self else { return }

                guard let selection else {
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    self.petController?.clearReady()
                    self.presentSelectionTranslationError("Select text first, then press \(self.shortcut(for: .translateSelection).displayString).")
                    return
                }

                let cleanedDraft = TextNormalizer.cleanedDraftMessage(selection.text)
                guard !cleanedDraft.isEmpty else {
                    self.translateButtonController?.close()
                    self.translateButtonController = nil
                    self.petController?.clearReady()
                    self.presentSelectionTranslationError("Select text first, then press \(self.shortcut(for: .translateSelection).displayString).")
                    return
                }

                let mouseLocation = NSEvent.mouseLocation
                self.rewriteSelectedDraftText(
                    cleanedDraft,
                    near: mouseLocation,
                    selectionRect: selection.selectionRect,
                    panelSide: self.panelSideForSelectionEnding(at: mouseLocation),
                    keepPetReadyUntilPanelCloses: true
                )
            }
        }
    }

    @MainActor
    private func runInstantTranslation(_ text: String, language: TranslationLanguage, near screenPoint: NSPoint) {
        if let setupError = translationErrorIfBootstrapNeedsSetup() {
            handleTranslationFailure(setupError)
            return
        }

        if let busyError = translationErrorIfBootstrapBusy() {
            presentSelectionTranslationError(
                busyError.localizedDescription,
                title: "Translator is still downloading"
            )
            return
        }

        let currentThinkingLevel = textThinkingLevel
        let (_, currentAppCategory) = AppCategoryClassifier.detectFrontmost()
        let currentComposition = compositionSettings(for: .draftMessage, appCategory: currentAppCategory)

        let loadingBar = showInstantTranslationLoading(near: screenPoint)

        let client = currentBackend
        Task { [weak self] in
            do {
                let translated = try await client.translate(
                    text,
                    images: [],
                    to: language,
                    mode: .draftMessage,
                    appCategory: currentAppCategory,
                    composition: currentComposition,
                    thinkingLevel: currentThinkingLevel
                ) { _ in }
                await MainActor.run {
                    guard let self else { return }
                    self.usageStatsStore.recordUse(
                        sourceText: text,
                        resultText: translated,
                        kind: .draftMessage,
                        targetLanguage: language
                    )
                    self.analyticsClient.trackCompletedUsage(
                        kind: .draftMessage,
                        targetLanguageID: language.id,
                        modelID: self.textModelID
                    )
                    self.hideInstantTranslationLoading(loadingBar)
                    self.replaceCurrentSelection(with: translated)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.hideInstantTranslationLoading(loadingBar)
                    let routedToOnboarding = self.handleTranslationFailure(error)
                    if !routedToOnboarding {
                        self.analyticsClient.track(.errorOccurred, properties: [
                            "error_type": Self.analyticsErrorType(error),
                            "error_context": "instant_rewrite"
                        ])
                        self.presentSelectionTranslationError(
                            error.localizedDescription,
                            title: "Translation failed"
                        )
                    }
                }
            }
        }
    }

    @MainActor
    private func showInstantTranslationLoading(near screenPoint: NSPoint) -> FloatingTranslateButtonController? {
        switch selectionDisplayMode {
        case .pet:
            if petController == nil {
                petController = PetController(initialMode: .draftMessage)
            }
            petController?.showThinking()
            return nil
        case .floatingBar:
            // Reuse the bar that's already on screen so it morphs in place
            // instead of flickering — its panel stays at the same origin.
            let bar: FloatingTranslateButtonController
            if let existing = translateButtonController {
                bar = existing
                translateButtonController = nil
            } else {
                bar = FloatingTranslateButtonController(
                    screenPoint: screenPoint,
                    selectedText: "",
                    initialMode: .selection,
                    onTranslate: { _ in },
                    onRewrite: { _ in },
                    onSmartReply: { _ in }
                )
                bar.show()
            }
            bar.setLoading()
            floatingLoadingBar?.close()
            floatingLoadingBar = bar
            return bar
        case .off:
            return nil
        }
    }

    @MainActor
    private func hideInstantTranslationLoading(_ loadingBar: FloatingTranslateButtonController?) {
        petController?.clearThinking()
        guard let loadingBar else { return }
        loadingBar.close()
        if floatingLoadingBar === loadingBar {
            floatingLoadingBar = nil
        }
    }

    @MainActor
    private func replaceCurrentSelection(with translation: String) {
        let cleanTranslation = TextNormalizer.cleanedTranslation(translation)
        guard !cleanTranslation.isEmpty else {
            return
        }

        let sourcePID = lastReplacementSourcePID
        lastReplacementSourcePID = nil

        // Tear down panel + interceptors first so they can't intercept the
        // synthesized Cmd+V or leave the source app's text view in a stale
        // resign-key state.
        translationPanelController?.close()
        translationPanelController = nil

        let performPaste: @MainActor () -> Void = { [weak self] in
            PasteboardTextInserter.replaceCurrentSelection(with: cleanTranslation)
            self?.usageStatsStore.recordReplacement(text: cleanTranslation)
        }

        if let pid = sourcePID, let runningApp = NSRunningApplication(processIdentifier: pid) {
            // Always reactivate source — even if frontmost == source — because
            // some apps (notably Electron-based ones) drop their text view's
            // selection when their window briefly resigned key while the panel
            // was up.
            runningApp.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                performPaste()
            }
        } else {
            performPaste()
        }
    }

    @MainActor
    private func startScreenshotTranslation() {
        guard !isScreenshotTranslationRunning else {
            return
        }

        isScreenshotTranslationRunning = true
        startScreenshotDragTracking()
        updateMenuState()
        translateButtonController?.close()
        translateButtonController = nil
        petController?.clearReady()
        translationPanelController?.close()
        translationPanelController = nil
        cancelPrefetch()

        Task { [weak self] in
            do {
                let screenshotURL = try await ScreenshotCapture.captureInteractiveArea()
                defer {
                    try? FileManager.default.removeItem(at: screenshotURL)
                }

                let recognizedText = try await ImageTextRecognizer.recognizeText(in: screenshotURL)
                await MainActor.run {
                    guard let self else { return }
                    self.isScreenshotTranslationRunning = false
                    self.updateMenuState()

                    let sourceText = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !TextNormalizer.cleanedSelection(sourceText).isEmpty else {
                        self.resetScreenshotDragTracking()
                        self.presentScreenshotTranslationError(ScreenshotTranslationError.noTextRecognized)
                        return
                    }

                    let mouseLocation = NSEvent.mouseLocation
                    let panelSide = self.panelSideForScreenshotEnding(at: mouseLocation)
                    self.resetScreenshotDragTracking()
                    let mode = self.floatingDefaultMode.translationMode
                    let language = self.targetLanguage
                    let usageKind: UsageStatsEventKind
                    switch mode {
                    case .smartReply:
                        usageKind = .smartReply
                    case .selection, .draftMessage:
                        usageKind = .screenArea
                    }
                    self.translate(
                        sourceText,
                        near: mouseLocation,
                        targetLanguage: language,
                        mode: mode,
                        useCache: mode == .selection,
                        usageKind: usageKind,
                        panelSide: panelSide,
                        keepPetReadyUntilPanelCloses: true
                    )
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isScreenshotTranslationRunning = false
                    self.resetScreenshotDragTracking()
                    self.updateMenuState()
                    guard !ScreenshotTranslationError.isCancellation(error) else {
                        return
                    }
                    self.presentScreenshotTranslationError(error)
                }
            }
        }
    }

    @MainActor
    private func presentScreenshotTranslationError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)

        if let screenshotError = error as? ScreenshotTranslationError,
           case .screenRecordingPermissionDenied = screenshotError {
            let response = NugumiAlertController(
                title: "Screen recording required",
                message: screenshotError.localizedDescription,
                primaryButtonTitle: "Open settings",
                secondaryButtonTitle: "Quit Nugumi"
            ).showModal()
            switch response {
            case .alertFirstButtonReturn:
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                NSWorkspace.shared.open(url)
            case .alertSecondButtonReturn:
                NSApp.terminate(nil)
            default:
                break
            }
            return
        }

        _ = NugumiAlertController(
            title: "Screenshot translation failed",
            message: error.localizedDescription,
            primaryButtonTitle: "OK"
        ).showModal()
    }

    @MainActor
    private func presentSelectionTranslationError(_ message: String, title: String = "No text selected") {
        NSApp.activate(ignoringOtherApps: true)
        _ = NugumiAlertController(
            title: title,
            message: message,
            primaryButtonTitle: "OK"
        ).showModal()
    }

    @MainActor
    @objc private func selectTargetLanguage(_ sender: NSMenuItem) {
        guard let languageID = sender.representedObject as? String else {
            return
        }

        targetLanguage = TranslationLanguage.language(id: languageID)
        cancelPrefetch()
        translationPanelController?.close()
        translationPanelController = nil
        updateMenuState()
    }

    @MainActor
    @objc private func selectDraftTargetLanguage(_ sender: NSMenuItem) {
        guard let languageID = sender.representedObject as? String else {
            return
        }

        draftTargetLanguage = TranslationLanguage.language(id: languageID)
        translationPanelController?.close()
        translationPanelController = nil
        updateMenuState()
    }

    @MainActor
    @objc private func selectFloatingDefaultMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = FloatingButtonDefaultMode(rawValue: raw)
        else {
            return
        }

        floatingDefaultMode = mode
        petController?.setActionMode(mode.translationMode)
        refreshStatusBarIcon()
        updateMenuState()
    }

    @MainActor
    @objc private func selectSelectionDisplayMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = SelectionDisplayMode(rawValue: raw)
        else {
            return
        }

        selectionDisplayMode = mode
        applySelectionDisplayMode()
    }

    @MainActor
    @objc private func selectThinkingLevel(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? ThinkingMenuSelection else {
            return
        }

        guard selection.level != thinkingLevel(for: selection.scope) else {
            return
        }

        setThinkingLevel(selection.level, for: selection.scope)
        if selection.scope == .textActions {
            cancelPrefetch()
        }
        updateMenuState()
    }

    @MainActor
    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? ModelMenuSelection else {
            return
        }

        let option = LLMModel.option(id: selection.modelID)
        guard option.id != modelID(for: selection.scope) else {
            return
        }

        if let provider = option.cloudProvider, KeychainStore.apiKey(for: provider) == nil {
            presentAPIKeySheet(for: provider) { [weak self] saved in
                guard let self, saved else { return }
                self.applyModelSelection(option.id, for: selection.scope)
            }
            return
        }

        applyModelSelection(option.id, for: selection.scope)
    }

    @MainActor
    private func runCloudTest(for provider: CloudProvider) async -> CloudTestResult {
        guard let model = LLMModel.all.first(where: { $0.cloudProvider == provider }) else {
            return .failure("No model registered for \(provider.displayName).")
        }
        guard let apiKey = KeychainStore.apiKey(for: provider), !apiKey.isEmpty else {
            return .failure("No API key saved.")
        }
        let client = OpenAIChatClient(provider: provider, apiKey: apiKey, model: model.id)
        do {
            let translated = try await client.translate(
                "Hello, this is a test sentence.",
                images: [],
                to: targetLanguage,
                mode: .selection,
                appCategory: .other,
                composition: nil,
                thinkingLevel: textThinkingLevel,
                onPartial: { _ in }
            )
            let preview = String(translated.prefix(160))
            return .success(preview: "Model: \(model.shortName)\n\n\(preview)")
        } catch let error as TranslationError {
            return .failure(error.errorDescription ?? "Unknown error.")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    @MainActor
    private func applyModelSelection(_ modelID: String, for scope: ModelUseScope) {
        setModelID(modelID, for: scope)
        analyticsClient.track(.modelChanged, properties: [
            "model_id": modelID,
            "model_scope": scope.rawValue
        ])
        cancelPrefetch()
        translationCache = TranslationCache()
        onModelSelectionChanged(for: scope)
        updateMenuState()
    }

    @MainActor
    private func presentAPIKeySheet(for provider: CloudProvider, errorMessage: String? = nil, onSave: @escaping (Bool) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let baseMessage = "Your key is stored locally on this Mac. Nugumi sends your selected text to \(provider.displayName) for translation."
        let fullMessage = errorMessage.map { "⚠️ \($0)\n\n\(baseMessage)" } ?? baseMessage
        let controller = NugumiInputAlertController(
            title: "Enter your \(provider.displayName) API key",
            message: fullMessage,
            placeholder: "sk-...",
            initialValue: KeychainStore.apiKey(for: provider),
            primaryButtonTitle: "Save",
            secondaryButtonTitle: "Get a key…",
            tertiaryButtonTitle: "Cancel"
        )
        let result = controller.showModal()
        switch result.response {
        case .alertFirstButtonReturn:
            guard !result.text.isEmpty else {
                onSave(false)
                return
            }
            Task { @MainActor in
                let outcome = await APIKeyValidator.validate(result.text, for: provider)
                switch outcome {
                case .valid:
                    KeychainStore.setAPIKey(result.text, for: provider)
                    self.bootstrap.refresh()
                    onSave(true)
                case .invalid(let reason):
                    self.presentAPIKeySheet(for: provider, errorMessage: reason, onSave: onSave)
                case .networkUnreachable(let detail):
                    // Network problem — save anyway so user isn't stuck offline.
                    KeychainStore.setAPIKey(result.text, for: provider)
                    self.bootstrap.refresh()
                    self.presentSelectionTranslationError("Couldn't reach \(provider.displayName) to verify the key (\(detail)). Saved it locally.", title: "Key saved without verification")
                    onSave(true)
                }
            }
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(provider.apiKeyHelpURL)
            onSave(false)
        default:
            onSave(false)
        }
    }

    @MainActor
    @objc private func selectWritingStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let category = AppCategory(rawValue: parts[0]),
              let style = WritingStyle(rawValue: parts[1])
        else { return }
        setWritingStyle(style, for: category)
        updateMenuState()
    }

    @MainActor
    @objc private func selectCleanupLevel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let level = CleanupLevel(rawValue: raw)
        else { return }
        cleanupLevel = level
        updateMenuState()
    }

    @MainActor
    @objc private func selectReplacementMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ReplacementMode(rawValue: raw)
        else { return }
        replacementMode = mode
        updateMenuState()
    }

    @MainActor
    @objc private func recordKeyboardShortcut(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = GlobalShortcutAction(rawValue: raw)
        else { return }

        doubleControlDetector?.isEnabled = false
        shortcutRecorderWindowController?.close()
        let controller = ShortcutRecorderWindowController(
            action: action,
            currentShortcut: shortcut(for: action),
            onShortcut: { [weak self] shortcut in
                self?.setKeyboardShortcut(shortcut, for: action) ?? false
            },
            onClose: { [weak self] in
                self?.doubleControlDetector?.isEnabled = true
                self?.shortcutRecorderWindowController = nil
            }
        )
        shortcutRecorderWindowController = controller
        controller.present()
    }

    @MainActor
    private func setKeyboardShortcut(_ shortcut: GlobalShortcut, for action: GlobalShortcutAction) -> Bool {
        for otherAction in GlobalShortcutAction.allCases where otherAction != action {
            if self.shortcut(for: otherAction) == shortcut {
                return false
            }
        }

        GlobalShortcutStore.set(shortcut, for: action)
        setupGlobalHotKeys()
        updateMenuState()
        return true
    }

    @MainActor
    @objc private func resetKeyboardShortcuts() {
        GlobalShortcutStore.resetToDefaults()
        setupGlobalHotKeys()
        updateMenuState()
    }

    @MainActor
    @objc private func resetSettings() {
        let response = NugumiAlertController(
            title: "Reset settings?",
            message: "This restores languages, main mode, display, output, AI mode, and keyboard shortcuts. Snippets, dictionary, and usage stats stay unchanged.",
            primaryButtonTitle: "Reset",
            secondaryButtonTitle: "Cancel"
        ).showModal()
        guard response == .alertFirstButtonReturn else {
            return
        }

        resetSettingsToDefaults()
    }

    @MainActor
    private func resetSettingsToDefaults() {
        let previousTextModelID = textModelID
        let previousAskModelID = askNugumiModelID
        let defaults = UserDefaults.standard
        [
            "targetLanguageID",
            "draftTargetLanguageID",
            "floatingButtonDefaultMode",
            "selectionDisplayMode",
            ModelUseScope.textActions.defaultsKey,
            ModelUseScope.askNugumi.defaultsKey,
            ModelUseScope.textActions.thinkingDefaultsKey,
            ModelUseScope.askNugumi.thinkingDefaultsKey,
            "selectedOllamaModel",
            "thinkingLevel",
            "cleanupLevel",
            "replacementMode",
            InvisibilityState.defaultsKey,
            InvisibilityState.firstRunShownKey,
            usageStatsExpandedKey
        ].forEach { defaults.removeObject(forKey: $0) }

        for category in AppCategory.allCases {
            defaults.removeObject(forKey: "writingStyle.\(category.rawValue)")
        }

        GlobalShortcutStore.resetToDefaults(defaults: defaults)
        shortcutRecorderWindowController?.close()
        cancelPrefetch()
        translationCache = TranslationCache()
        translationPanelController?.close()
        translationPanelController = nil
        petController?.setActionMode(floatingDefaultMode.translationMode)
        refreshStatusBarIcon()
        applySelectionDisplayMode()
        setupGlobalHotKeys()
        statusItem?.isVisible = true
        InvisibilityState.applyToAllOpenWindows()

        if textModelID != previousTextModelID {
            onModelSelectionChanged(for: .textActions)
        }
        if askNugumiModelID != previousAskModelID {
            onModelSelectionChanged(for: .askNugumi)
        }

        updateMenuState()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @MainActor
    @objc private func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
}

extension NugumiApp: SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        "https://raw.githubusercontent.com/ChoiVadim/nugumi/main/appcast.xml"
    }
}

@MainActor
private final class NugumiModalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command {
            switch event.charactersIgnoringModifiers {
            case "v":
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
            case "c":
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
            case "x":
                if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
            case "a":
                if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self) { return true }
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class NugumiInputAlertController: NSWindowController, NSWindowDelegate {
    private static let horizontalPadding: CGFloat = 18
    private static let verticalPadding: CGFloat = 18
    private static let shadowMargin: CGFloat = 30
    private static let cornerRadius: CGFloat = 28
    private static let mascotSize = NSSize(width: 42, height: 34)
    private static let textGap: CGFloat = 10
    private static let fieldHeight: CGFloat = 30
    private static let buttonHeight: CGFloat = 30
    private static let buttonStackSpacing: CGFloat = 8
    private static let textColumnWidth: CGFloat = 320
    private static let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private static let messageFont = NSFont.systemFont(ofSize: 12, weight: .regular)

    struct Result {
        let response: NSApplication.ModalResponse
        let text: String
    }

    private var textField: NSTextField!
    private(set) var enteredText: String = ""

    private let title_: String
    private let message: String
    private let placeholder: String
    private let initialValue: String?
    private let isSecure: Bool
    private let primaryButtonTitle: String
    private let secondaryButtonTitle: String?
    private let tertiaryButtonTitle: String?

    init(
        title: String,
        message: String,
        placeholder: String,
        initialValue: String? = nil,
        isSecure: Bool = true,
        primaryButtonTitle: String,
        secondaryButtonTitle: String? = nil,
        tertiaryButtonTitle: String? = nil
    ) {
        self.title_ = title
        self.message = message
        self.placeholder = placeholder
        self.initialValue = initialValue
        self.isSecure = isSecure
        self.primaryButtonTitle = primaryButtonTitle
        self.secondaryButtonTitle = secondaryButtonTitle
        self.tertiaryButtonTitle = tertiaryButtonTitle

        let cardSize = Self.cardSize(
            title: title,
            message: message,
            buttons: [primaryButtonTitle, secondaryButtonTitle, tertiaryButtonTitle].compactMap { $0 }
        )
        let windowSize = NSSize(
            width: cardSize.width + Self.shadowMargin * 2,
            height: cardSize.height + Self.shadowMargin * 2
        )
        let panel = NugumiModalPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true

        super.init(window: panel)
        panel.delegate = self
        buildUI(panel: panel, windowSize: windowSize, cardSize: cardSize)
    }

    required init?(coder: NSCoder) { nil }

    func showModal() -> Result {
        guard let window else { return Result(response: .cancel, text: "") }
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textField)
        let response = NSApp.runModal(for: window)
        return Result(response: response, text: enteredText)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            NSApp.stopModal(withCode: .cancel)
        }
    }

    private func buildUI(panel: NSPanel, windowSize: NSSize, cardSize: NSSize) {
        let rootView = NSView(frame: NSRect(origin: .zero, size: windowSize))
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.layer?.masksToBounds = false
        panel.contentView = rootView

        let glass = GlassHostView(
            frame: NSRect(origin: NSPoint(x: Self.shadowMargin, y: Self.shadowMargin), size: cardSize),
            cornerRadius: Self.cornerRadius,
            tintColor: nil,
            style: .regular
        )
        glass.wantsLayer = true
        glass.layer?.masksToBounds = false
        glass.layer?.shadowColor = NSColor.black.cgColor
        glass.layer?.shadowOpacity = 0.24
        glass.layer?.shadowRadius = 18
        glass.layer?.shadowOffset = CGSize(width: 0, height: -4)
        glass.layer?.shadowPath = CGPath(
            roundedRect: NSRect(origin: .zero, size: cardSize),
            cornerWidth: Self.cornerRadius,
            cornerHeight: Self.cornerRadius,
            transform: nil
        )
        glass.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(glass)
        let contentView = glass.contentView

        let mascotColumn = NSView()
        mascotColumn.translatesAutoresizingMaskIntoConstraints = false

        let mascotView = PetMascotView(frame: NSRect(origin: .zero, size: Self.mascotSize))
        mascotView.apply(state: .idle, mode: .selection)
        mascotView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title_)
        titleLabel.font = Self.titleFont
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = Self.messageFont
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 0
        messageLabel.preferredMaxLayoutWidth = Self.textColumnWidth
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        let field: NSTextField = isSecure ? NSSecureTextField() : NSTextField()
        field.placeholderString = placeholder
        if let initialValue { field.stringValue = initialValue }
        field.font = NSFont.systemFont(ofSize: 13)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.cell?.lineBreakMode = .byTruncatingTail
        textField = field

        let buttonStack = NSStackView()
        buttonStack.orientation = .vertical
        buttonStack.alignment = .centerX
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = Self.buttonStackSpacing
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        var buttons: [NSButton] = []
        let primary = makeButton(title: primaryButtonTitle, action: #selector(primaryTapped))
        buttonStack.addArrangedSubview(primary)
        buttons.append(primary)
        if let secondaryButtonTitle {
            let secondary = makeButton(title: secondaryButtonTitle, action: #selector(secondaryTapped))
            buttonStack.addArrangedSubview(secondary)
            buttons.append(secondary)
        }
        if let tertiaryButtonTitle {
            let tertiary = makeButton(title: tertiaryButtonTitle, action: #selector(tertiaryTapped))
            buttonStack.addArrangedSubview(tertiary)
            buttons.append(tertiary)
        }

        contentView.addSubview(mascotColumn)
        mascotColumn.addSubview(mascotView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(messageLabel)
        contentView.addSubview(field)
        contentView.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: rootView.topAnchor, constant: Self.shadowMargin),
            glass.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: Self.shadowMargin),
            glass.widthAnchor.constraint(equalToConstant: cardSize.width),
            glass.heightAnchor.constraint(equalToConstant: cardSize.height),

            mascotColumn.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.verticalPadding),
            mascotColumn.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.horizontalPadding),
            mascotColumn.widthAnchor.constraint(equalToConstant: Self.mascotSize.width),
            mascotColumn.heightAnchor.constraint(equalToConstant: Self.mascotSize.height),

            mascotView.centerXAnchor.constraint(equalTo: mascotColumn.centerXAnchor),
            mascotView.centerYAnchor.constraint(equalTo: mascotColumn.centerYAnchor),
            mascotView.widthAnchor.constraint(equalToConstant: Self.mascotSize.width),
            mascotView.heightAnchor.constraint(equalToConstant: Self.mascotSize.height),

            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.verticalPadding + 1),
            titleLabel.leadingAnchor.constraint(equalTo: mascotColumn.trailingAnchor, constant: Self.textGap),
            titleLabel.widthAnchor.constraint(equalToConstant: Self.textColumnWidth),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            messageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            field.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            field.heightAnchor.constraint(equalToConstant: Self.fieldHeight),

            buttonStack.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            buttonStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Self.verticalPadding)
        ])

        for button in buttons {
            NSLayoutConstraint.activate([
                button.heightAnchor.constraint(equalToConstant: Self.buttonHeight),
                button.widthAnchor.constraint(equalTo: buttonStack.widthAnchor)
            ])
        }
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        button.focusRingType = .none
        return button
    }

    @objc private func primaryTapped() {
        enteredText = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        close(with: .alertFirstButtonReturn)
    }

    @objc private func secondaryTapped() {
        enteredText = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        close(with: .alertSecondButtonReturn)
    }

    @objc private func tertiaryTapped() {
        close(with: .alertThirdButtonReturn)
    }

    private func close(with response: NSApplication.ModalResponse) {
        NSApp.stopModal(withCode: response)
        window?.orderOut(nil)
    }

    private static func cardSize(title: String, message: String, buttons: [String]) -> NSSize {
        let titleHeight = ceil(titleFont.boundingRectForFont.height)
        let messageHeight = ceil((message as NSString).boundingRect(
            with: NSSize(width: textColumnWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: messageFont]
        ).height)
        let buttonsBlock = CGFloat(buttons.count) * buttonHeight
            + CGFloat(max(0, buttons.count - 1)) * buttonStackSpacing
        let inner = titleHeight + 4 + messageHeight + 12 + fieldHeight + 12 + buttonsBlock
        let height = verticalPadding * 2 + max(mascotSize.height, inner)
        let width = horizontalPadding * 2 + mascotSize.width + textGap + textColumnWidth
        return NSSize(width: ceil(width), height: ceil(height))
    }
}

final class NugumiAlertController: NSWindowController, NSWindowDelegate {
    private static let horizontalPadding: CGFloat = 16
    private static let verticalPadding: CGFloat = 16
    private static let shadowMargin: CGFloat = 30
    private static let cornerRadius: CGFloat = 28
    private static let mascotSize = NSSize(width: 42, height: 34)
    private static let textGap: CGFloat = 10
    private static let minTextWidth: CGFloat = 168
    private static let maxTextWidth: CGFloat = 300
    private static let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private static let messageFont = NSFont.systemFont(ofSize: 12, weight: .regular)

    private struct AlertLayout {
        let cardSize: NSSize
        let textWidth: CGFloat
    }

    init(
        title: String,
        message: String,
        primaryButtonTitle: String,
        secondaryButtonTitle: String? = nil
    ) {
        let layout = Self.layout(
            title: title,
            message: message,
            primaryButtonTitle: primaryButtonTitle,
            secondaryButtonTitle: secondaryButtonTitle
        )
        let windowSize = NSSize(
            width: layout.cardSize.width + Self.shadowMargin * 2,
            height: layout.cardSize.height + Self.shadowMargin * 2
        )
        let panel = NugumiModalPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true

        super.init(window: panel)
        panel.delegate = self
        buildUI(
            in: panel,
            windowSize: windowSize,
            layout: layout,
            title: title,
            message: message,
            primaryButtonTitle: primaryButtonTitle,
            secondaryButtonTitle: secondaryButtonTitle
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    func showModal() -> NSApplication.ModalResponse {
        guard let window else { return .cancel }
        window.center()
        window.makeKeyAndOrderFront(nil)
        return NSApp.runModal(for: window)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            NSApp.stopModal(withCode: .cancel)
        }
    }

    private func buildUI(
        in panel: NSPanel,
        windowSize: NSSize,
        layout: AlertLayout,
        title: String,
        message: String,
        primaryButtonTitle: String,
        secondaryButtonTitle: String?
    ) {
        let rootView = NSView(frame: NSRect(origin: .zero, size: windowSize))
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.layer?.masksToBounds = false
        panel.contentView = rootView

        let glass = GlassHostView(
            frame: NSRect(origin: NSPoint(x: Self.shadowMargin, y: Self.shadowMargin), size: layout.cardSize),
            cornerRadius: Self.cornerRadius,
            tintColor: nil,
            style: .regular
        )
        glass.wantsLayer = true
        glass.layer?.masksToBounds = false
        glass.layer?.shadowColor = NSColor.black.cgColor
        glass.layer?.shadowOpacity = 0.24
        glass.layer?.shadowRadius = 18
        glass.layer?.shadowOffset = CGSize(width: 0, height: -4)
        glass.layer?.shadowPath = CGPath(
            roundedRect: NSRect(origin: .zero, size: layout.cardSize),
            cornerWidth: Self.cornerRadius,
            cornerHeight: Self.cornerRadius,
            transform: nil
        )
        glass.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(glass)
        let contentView = glass.contentView

        let mascotColumn = NSView()
        mascotColumn.translatesAutoresizingMaskIntoConstraints = false

        let mascotView = PetMascotView(frame: NSRect(origin: .zero, size: Self.mascotSize))
        mascotView.apply(state: .idle, mode: .selection)
        mascotView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Self.titleFont
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = Self.messageFont
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 0
        messageLabel.preferredMaxLayoutWidth = layout.textWidth
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        let primaryButton = makeButton(title: primaryButtonTitle, action: #selector(primaryTapped))

        contentView.addSubview(mascotColumn)
        mascotColumn.addSubview(mascotView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(messageLabel)
        contentView.addSubview(primaryButton)

        var constraints: [NSLayoutConstraint] = [
            glass.topAnchor.constraint(equalTo: rootView.topAnchor, constant: Self.shadowMargin),
            glass.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: Self.shadowMargin),
            glass.widthAnchor.constraint(equalToConstant: layout.cardSize.width),
            glass.heightAnchor.constraint(equalToConstant: layout.cardSize.height),

            mascotColumn.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.verticalPadding),
            mascotColumn.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.horizontalPadding),
            mascotColumn.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Self.verticalPadding),
            mascotColumn.widthAnchor.constraint(equalToConstant: Self.mascotSize.width),

            mascotView.centerXAnchor.constraint(equalTo: mascotColumn.centerXAnchor),
            mascotView.centerYAnchor.constraint(equalTo: mascotColumn.centerYAnchor),
            mascotView.widthAnchor.constraint(equalToConstant: Self.mascotSize.width),
            mascotView.heightAnchor.constraint(equalToConstant: Self.mascotSize.height),

            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.verticalPadding + 1),
            titleLabel.leadingAnchor.constraint(equalTo: mascotColumn.trailingAnchor, constant: Self.textGap),
            titleLabel.widthAnchor.constraint(equalToConstant: layout.textWidth),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            messageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            primaryButton.heightAnchor.constraint(equalToConstant: 30),
            primaryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.buttonWidth(for: primaryButtonTitle)),
            primaryButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Self.verticalPadding)
        ]

        if let secondaryButtonTitle {
            let secondaryButton = makeButton(title: secondaryButtonTitle, action: #selector(secondaryTapped))
            contentView.addSubview(secondaryButton)
            constraints.append(contentsOf: [
                secondaryButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                secondaryButton.trailingAnchor.constraint(equalTo: primaryButton.leadingAnchor, constant: -8),
                secondaryButton.bottomAnchor.constraint(equalTo: primaryButton.bottomAnchor),
                secondaryButton.heightAnchor.constraint(equalTo: primaryButton.heightAnchor),
                secondaryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.buttonWidth(for: secondaryButtonTitle)),
                secondaryButton.widthAnchor.constraint(equalTo: primaryButton.widthAnchor),

                primaryButton.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor)
            ])
        } else {
            constraints.append(contentsOf: [
                primaryButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                primaryButton.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor)
            ])
        }

        constraints.append(primaryButton.topAnchor.constraint(greaterThanOrEqualTo: messageLabel.bottomAnchor, constant: 12))
        NSLayoutConstraint.activate(constraints)
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        button.focusRingType = .none
        return button
    }

    @objc private func primaryTapped() {
        close(with: .alertFirstButtonReturn)
    }

    @objc private func secondaryTapped() {
        close(with: .alertSecondButtonReturn)
    }

    private func close(with response: NSApplication.ModalResponse) {
        NSApp.stopModal(withCode: response)
        window?.orderOut(nil)
    }

    private static func layout(
        title: String,
        message: String,
        primaryButtonTitle: String,
        secondaryButtonTitle: String?
    ) -> AlertLayout {
        let titleWidth = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width)
        let messageSingleLineWidth = ceil((message as NSString).size(withAttributes: [.font: messageFont]).width)
        let primaryButtonWidth = buttonWidth(for: primaryButtonTitle)
        let buttonWidth: CGFloat
        if let secondaryButtonTitle {
            let secondaryButtonWidth = Self.buttonWidth(for: secondaryButtonTitle)
            buttonWidth = max(primaryButtonWidth, secondaryButtonWidth) * 2 + 8
        } else {
            buttonWidth = primaryButtonWidth
        }

        let textWidth = min(
            max(max(titleWidth, messageSingleLineWidth, buttonWidth), minTextWidth),
            maxTextWidth
        )
        let messageHeight = ceil((message as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: messageFont]
        ).height)
        let textBlockHeight = ceil(titleFont.boundingRectForFont.height) + 4 + messageHeight
        let height = verticalPadding + max(mascotSize.height, textBlockHeight + 12 + 30) + verticalPadding
        let width = horizontalPadding * 2 + mascotSize.width + textGap + textWidth
        return AlertLayout(
            cardSize: NSSize(width: ceil(width), height: max(112, ceil(height))),
            textWidth: textWidth
        )
    }

    private static func buttonWidth(for title: String) -> CGFloat {
        let titleWidth = ceil((title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        ]).width)
        return max(54, titleWidth + 28)
    }
}

struct SelectedTextContext {
    let text: String
    let selectionRect: NSRect?
}

final class SelectionReader {
    func readSelectedText(
        preferClipboard: Bool = false,
        allowClipboardFallback: Bool,
        completion: @escaping (String?) -> Void
    ) {
        readSelectedTextContext(
            preferClipboard: preferClipboard,
            allowClipboardFallback: allowClipboardFallback
        ) { selection in
            completion(selection?.text)
        }
    }

    func readSelectedTextContext(
        preferClipboard: Bool = false,
        allowClipboardFallback: Bool,
        completion: @escaping (SelectedTextContext?) -> Void
    ) {
        if preferClipboard {
            ClipboardSelectionReader.readSelectedText { [weak self] clipboardText in
                if let clipboardText, !clipboardText.isEmpty {
                    completion(SelectedTextContext(text: clipboardText, selectionRect: nil))
                    return
                }
                completion(self?.readSelectedTextContext())
            }
            return
        }

        if let selection = readSelectedTextContext() {
            completion(selection)
            return
        }

        guard allowClipboardFallback else {
            completion(nil)
            return
        }

        ClipboardSelectionReader.readSelectedText { selectedText in
            guard let selectedText else {
                completion(nil)
                return
            }

            completion(SelectedTextContext(text: selectedText, selectionRect: nil))
        }
    }

    func isLikelyEditableElementAtMouseLocation() -> Bool {
        guard let element = elementAtMouseLocation() ?? focusedElement() else {
            return false
        }

        var currentElement: AXUIElement? = element
        for _ in 0..<6 {
            guard let element = currentElement else {
                return false
            }

            if let role = role(of: element), Self.editableTextRoles.contains(role) {
                return true
            }

            currentElement = parent(of: element)
        }

        return false
    }

    func readSelectedText() -> String? {
        readSelectedTextContext()?.text
    }

    func readSelectedTextContext() -> SelectedTextContext? {
        guard let focusedElement = focusedElement() else {
            return nil
        }

        guard let text = selectedText(from: focusedElement) else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let rect = selectedTextRange(from: focusedElement)
            .flatMap { selectionBounds(from: focusedElement, range: $0) }

        return SelectedTextContext(
            text: trimmed,
            selectionRect: rect
        )
    }

    private static let editableTextRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField"
    ]

    private func focusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        guard focusedResult == .success,
              let focusedElement = focusedValue,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (focusedElement as! AXUIElement)
    }

    private func elementAtMouseLocation() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        let mouseLocation = NSEvent.mouseLocation
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(mouseLocation.x),
            Float(mouseLocation.y),
            &element
        )

        guard result == .success else {
            return nil
        }

        return element
    }

    private func role(of element: AXUIElement) -> String? {
        var roleValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        )

        guard result == .success else {
            return nil
        }

        return roleValue as? String
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        var parentValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXParentAttribute as CFString,
            &parentValue
        )

        guard result == .success,
              let parentValue,
              CFGetTypeID(parentValue) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (parentValue as! AXUIElement)
    }

    private func selectedText(from element: AXUIElement) -> String? {
        var selectedTextValue: CFTypeRef?
        let selectedTextResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextValue
        )

        if selectedTextResult == .success, let selectedText = selectedTextValue as? String {
            return selectedText
        }

        return selectedTextViaRange(from: element)
    }

    private func selectedTextViaRange(from element: AXUIElement) -> String? {
        guard let range = selectedTextRange(from: element) else {
            return nil
        }

        var textValue: CFTypeRef?
        let textResult = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &textValue
        )

        guard textResult == .success, let fullText = textValue as? String else {
            return nil
        }

        let utf16 = fullText.utf16
        guard range.location >= 0,
              range.length >= 0,
              range.location + range.length <= utf16.count
        else {
            return nil
        }

        let utf16Start = utf16.index(utf16.startIndex, offsetBy: range.location)
        let utf16End = utf16.index(utf16.startIndex, offsetBy: range.location + range.length)
        guard let start = utf16Start.samePosition(in: fullText),
              let end = utf16End.samePosition(in: fullText)
        else {
            return nil
        }

        return String(fullText[start..<end])
    }

    private func selectedTextRange(from element: AXUIElement) -> CFRange? {
        var rangeValue: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        )

        guard rangeResult == .success,
              let rangeValue,
              CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let axRangeValue = rangeValue as! AXValue
        var range = CFRange()
        guard AXValueGetType(axRangeValue) == .cfRange,
              AXValueGetValue(axRangeValue, .cfRange, &range),
              range.location >= 0,
              range.length > 0
        else {
            return nil
        }

        return range
    }

    private func selectionBounds(from element: AXUIElement, range: CFRange) -> NSRect? {
        var mutableRange = range
        guard let rangeAXValue = AXValueCreate(.cfRange, &mutableRange) else {
            return nil
        }

        var boundsValue: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeAXValue,
            &boundsValue
        )

        guard result == .success,
              let boundsValue,
              CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let axValue = boundsValue as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(axValue) == .cgRect,
              AXValueGetValue(axValue, .cgRect, &rect),
              rect.width > 0, rect.height > 0,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite
        else {
            return nil
        }

        return SelectionReader.convertAXRectToCocoa(rect)
    }

    // AX uses top-left global coordinates; NSScreen uses bottom-left.
    // Build an AX-space frame for each display so selection panels stay near
    // the selected text on horizontal and vertical multi-monitor layouts.
    private static func convertAXRectToCocoa(_ axRect: CGRect) -> NSRect? {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
                ?? NSScreen.screens.first
        else {
            return nil
        }

        let axMidPoint = CGPoint(x: axRect.midX, y: axRect.midY)
        let containingScreen = NSScreen.screens.first { screen in
            axFrame(for: screen, primaryScreen: primary).contains(axMidPoint)
        } ?? primary
        let containingAXFrame = axFrame(for: containingScreen, primaryScreen: primary)
        let flippedY = containingScreen.frame.maxY - (axRect.maxY - containingAXFrame.minY)
        return NSRect(x: axRect.origin.x, y: flippedY, width: axRect.width, height: axRect.height)
    }

    private static func axFrame(for screen: NSScreen, primaryScreen: NSScreen) -> CGRect {
        CGRect(
            x: screen.frame.minX,
            y: primaryScreen.frame.maxY - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
    }

}

enum ClipboardSelectionReader {
    private static let pollingInterval: TimeInterval = 0.02
    private static let pollingTimeout: TimeInterval = 0.5
    private static let lateRestoreGrace: TimeInterval = 0.5

    static func readSelectedText(completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let originalChangeCount = pasteboard.changeCount

        postCommandC()

        let deadline = Date().addingTimeInterval(pollingTimeout)
        pollForPasteboardChange(
            pasteboard: pasteboard,
            originalChangeCount: originalChangeCount,
            deadline: deadline,
            snapshot: snapshot,
            completion: completion
        )
    }

    private static func pollForPasteboardChange(
        pasteboard: NSPasteboard,
        originalChangeCount: Int,
        deadline: Date,
        snapshot: PasteboardSnapshot,
        completion: @escaping (String?) -> Void
    ) {
        if pasteboard.changeCount != originalChangeCount {
            let copiedText = pasteboard.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            snapshot.restore(to: pasteboard)
            let meaningful = copiedText.flatMap { TextNormalizer.looksMeaningful($0) ? $0 : nil }
            completion(meaningful)
            return
        }

        if Date() >= deadline {
            monitorLatePasteboardChange(
                pasteboard: pasteboard,
                originalChangeCount: originalChangeCount,
                deadline: Date().addingTimeInterval(lateRestoreGrace),
                snapshot: snapshot
            )
            completion(nil)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pollingInterval) {
            pollForPasteboardChange(
                pasteboard: pasteboard,
                originalChangeCount: originalChangeCount,
                deadline: deadline,
                snapshot: snapshot,
                completion: completion
            )
        }
    }

    private static func postCommandC() {
        KeyboardShortcutPoster.postCommandShortcut(keyCode: CGKeyCode(kVK_ANSI_C))
    }

    private static func monitorLatePasteboardChange(
        pasteboard: NSPasteboard,
        originalChangeCount: Int,
        deadline: Date,
        snapshot: PasteboardSnapshot
    ) {
        if pasteboard.changeCount != originalChangeCount {
            snapshot.restore(to: pasteboard)
            return
        }

        guard Date() < deadline else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pollingInterval) {
            monitorLatePasteboardChange(
                pasteboard: pasteboard,
                originalChangeCount: originalChangeCount,
                deadline: deadline,
                snapshot: snapshot
            )
        }
    }
}

enum KeyboardShortcutPoster {
    static func postCommandShortcut(keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        postKey(CGKeyCode(kVK_Command), keyDown: true, flags: .maskCommand, source: source)
        postKey(keyCode, keyDown: true, flags: .maskCommand, source: source)
        postKey(keyCode, keyDown: false, flags: .maskCommand, source: source)
        postKey(CGKeyCode(kVK_Command), keyDown: false, flags: [], source: source)
    }

    private static func postKey(
        _ keyCode: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags,
        source: CGEventSource?
    ) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
}

private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let capturedItems = (pasteboard.pasteboardItems ?? []).map { item in
            var capturedTypes: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    capturedTypes[type] = data
                }
            }
            return capturedTypes
        }

        return PasteboardSnapshot(items: capturedItems)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { capturedTypes in
            let item = NSPasteboardItem()
            for (type, data) in capturedTypes {
                item.setData(data, forType: type)
            }
            return item
        }

        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}

enum PasteboardTextInserter {
    static func replaceCurrentSelection(with text: String) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let replacementChangeCount = pasteboard.changeCount

        postCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            guard pasteboard.changeCount == replacementChangeCount else {
                return
            }
            snapshot.restore(to: pasteboard)
        }
    }

    private static func postCommandV() {
        KeyboardShortcutPoster.postCommandShortcut(keyCode: CGKeyCode(kVK_ANSI_V))
    }
}

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
            "Nugumi needs Screen Recording permission to capture screenshots. Open settings to enable it, then choose Quit Nugumi and reopen Nugumi for the change to take effect."
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
            guard let cgImage = CGDisplayCreateImage(screenID) else {
                throw ScreenshotTranslationError.captureFailedDetail("Could not capture the active screen.")
            }

            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
                throw ScreenshotTranslationError.captureFailedDetail("Could not encode the active screen.")
            }

            return (
                image: ImageInput(data: pngData, mediaType: "image/png"),
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

final class TabKeyInterceptor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onTab: @MainActor () -> Void

    init(onTab: @escaping @MainActor () -> Void) {
        self.onTab = onTab
    }

    func enable() {
        guard eventTap == nil else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo, type == .keyDown else {
                    return Unmanaged.passUnretained(event)
                }

                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                guard keyCode == Int64(kVK_Tab) else {
                    return Unmanaged.passUnretained(event)
                }

                let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
                guard event.flags.intersection(modifierMask).isEmpty else {
                    return Unmanaged.passUnretained(event)
                }

                let interceptor = Unmanaged<TabKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
                Task { @MainActor in
                    interceptor.onTab()
                }
                return nil
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
    }

    deinit {
        disable()
    }
}

final class CommandCopyInterceptor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let consumesEvent: Bool
    private let onCopy: @MainActor () -> Void

    init(consumesEvent: Bool = true, onCopy: @escaping @MainActor () -> Void) {
        self.consumesEvent = consumesEvent
        self.onCopy = onCopy
    }

    func enable() {
        guard eventTap == nil else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: consumesEvent ? .defaultTap : .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo, type == .keyDown else {
                    return Unmanaged.passUnretained(event)
                }

                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                guard keyCode == Int64(kVK_ANSI_C) else {
                    return Unmanaged.passUnretained(event)
                }

                let modifiers = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
                guard modifiers == .maskCommand else {
                    return Unmanaged.passUnretained(event)
                }

                let interceptor = Unmanaged<CommandCopyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
                Task { @MainActor in
                    interceptor.onCopy()
                }
                return interceptor.consumesEvent ? nil : Unmanaged.passUnretained(event)
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
    }

    deinit {
        disable()
    }
}

final class ReturnKeyInterceptor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let sourcePID: pid_t
    private let onReturn: @MainActor () -> Void

    init(sourcePID: pid_t, onReturn: @escaping @MainActor () -> Void) {
        self.sourcePID = sourcePID
        self.onReturn = onReturn
    }

    func enable() {
        guard eventTap == nil else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo, type == .keyDown else {
                    return Unmanaged.passUnretained(event)
                }

                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                guard keyCode == Int64(kVK_Return) || keyCode == Int64(kVK_ANSI_KeypadEnter) else {
                    return Unmanaged.passUnretained(event)
                }

                let modifiers = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
                guard modifiers == [] else {
                    return Unmanaged.passUnretained(event)
                }

                let interceptor = Unmanaged<ReturnKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()

                // Only steal Return when the user is still in the source app
                // where the selection lives. Otherwise let it through so it
                // doesn't hijack typing in other apps.
                let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
                guard frontmost == interceptor.sourcePID else {
                    return Unmanaged.passUnretained(event)
                }

                Task { @MainActor in
                    interceptor.onReturn()
                }
                return nil
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
    }

    deinit {
        disable()
    }
}

final class PromptKeyInterceptor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onInsertText: @MainActor (String) -> Void
    private let onBackspace: @MainActor () -> Void
    private let onSubmit: @MainActor () -> Void
    private let onCancel: @MainActor () -> Void
    private let onPaste: @MainActor () -> Void
    private let onSelectAll: @MainActor () -> Void

    init(
        onInsertText: @escaping @MainActor (String) -> Void,
        onBackspace: @escaping @MainActor () -> Void,
        onSubmit: @escaping @MainActor () -> Void,
        onCancel: @escaping @MainActor () -> Void,
        onPaste: @escaping @MainActor () -> Void,
        onSelectAll: @escaping @MainActor () -> Void
    ) {
        self.onInsertText = onInsertText
        self.onBackspace = onBackspace
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self.onPaste = onPaste
        self.onSelectAll = onSelectAll
    }

    func enable() {
        guard eventTap == nil else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo, type == .keyDown else {
                    return Unmanaged.passUnretained(event)
                }

                let interceptor = Unmanaged<PromptKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags
                let hasCommand = flags.contains(.maskCommand)
                let hasControl = flags.contains(.maskControl)
                let hasOption = flags.contains(.maskAlternate)

                if keyCode == Int64(kVK_Escape) {
                    Task { @MainActor in interceptor.onCancel() }
                    return nil
                }

                if keyCode == Int64(kVK_Return) || keyCode == Int64(kVK_ANSI_KeypadEnter) {
                    guard !hasCommand, !hasControl, !hasOption else {
                        return Unmanaged.passUnretained(event)
                    }
                    Task { @MainActor in interceptor.onSubmit() }
                    return nil
                }

                if keyCode == Int64(kVK_Delete) || keyCode == Int64(kVK_ForwardDelete) {
                    guard !hasCommand, !hasControl else {
                        return Unmanaged.passUnretained(event)
                    }
                    Task { @MainActor in interceptor.onBackspace() }
                    return nil
                }

                if hasCommand, keyCode == Int64(kVK_ANSI_V) {
                    Task { @MainActor in interceptor.onPaste() }
                    return nil
                }

                if hasCommand, keyCode == Int64(kVK_ANSI_A) {
                    Task { @MainActor in interceptor.onSelectAll() }
                    return nil
                }

                guard !hasCommand, !hasControl,
                      let nsEvent = NSEvent(cgEvent: event),
                      let characters = nsEvent.characters,
                      !characters.isEmpty,
                      characters.rangeOfCharacter(from: .controlCharacters) == nil
                else {
                    return Unmanaged.passUnretained(event)
                }

                Task { @MainActor in interceptor.onInsertText(characters) }
                return nil
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
    }

    deinit {
        disable()
    }
}

private final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private enum NugumiFont {
    private static let didRegisterPixelifySans: Bool = {
        guard let url = Bundle.module.url(
            forResource: "PixelifySans",
            withExtension: "ttf",
            subdirectory: "Fonts"
        ) else {
            return false
        }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    static func pixelPrompt(size: CGFloat) -> NSFont {
        _ = didRegisterPixelifySans
        return NSFont(name: "PixelifySans-Regular_SemiBold", size: size)
            ?? NSFont(name: "Pixelify Sans", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
    }
}

private final class PetPromptBubbleView: NSView {
    var drawsBubble = true {
        didSet { needsDisplay = true }
    }
    var isError = false {
        didSet { needsDisplay = true }
    }
    var bubbleFrame: NSRect = .zero {
        didSet { needsDisplay = true }
    }
    var targetMarkerPoint: NSPoint? {
        didSet { needsDisplay = true }
    }
    /// Direction (radians) the pixel arrow points — pet → destination.
    var targetMarkerAngle: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    private var targetMarkerFrame = 0

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func advanceTargetMarkerBlink() {
        guard targetMarkerPoint != nil else { return }
        targetMarkerFrame = (targetMarkerFrame + 1) % 60
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = false
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        let unit: CGFloat = 3
        let drawingFrame = bubbleFrame == .zero ? bounds : bubbleFrame
        let bubbleRect = NSRect(
            x: drawingFrame.minX + 5 * unit,
            y: drawingFrame.minY + 3 * unit,
            width: floor((drawingFrame.width - 10 * unit) / unit) * unit,
            height: floor((drawingFrame.height - 7 * unit) / unit) * unit
        )

        let shadow = NSColor(calibratedWhite: 0.0, alpha: 0.22)
        let fill = NSColor(srgbRed: 0.95, green: 0.96, blue: 0.91, alpha: 1.0)
        let highlight = NSColor(calibratedWhite: 1.0, alpha: 0.55)
        let border = isError
            ? NSColor(srgbRed: 0.93, green: 0.23, blue: 0.23, alpha: 1.0)
            : NSColor(srgbRed: 0.42, green: 0.47, blue: 0.47, alpha: 1.0)
        let borderDark = isError
            ? NSColor(srgbRed: 0.54, green: 0.08, blue: 0.08, alpha: 1.0)
            : NSColor(srgbRed: 0.22, green: 0.27, blue: 0.28, alpha: 1.0)

        if drawsBubble {
            drawPixelBubbleBody(in: bubbleRect.offsetBy(dx: unit, dy: -unit), unit: unit, color: shadow)
            let tailAnchor = bubbleRect.minX + 4 * unit
            drawPixelTail(anchor: tailAnchor, baseY: bubbleRect.minY, unit: unit, color: shadow, offset: NSPoint(x: unit, y: -unit))
            drawPixelTail(anchor: tailAnchor, baseY: bubbleRect.minY, unit: unit, color: borderDark)
            drawPixelBubbleBody(in: bubbleRect, unit: unit, color: borderDark)
            drawPixelBubbleBody(in: bubbleRect.insetBy(dx: unit, dy: unit), unit: unit, color: border)
            drawPixelBubbleBody(in: bubbleRect.insetBy(dx: unit * 2, dy: unit * 2), unit: unit, color: fill)

            drawPixelTail(anchor: tailAnchor, baseY: bubbleRect.minY, unit: unit, color: fill, offset: NSPoint(x: unit * 2, y: unit * 2))

            highlight.setFill()
            NSBezierPath(rect: NSRect(
                x: bubbleRect.minX + 4 * unit,
                y: bubbleRect.maxY - 4 * unit,
                width: bubbleRect.width - 8 * unit,
                height: unit
            )).fill()
        }

        if let targetMarkerPoint {
            drawTargetMarker(center: targetMarkerPoint, unit: unit)
        }
    }

    private func drawPixelBubbleBody(in rect: NSRect, unit: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(rect: NSRect(
            x: rect.minX + unit,
            y: rect.minY,
            width: rect.width - unit * 2,
            height: rect.height
        )).fill()
        NSBezierPath(rect: NSRect(
            x: rect.minX,
            y: rect.minY + unit,
            width: rect.width,
            height: rect.height - unit * 2
        )).fill()
    }

    private func drawPixelTail(anchor: CGFloat, baseY: CGFloat, unit: CGFloat, color: NSColor, offset: NSPoint = .zero) {
        color.setFill()
        let cells: [(CGFloat, CGFloat, CGFloat)] = [
            (0, 0, 7),
            (1, -1, 5),
            (2, -2, 3),
            (3, -3, 1)
        ]
        for (x, y, width) in cells {
            NSBezierPath(rect: NSRect(
                x: anchor + offset.x + x * unit,
                y: baseY + offset.y + y * unit,
                width: width * unit,
                height: unit
            )).fill()
        }
    }

    // Arrow sprite, pointing +x (right): rectangular stem on the left, a
    // triangular head tapering to a point on the right. Equal-width rows so
    // it aligns; '#' = fill. Border is synthesized as a 1-cell outline so the
    // pixel edge matches the dialog bubble's dark-bordered look.
    private static let arrowSpriteRows = [
        "....#...",
        "....##..",
        "#######.",
        "########",
        "#######.",
        "....##..",
        "....#...",
    ]
    private static let arrowCoreCell = (col: 1, row: 3) // lighter accent pixel

    private func drawTargetMarker(center: NSPoint, unit: CGFloat) {
        let isBrightFrame = targetMarkerFrame < 34
        // Brighter than the old dot, same footprint.
        let border = NSColor(
            srgbRed: 0.05, green: 0.24, blue: 0.22,
            alpha: isBrightFrame ? 0.98 : 0.82
        )
        let fill = NSColor(
            srgbRed: 17.0 / 255.0,
            green: 118.0 / 255.0,
            blue: 110.0 / 255.0,
            alpha: isBrightFrame ? 1.0 : 0.72
        )
        let core = NSColor(
            srgbRed: 0.90, green: 0.98, blue: 0.96,
            alpha: isBrightFrame ? 0.95 : 0.55
        )
        let shadow = NSColor(calibratedWhite: 0.0, alpha: isBrightFrame ? 0.20 : 0.09)

        // Dedicated unit so the arrow keeps the old dot's ~15px footprint
        // (it must not look bigger) while leaving rotation room in the panel.
        _ = unit
        let arrowUnit: CGFloat = 1.8

        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.rotate(byRadians: targetMarkerAngle)
        transform.concat()
        // Local space: sprite centered on (0,0), now rotated toward target.
        drawArrowSprite(unit: arrowUnit, offset: NSPoint(x: arrowUnit, y: -arrowUnit),
                        border: shadow, fill: shadow, core: shadow)
        drawArrowSprite(unit: arrowUnit, offset: .zero,
                        border: border, fill: fill, core: core)
        context.restoreGraphicsState()
    }

    private func drawArrowSprite(
        unit: CGFloat,
        offset: NSPoint,
        border: NSColor,
        fill: NSColor,
        core: NSColor
    ) {
        let rows = Self.arrowSpriteRows
        let rowCount = rows.count
        let colCount = rows.map(\.count).max() ?? 0
        // Center the grid on the origin (sprite center).
        let centerCol = CGFloat(colCount - 1) / 2
        let centerRow = CGFloat(rowCount - 1) / 2

        func cell(_ col: Int, _ row: Int) -> NSRect {
            // Flip row so the grid reads top-to-bottom but draws y-up.
            NSRect(
                x: offset.x + (CGFloat(col) - centerCol) * unit,
                y: offset.y + (centerRow - CGFloat(row)) * unit,
                width: unit,
                height: unit
            )
        }

        var filled = Set<[Int]>()
        for (r, line) in rows.enumerated() {
            for (c, ch) in line.enumerated() where ch == "#" {
                filled.insert([c, r])
            }
        }

        // 1-cell dark outline around the whole shape.
        border.setFill()
        let neighbors = [-1, 0, 1]
        for key in filled {
            for dx in neighbors {
                for dy in neighbors where !(dx == 0 && dy == 0) {
                    let n = [key[0] + dx, key[1] + dy]
                    if !filled.contains(n) {
                        NSBezierPath(rect: cell(n[0], n[1])).fill()
                    }
                }
            }
        }

        // Fill, then the single lighter accent pixel.
        fill.setFill()
        for key in filled {
            NSBezierPath(rect: cell(key[0], key[1])).fill()
        }
        core.setFill()
        NSBezierPath(rect: cell(Self.arrowCoreCell.col, Self.arrowCoreCell.row)).fill()
    }
}

@MainActor
final class PetController: NSObject, NSTextFieldDelegate {
    private let panel: NSPanel
    private let containerView: NSView
    private let promptPanel: NSPanel
    private let promptContainerView: NSView
    private let targetMarkerPanel: NSPanel
    private let petView: PetMascotView
    private let appIconView: NSImageView
    private let promptBubbleView: PetPromptBubbleView
    private let targetMarkerView: PetPromptBubbleView
    private let promptTextField: AskPromptTextField
    private let answerScrollView: NSScrollView
    private let answerTextView: NSTextView
    private let continueButton = NSButton()
    private var workspaceObserver: NSObjectProtocol?
    private var trackingTimer: Timer?
    private var tabInterceptor: TabKeyInterceptor?
    private var promptKeyInterceptor: PromptKeyInterceptor?
    private var promptGlobalOutsideClickMonitor: Any?
    private var promptLocalOutsideClickMonitor: Any?
    private var selectedText: String?
    private var onTranslate: ((String) -> Void)?
    private var onRewrite: ((String) -> Void)?
    private var onSmartReply: ((String) -> Void)?
    private var onPromptSubmit: ((String) -> Void)?
    private var onPromptClose: (() -> Void)?
    var onContinue: (() -> Void)?
    private var currentMode: TranslationMode
    private var isReadyLockedUntilPanelCloses = false
    private var isThinking = false
    private var isPromptOpen = false
    private var isPromptLoading = false
    private var isAnswerOpen = false
    private var promptBuffer = ""
    private var promptHasFullSelection = false
    private var currentPromptInputLayout = AskNugumiPromptInputMetrics.layout(forContentHeight: 0)
    private var currentAnswerLayout = AskNugumiAnswerBubbleMetrics.layout(forContentHeight: 0)
    private var currentAnswerMarkerTarget: NSPoint?
    private var pointingTarget: NSPoint?
    private var pendingPointArrival: (() -> Void)?
    private var pointingArrivalFallbackTimer: Timer?
    private var pointingReturnTimer: Timer?
    private var lastCursorLocation = NSEvent.mouseLocation
    private var lastCursorMovementDate = Date.distantPast
    private var cursorOffset = PetController.defaultCursorOffset
    private var isReadyState: Bool {
        selectedText != nil || isReadyLockedUntilPanelCloses
    }

    private static let mascotSize = NSSize(width: 42, height: 34)
    private static let appIconSize = NSSize(width: 14, height: 14)
    private static let panelPadding: CGFloat = 6
    private static let panelSize = NSSize(
        width: mascotSize.width + panelPadding * 2,
        height: mascotSize.height + panelPadding * 2
    )
    private static let answerFontSize: CGFloat = 14
    private static let edgeMargin: CGFloat = 6
    private static let pointingArrivalThreshold: CGFloat = 8
    private static let pointingArrivalFallbackDelay: TimeInterval = 1.6
    private static let textMovementUserInfoKey = "NSTextMovement"
    private static let promptPlaceholder = "Hey, need me?"
    private static let defaultCursorOffset = NSPoint(
        x: 12 - panelPadding,
        y: -mascotSize.height - 8 - panelPadding
    )

    var isPromptVisible: Bool {
        isPromptOpen || isPromptLoading || isAnswerOpen
    }

    var isPromptComposingVisible: Bool {
        isPromptOpen || isPromptLoading
    }

    /// Screen-space center of the pet panel. The floating target pointer
    /// launches from here so it visibly travels from the character.
    var petAnchorPoint: NSPoint {
        NSPoint(x: panel.frame.midX, y: panel.frame.midY)
    }

    init(initialMode: TranslationMode) {
        currentMode = initialMode
        let origin = PetController.originNearCursor(
            for: NSEvent.mouseLocation,
            size: Self.panelSize,
            offset: cursorOffset
        )
        panel = PetPanel(
            contentRect: NSRect(origin: origin, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        containerView = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        let initialPromptInputLayout = AskNugumiPromptInputMetrics.layout(forContentHeight: 0)
        promptPanel = PetPanel(
            contentRect: NSRect(origin: origin, size: initialPromptInputLayout.panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        promptContainerView = NSView(frame: NSRect(origin: .zero, size: initialPromptInputLayout.panelSize))
        let initialMarkerPanelSize = AskNugumiTargetMarkerMetrics.paddedFrame(centeredAt: .zero).size
        targetMarkerPanel = PetPanel(
            contentRect: NSRect(origin: origin, size: initialMarkerPanelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        petView = PetMascotView(frame: NSRect(
            origin: .zero,
            size: Self.panelSize
        ))
        appIconView = NSImageView(frame: NSRect(
            x: Self.panelSize.width - Self.appIconSize.width,
            y: Self.panelSize.height - Self.appIconSize.height,
            width: Self.appIconSize.width,
            height: Self.appIconSize.height
        ))
        promptBubbleView = PetPromptBubbleView(frame: initialPromptInputLayout.bubbleFrame)
        targetMarkerView = PetPromptBubbleView(frame: NSRect(origin: .zero, size: initialMarkerPanelSize))
        promptTextField = AskPromptTextField(frame: initialPromptInputLayout.textFrame)
        let initialAnswerLayout = AskNugumiAnswerBubbleMetrics.layout(forContentHeight: 0)
        answerScrollView = NSScrollView(frame: initialAnswerLayout.viewportFrame)
        answerTextView = NSTextView(frame: NSRect(
            origin: .zero,
            size: initialAnswerLayout.viewportFrame.size
        ))

        super.init()

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true

        promptPanel.level = .floating
        promptPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: promptPanel)
        promptPanel.isReleasedWhenClosed = false
        promptPanel.isOpaque = false
        promptPanel.backgroundColor = .clear
        promptPanel.hasShadow = false
        promptPanel.hidesOnDeactivate = false
        promptPanel.ignoresMouseEvents = false

        targetMarkerPanel.level = .floating
        targetMarkerPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: targetMarkerPanel)
        targetMarkerPanel.isReleasedWhenClosed = false
        targetMarkerPanel.isOpaque = false
        targetMarkerPanel.backgroundColor = .clear
        targetMarkerPanel.hasShadow = false
        targetMarkerPanel.hidesOnDeactivate = false
        targetMarkerPanel.ignoresMouseEvents = true

        containerView.autoresizingMask = [.width, .height]
        promptContainerView.autoresizingMask = [.width, .height]
        petView.wantsLayer = true
        petView.layer?.shadowColor = NSColor.black.cgColor
        petView.layer?.shadowOpacity = 0.32
        petView.layer?.shadowRadius = 3
        petView.layer?.shadowOffset = .zero
        petView.layer?.masksToBounds = false
        containerView.addSubview(petView)

        appIconView.imageScaling = .scaleProportionallyDown
        appIconView.isHidden = true
        containerView.addSubview(appIconView)

        promptBubbleView.alphaValue = 0
        promptBubbleView.isHidden = true
        promptContainerView.addSubview(promptBubbleView)

        targetMarkerView.drawsBubble = false
        targetMarkerView.autoresizingMask = [.width, .height]
        targetMarkerView.targetMarkerPoint = NSPoint(
            x: targetMarkerView.bounds.midX,
            y: targetMarkerView.bounds.midY
        )
        targetMarkerPanel.contentView = targetMarkerView

        promptTextField.delegate = self
        promptTextField.onEscape = { [weak self] in
            self?.closePromptFromUser()
        }
        promptTextField.font = NugumiFont.pixelPrompt(size: 16)
        promptTextField.textColor = NSColor(srgbRed: 0.26, green: 0.30, blue: 0.30, alpha: 1.0)
        promptTextField.isBordered = false
        promptTextField.isBezeled = false
        promptTextField.drawsBackground = false
        promptTextField.backgroundColor = .clear
        promptTextField.focusRingType = .none
        promptTextField.isEditable = false
        promptTextField.isSelectable = false
        configurePromptTextFieldForInput()
        promptTextField.alphaValue = 0
        promptTextField.isHidden = true
        setPromptPlaceholder(Self.promptPlaceholder)
        promptContainerView.addSubview(promptTextField)

        answerTextView.font = NugumiFont.pixelPrompt(size: Self.answerFontSize)
        answerTextView.textColor = NSColor(srgbRed: 0.26, green: 0.30, blue: 0.30, alpha: 1.0)
        answerTextView.drawsBackground = false
        answerTextView.backgroundColor = .clear
        answerTextView.isEditable = false
        answerTextView.isSelectable = true
        answerTextView.isRichText = false
        answerTextView.importsGraphics = false
        answerTextView.isHorizontallyResizable = false
        answerTextView.isVerticallyResizable = true
        answerTextView.textContainerInset = .zero
        answerTextView.textContainer?.lineFragmentPadding = 0
        answerTextView.textContainer?.widthTracksTextView = true
        answerTextView.textContainer?.heightTracksTextView = false

        answerScrollView.borderType = .noBorder
        answerScrollView.drawsBackground = false
        answerScrollView.hasHorizontalScroller = false
        answerScrollView.hasVerticalScroller = false
        answerScrollView.autohidesScrollers = true
        answerScrollView.scrollerStyle = .overlay
        answerScrollView.alphaValue = 0
        answerScrollView.isHidden = true
        answerScrollView.documentView = answerTextView
        promptContainerView.addSubview(answerScrollView)

        // "Continue dialog" affordance, bottom-right of the answer bubble.
        continueButton.isBordered = false
        continueButton.bezelStyle = .regularSquare
        continueButton.imagePosition = .imageOnly
        continueButton.image = NSImage(
            systemSymbolName: "arrowshape.turn.up.left.circle.fill",
            accessibilityDescription: "Continue conversation"
        )
        continueButton.contentTintColor = .nugumiAccent
        continueButton.toolTip = "Continue the conversation"
        continueButton.target = self
        continueButton.action = #selector(continueButtonTapped)
        continueButton.isHidden = true
        continueButton.alphaValue = 0
        promptContainerView.addSubview(continueButton)

        panel.contentView = containerView
        promptPanel.contentView = promptContainerView
        petView.onClick = { [weak self] in
            guard let self else { return }
            if self.isPromptVisible || self.onPromptClose != nil {
                self.closePromptFromUser()
                return
            }
            self.invokeCurrentMode()
        }
        petView.onRightClick = { [weak self] in
            self?.invokeRewriteMode()
        }

        refreshAppIcon()
        subscribeToFrontmostAppChanges()
    }

    private func subscribeToFrontmostAppChanges() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAppIcon()
            }
        }
    }

    private func refreshAppIcon() {
        guard !isReadyState, !isThinking, !isPromptVisible else {
            appIconView.isHidden = true
            return
        }
        guard let runningApp = NSWorkspace.shared.frontmostApplication else {
            appIconView.isHidden = true
            return
        }
        if runningApp.bundleIdentifier == Bundle.main.bundleIdentifier {
            appIconView.isHidden = true
            return
        }
        if let icon = runningApp.icon {
            appIconView.image = icon
            appIconView.isHidden = false
        } else {
            appIconView.isHidden = true
        }
    }

    func show() {
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        startTracking()
    }

    func close() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        clearPrompt(animate: false)
        clearReady()
        trackingTimer?.invalidate()
        trackingTimer = nil
        cancelPointingAnimation()
        panel.close()
        promptPanel.close()
        targetMarkerPanel.close()
    }

    func showPrompt(
        onSubmit: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        cancelPointingAnimation()
        selectedText = nil
        self.onTranslate = nil
        self.onRewrite = nil
        self.onSmartReply = nil
        onPromptSubmit = onSubmit
        onPromptClose = onClose
        currentMode = .draftMessage
        isReadyLockedUntilPanelCloses = false
        isThinking = false
        isPromptOpen = true
        isPromptLoading = false
        isAnswerOpen = false
        currentAnswerMarkerTarget = nil
        hideTargetMarker()
        panel.ignoresMouseEvents = false
        petView.allowsClickWhenNotReady = true
        tabInterceptor?.disable()
        tabInterceptor = nil
        appIconView.isHidden = true
        petView.apply(state: .idle, mode: currentMode)

        promptBuffer = ""
        promptHasFullSelection = false
        promptTextField.isEnabled = true
        configurePromptTextFieldForInput()
        renderPromptText()
        promptBubbleView.isError = false
        promptBubbleView.targetMarkerPoint = nil
        setPromptPlaceholder(Self.promptPlaceholder)
        let presentation = promptPresentationAnchoredToPet(
            size: currentPromptInputLayout.panelSize,
            bubbleFrame: currentPromptInputLayout.bubbleFrame
        )
        panel.setFrameOrigin(presentation.petOrigin)
        promptPanel.setFrame(presentation.promptFrame, display: true)
        showPromptViews()
        promptPanel.alphaValue = 1
        show()
        promptPanel.orderFrontRegardless()
        installPromptKeyInterceptor()
        installPromptOutsideClickMonitors()
    }

    func focusPrompt() {
        guard isPromptOpen else { return }
        promptPanel.orderFrontRegardless()
    }

    func setPromptLoading() {
        guard isPromptOpen else {
            showThinking()
            return
        }

        isPromptOpen = false
        isPromptLoading = true
        isAnswerOpen = false
        currentAnswerMarkerTarget = nil
        hideTargetMarker()
        isThinking = true
        promptHasFullSelection = false
        removePromptOutsideClickMonitors()
        removePromptKeyInterceptor()
        promptTextField.isEnabled = false
        panel.ignoresMouseEvents = false
        petView.allowsClickWhenNotReady = true
        petView.apply(state: .thinking, mode: currentMode)
        let targetFrame = panel.frame

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            promptPanel.animator().setFrame(targetFrame, display: true)
            promptPanel.animator().alphaValue = 0
            promptBubbleView.animator().alphaValue = 0
            promptTextField.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isPromptLoading else { return }
                self.promptBubbleView.isHidden = true
                self.promptTextField.isHidden = true
                self.promptPanel.orderOut(nil)
                self.promptPanel.alphaValue = 1
            }
        }
    }

    func showPromptError(_ message: String) {
        guard isPromptVisible || onPromptSubmit != nil else { return }

        isPromptOpen = true
        isPromptLoading = false
        isAnswerOpen = false
        currentAnswerMarkerTarget = nil
        hideTargetMarker()
        isThinking = false
        panel.ignoresMouseEvents = false
        petView.allowsClickWhenNotReady = true
        promptTextField.isEnabled = true
        configurePromptTextFieldForInput()
        promptBubbleView.isError = true
        promptBubbleView.targetMarkerPoint = nil
        setPromptPlaceholder(message)
        petView.apply(state: .idle, mode: currentMode)
        refreshPromptInputLayout()
        let presentation = promptPresentationAnchoredToPet(
            size: currentPromptInputLayout.panelSize,
            bubbleFrame: currentPromptInputLayout.bubbleFrame
        )
        panel.setFrameOrigin(presentation.petOrigin)
        promptPanel.setFrame(presentation.promptFrame, display: true)
        showPromptViews()
        promptPanel.alphaValue = 1
        show()
        focusPrompt()
        installPromptKeyInterceptor()
        installPromptOutsideClickMonitors()
    }

    func clearPrompt() {
        clearPrompt(animate: true)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard textMovement(from: notification) == NSTextMovement.return.rawValue else {
            return
        }
        submitPrompt()
    }

    func showAnswer(_ message: String, emotion: AskNugumiEmotion?, markerTarget: NSPoint? = nil) {
        let cleanMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanMessage.isEmpty else { return }

        cancelPointingAnimation()
        selectedText = nil
        onTranslate = nil
        onRewrite = nil
        onSmartReply = nil
        onPromptSubmit = nil
        onPromptClose = nil
        isReadyLockedUntilPanelCloses = false
        isThinking = false
        isPromptOpen = false
        isPromptLoading = false
        isAnswerOpen = true
        currentAnswerMarkerTarget = nil
        promptBuffer = ""
        promptHasFullSelection = false
        removePromptKeyInterceptor()

        panel.ignoresMouseEvents = false
        petView.allowsClickWhenNotReady = true
        tabInterceptor?.disable()
        tabInterceptor = nil
        appIconView.isHidden = true
        promptBubbleView.isError = false
        configureAnswerTextView(with: cleanMessage)

        let presentation = answerPresentationFrame(
            for: currentAnswerLayout,
            markerTarget: markerTarget
        )
        currentAnswerLayout = presentation.layout
        panel.setFrameOrigin(presentation.petOrigin)
        promptPanel.setFrame(presentation.frame, display: true)
        currentAnswerMarkerTarget = presentation.markerTarget
        showPromptViews()
        promptPanel.alphaValue = 1
        show()
        promptPanel.orderFrontRegardless()
        let petCenter = NSPoint(
            x: presentation.petOrigin.x + Self.panelSize.width / 2,
            y: presentation.petOrigin.y + Self.panelSize.height / 2
        )
        showTargetMarker(
            frame: presentation.markerFrame,
            target: presentation.markerTarget,
            fromPetCenter: petCenter
        )
        panel.orderFrontRegardless()
        petView.apply(state: .idle, mode: currentMode, emotion: emotion ?? .neutral)
        installPromptOutsideClickMonitors()
    }

    func moveToAnswerTarget(
        _ destination: NSPoint,
        markerTarget: NSPoint,
        message: String,
        emotion: AskNugumiEmotion?
    ) {
        let targetOrigin = Self.originNearPoint(destination, size: Self.panelSize)
        let distance = hypot(targetOrigin.x - panel.frame.origin.x, targetOrigin.y - panel.frame.origin.y)
        guard distance > Self.pointingArrivalThreshold else {
            showAnswer(message, emotion: emotion, markerTarget: markerTarget)
            return
        }

        cancelPointingAnimation()
        selectedText = nil
        onTranslate = nil
        onRewrite = nil
        onSmartReply = nil
        isReadyLockedUntilPanelCloses = false
        isThinking = false
        isPromptOpen = false
        isPromptLoading = false
        isAnswerOpen = false
        currentAnswerMarkerTarget = nil
        hideTargetMarker()
        panel.ignoresMouseEvents = true
        tabInterceptor?.disable()
        tabInterceptor = nil
        appIconView.isHidden = true
        promptPanel.orderOut(nil)
        pointingTarget = destination
        pendingPointArrival = { [weak self] in
            self?.showAnswer(message, emotion: emotion, markerTarget: markerTarget)
        }
        schedulePointingArrivalFallback()
        petView.apply(state: .run, mode: currentMode)
        show()
    }

    private func submitPrompt() {
        guard isPromptOpen, promptTextField.isEnabled else { return }
        let text = promptBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            promptHasFullSelection = false
            renderPromptText()
            return
        }
        onPromptSubmit?(text)
    }

    private func closePromptFromUser() {
        guard isPromptVisible else { return }
        let onClose = onPromptClose
        clearPrompt(animate: true)
        onClose?()
    }

    private func clearPrompt(animate: Bool) {
        guard isPromptVisible || onPromptSubmit != nil || onPromptClose != nil else { return }
        removePromptOutsideClickMonitors()
        removePromptKeyInterceptor()
        isPromptOpen = false
        isPromptLoading = false
        isAnswerOpen = false
        currentAnswerMarkerTarget = nil
        hideTargetMarker()
        onPromptSubmit = nil
        onPromptClose = nil
        promptBuffer = ""
        promptHasFullSelection = false
        renderPromptText()
        promptTextField.isEnabled = true
        promptBubbleView.isError = false
        setPromptPlaceholder(Self.promptPlaceholder)
        hidePromptViews()
        promptPanel.orderOut(nil)
        promptPanel.alphaValue = 1
        if !isThinking {
            panel.ignoresMouseEvents = true
            petView.allowsClickWhenNotReady = false
            petView.apply(state: .idle, mode: currentMode, emotion: .neutral)
            refreshAppIcon()
        }
    }

    private func showPromptViews() {
        layoutPromptSubviews()
        promptBubbleView.isHidden = false
        promptBubbleView.alphaValue = 1
        if isAnswerOpen {
            promptTextField.alphaValue = 0
            promptTextField.isHidden = true
            answerScrollView.isHidden = false
            answerScrollView.alphaValue = 1
            continueButton.isHidden = (onContinue == nil)
            continueButton.alphaValue = (onContinue == nil) ? 0 : 1
        } else {
            answerScrollView.alphaValue = 0
            answerScrollView.isHidden = true
            promptTextField.isHidden = false
            promptTextField.alphaValue = 1
            continueButton.isHidden = true
            continueButton.alphaValue = 0
        }
    }

    private func hidePromptViews() {
        promptBubbleView.alphaValue = 0
        promptTextField.alphaValue = 0
        answerScrollView.alphaValue = 0
        promptBubbleView.isHidden = true
        promptTextField.isHidden = true
        answerScrollView.isHidden = true
        continueButton.isHidden = true
        continueButton.alphaValue = 0
        hideTargetMarker()
    }

    @objc private func continueButtonTapped() {
        onContinue?()
    }

    private func configurePromptTextFieldForInput() {
        promptTextField.font = NugumiFont.pixelPrompt(size: AskNugumiPromptInputMetrics.fontSize)
        promptTextField.usesSingleLineMode = false
        promptTextField.maximumNumberOfLines = 0
        promptTextField.cell?.wraps = true
        promptTextField.cell?.isScrollable = false
        promptTextField.cell?.lineBreakMode = .byWordWrapping
    }

    private func configureAnswerTextView(with message: String) {
        let contentHeight = answerContentHeight(for: message)
        currentAnswerLayout = AskNugumiAnswerBubbleMetrics.layout(forContentHeight: contentHeight)
        let layout = currentAnswerLayout
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NugumiFont.pixelPrompt(size: Self.answerFontSize),
            .foregroundColor: NSColor(srgbRed: 0.26, green: 0.30, blue: 0.30, alpha: 1.0),
            .paragraphStyle: paragraphStyle
        ]
        answerTextView.textStorage?.setAttributedString(NSAttributedString(
            string: message,
            attributes: attributes
        ))
        answerTextView.font = NugumiFont.pixelPrompt(size: Self.answerFontSize)
        answerTextView.textColor = NSColor(srgbRed: 0.26, green: 0.30, blue: 0.30, alpha: 1.0)
        // Only carve out a lane for the overlay scroller when it's actually
        // shown. The text view stays full-width (so the clip view fills the
        // bubble); the container wraps ~14px short so glyphs never sit under
        // the scrollbar, with no wasted space when there's no scroll.
        let scrollerGutter: CGFloat = layout.needsScroll ? 14 : 0
        answerTextView.textContainer?.widthTracksTextView = false
        answerTextView.textContainer?.containerSize = NSSize(
            width: layout.viewportFrame.width - scrollerGutter,
            height: .greatestFiniteMagnitude
        )
        answerTextView.frame = NSRect(
            origin: .zero,
            size: NSSize(
                width: layout.viewportFrame.width,
                height: layout.documentHeight
            )
        )
        answerScrollView.hasVerticalScroller = layout.needsScroll
        answerScrollView.autohidesScrollers = !layout.needsScroll
        answerTextView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private func answerContentHeight(for message: String) -> CGFloat {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NugumiFont.pixelPrompt(size: Self.answerFontSize),
            .paragraphStyle: paragraphStyle
        ]
        let boundingRect = (message as NSString).boundingRect(
            with: NSSize(
                width: AskNugumiAnswerBubbleMetrics.layout(forContentHeight: 0).viewportFrame.width,
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return ceil(boundingRect.height) + 4
    }

    private func setPromptPlaceholder(_ text: String) {
        promptTextField.placeholderString = text
        promptTextField.placeholderAttributedString = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: promptBubbleView.isError
                    ? NSColor(srgbRed: 0.78, green: 0.18, blue: 0.18, alpha: 0.78)
                    : NSColor(srgbRed: 0.27, green: 0.31, blue: 0.33, alpha: 0.62),
                .font: promptTextField.font ?? NugumiFont.pixelPrompt(size: 16)
            ]
        )
    }

    private func renderPromptText() {
        promptTextField.stringValue = promptBuffer
        refreshPromptInputLayout()
    }

    private func refreshPromptInputLayout() {
        currentPromptInputLayout = AskNugumiPromptInputMetrics.layout(
            forContentHeight: promptInputContentHeight(for: promptBuffer)
        )
        guard isPromptOpen, !isAnswerOpen else { return }
        let presentation = promptPresentationAnchoredToPet(
            size: currentPromptInputLayout.panelSize,
            bubbleFrame: currentPromptInputLayout.bubbleFrame
        )
        panel.setFrameOrigin(presentation.petOrigin)
        promptPanel.setFrame(presentation.promptFrame, display: true)
        layoutPromptSubviews()
    }

    private func promptInputContentHeight(for text: String) -> CGFloat {
        let measuredText = text.isEmpty ? Self.promptPlaceholder : text
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NugumiFont.pixelPrompt(size: AskNugumiPromptInputMetrics.fontSize),
            .paragraphStyle: paragraphStyle
        ]
        let boundingRect = (measuredText as NSString).boundingRect(
            with: NSSize(
                width: AskNugumiPromptInputMetrics.textMeasurementWidth,
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return ceil(boundingRect.height) + AskNugumiPromptInputMetrics.textMeasurementBottomInset
    }

    private func insertPromptText(_ text: String) {
        guard isPromptOpen, promptTextField.isEnabled else { return }
        if promptHasFullSelection {
            promptBuffer = text
        } else {
            promptBuffer.append(text)
        }
        promptHasFullSelection = false
        promptBubbleView.isError = false
        setPromptPlaceholder(Self.promptPlaceholder)
        renderPromptText()
    }

    private func deletePromptBackward() {
        guard isPromptOpen, promptTextField.isEnabled else { return }
        if promptHasFullSelection {
            promptBuffer = ""
            promptHasFullSelection = false
        } else if !promptBuffer.isEmpty {
            promptBuffer.removeLast()
        }
        renderPromptText()
    }

    private func pastePromptText() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return
        }
        insertPromptText(text)
    }

    private func selectAllPromptText() {
        guard isPromptOpen, !promptBuffer.isEmpty else { return }
        promptHasFullSelection = true
    }

    private func installPromptKeyInterceptor() {
        guard promptKeyInterceptor == nil else { return }
        let interceptor = PromptKeyInterceptor(
            onInsertText: { [weak self] text in
                self?.insertPromptText(text)
            },
            onBackspace: { [weak self] in
                self?.deletePromptBackward()
            },
            onSubmit: { [weak self] in
                self?.submitPrompt()
            },
            onCancel: { [weak self] in
                self?.closePromptFromUser()
            },
            onPaste: { [weak self] in
                self?.pastePromptText()
            },
            onSelectAll: { [weak self] in
                self?.selectAllPromptText()
            }
        )
        promptKeyInterceptor = interceptor
        interceptor.enable()
    }

    private func removePromptKeyInterceptor() {
        promptKeyInterceptor?.disable()
        promptKeyInterceptor = nil
    }

    private func textMovement(from notification: Notification) -> Int? {
        notification.userInfo?[Self.textMovementUserInfoKey] as? Int
    }

    private func promptPresentationAnchoredToPet(
        size: NSSize,
        bubbleFrame: NSRect
    ) -> (promptFrame: NSRect, petOrigin: NSPoint) {
        let referencePoint = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let visibleFrame = NSScreen.visibleFrame(containing: referencePoint)
        let presentation = AskNugumiPetBubblePresentationMetrics.presentation(
            petOrigin: panel.frame.origin,
            petSize: Self.panelSize,
            promptSize: size,
            bubbleFrame: bubbleFrame,
            visibleFrame: visibleFrame,
            edgeMargin: Self.edgeMargin
        )

        return (presentation.promptFrame, presentation.petOrigin)
    }

    private func answerPresentationFrame(
        for layout: AskNugumiAnswerBubbleLayout,
        markerTarget: NSPoint?
    ) -> (
        frame: NSRect,
        petOrigin: NSPoint,
        layout: AskNugumiAnswerBubbleLayout,
        markerFrame: NSRect?,
        markerTarget: NSPoint?
    ) {
        let promptPresentation = promptPresentationAnchoredToPet(
            size: layout.panelSize,
            bubbleFrame: layout.bubbleFrame
        )
        let markerPresentation = AskNugumiPetAnswerTargetPanelMetrics.presentation(
            bubblePanelFrame: promptPresentation.promptFrame,
            markerTarget: markerTarget
        )

        return (
            markerPresentation.bubblePanelFrame,
            promptPresentation.petOrigin,
            layout,
            markerPresentation.markerPanelFrame,
            markerPresentation.localMarkerTarget
        )
    }

    private func showTargetMarker(frame: NSRect?, target: NSPoint?, fromPetCenter petCenter: NSPoint) {
        guard let frame, let target else {
            hideTargetMarker()
            return
        }

        let destCenter = NSPoint(x: frame.midX, y: frame.midY)
        targetMarkerView.frame = NSRect(origin: .zero, size: frame.size)
        targetMarkerView.targetMarkerPoint = target
        targetMarkerView.targetMarkerAngle = atan2(
            destCenter.y - petCenter.y,
            destCenter.x - petCenter.x
        )

        // Launch centered on the pet, then glide to the destination so the
        // arrow visibly travels from the character to the target.
        let startFrame = NSRect(
            x: petCenter.x - frame.width / 2,
            y: petCenter.y - frame.height / 2,
            width: frame.width,
            height: frame.height
        )
        targetMarkerPanel.setFrame(startFrame, display: true)
        targetMarkerPanel.alphaValue = 1
        targetMarkerPanel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.46
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            targetMarkerPanel.animator().setFrame(frame, display: true)
        }
    }

    private func hideTargetMarker() {
        targetMarkerPanel.orderOut(nil)
        targetMarkerPanel.alphaValue = 1
    }

    private func layoutPromptSubviews() {
        petView.frame = NSRect(origin: .zero, size: Self.panelSize)
        appIconView.frame = NSRect(
            x: Self.panelSize.width - Self.appIconSize.width,
            y: Self.panelSize.height - Self.appIconSize.height,
            width: Self.appIconSize.width,
            height: Self.appIconSize.height
        )
        if isAnswerOpen {
            promptBubbleView.frame = NSRect(origin: .zero, size: currentAnswerLayout.panelSize)
            promptBubbleView.bubbleFrame = currentAnswerLayout.bubbleFrame
            promptBubbleView.targetMarkerPoint = nil
            answerScrollView.frame = currentAnswerLayout.viewportFrame
            // The visible bubble border sits 15px in from the sides (5*unit)
            // and 9px up from the bottom (3*unit). Add the SAME gap past each
            // so the button is equidistant from the right and bottom edges.
            let bubble = currentAnswerLayout.bubbleFrame
            let buttonSize: CGFloat = 16
            let sideBorder: CGFloat = 15
            let bottomBorder: CGFloat = 9
            let gap: CGFloat = 8
            continueButton.frame = NSRect(
                x: bubble.maxX - sideBorder - gap - buttonSize,
                y: bubble.minY + bottomBorder + gap,
                width: buttonSize,
                height: buttonSize
            )
        } else {
            promptBubbleView.frame = NSRect(origin: .zero, size: currentPromptInputLayout.panelSize)
            promptBubbleView.bubbleFrame = currentPromptInputLayout.bubbleFrame
            promptBubbleView.targetMarkerPoint = nil
            promptTextField.frame = currentPromptInputLayout.textFrame
        }
    }

    private func installPromptOutsideClickMonitors() {
        guard promptGlobalOutsideClickMonitor == nil, promptLocalOutsideClickMonitor == nil else {
            return
        }

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        promptGlobalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.closePromptIfClickIsOutside(event)
        }

        promptLocalOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.closePromptIfClickIsOutside(event)
            return event
        }
    }

    private func removePromptOutsideClickMonitors() {
        if let promptGlobalOutsideClickMonitor {
            NSEvent.removeMonitor(promptGlobalOutsideClickMonitor)
            self.promptGlobalOutsideClickMonitor = nil
        }
        if let promptLocalOutsideClickMonitor {
            NSEvent.removeMonitor(promptLocalOutsideClickMonitor)
            self.promptLocalOutsideClickMonitor = nil
        }
    }

    private func closePromptIfClickIsOutside(_ event: NSEvent) {
        guard isPromptVisible, panel.isVisible else { return }

        let screenPoint = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        guard AskNugumiPetDismissalPolicy.shouldDismissPrompt(
            clickPoint: screenPoint,
            petFrame: panel.frame
        ) else {
            return
        }

        closePromptFromUser()
    }

    func showReady(
        selectedText: String,
        initialMode: TranslationMode,
        onTranslate: @escaping (String) -> Void,
        onRewrite: @escaping (String) -> Void,
        onSmartReply: @escaping (String) -> Void
    ) {
        guard !PetSelectionStatusPolicy.shouldPreserveCurrentStatus(isThinking: isThinking) else {
            return
        }
        clearPrompt(animate: true)
        cancelPointingAnimation()
        self.selectedText = selectedText
        self.onTranslate = onTranslate
        self.onRewrite = onRewrite
        self.onSmartReply = onSmartReply
        currentMode = initialMode
        isReadyLockedUntilPanelCloses = false
        panel.ignoresMouseEvents = false
        petView.apply(state: .ready, mode: currentMode)
        appIconView.isHidden = true
        enableTabInterceptor()
        show()
    }

    func holdReadyUntilPanelCloses(mode: TranslationMode? = nil) {
        cancelPointingAnimation()
        if let mode {
            currentMode = mode
        }
        selectedText = nil
        onTranslate = nil
        onRewrite = nil
        onSmartReply = nil
        isReadyLockedUntilPanelCloses = true
        panel.ignoresMouseEvents = true
        tabInterceptor?.disable()
        tabInterceptor = nil
        petView.apply(state: .ready, mode: currentMode)
        appIconView.isHidden = true
    }

    func clearReady() {
        guard !isPromptVisible,
              !PetSelectionStatusPolicy.shouldPreserveCurrentStatus(isThinking: isThinking)
        else { return }
        cancelPointingAnimation()
        selectedText = nil
        onTranslate = nil
        onRewrite = nil
        onSmartReply = nil
        isReadyLockedUntilPanelCloses = false
        panel.ignoresMouseEvents = true
        tabInterceptor?.disable()
        tabInterceptor = nil
        petView.apply(state: .idle, mode: currentMode)
        refreshAppIcon()
    }

    func showThinking() {
        if isPromptOpen {
            clearPrompt(animate: false)
        }
        cancelPointingAnimation()
        isThinking = true
        selectedText = nil
        onTranslate = nil
        onRewrite = nil
        onSmartReply = nil
        isReadyLockedUntilPanelCloses = false
        panel.ignoresMouseEvents = !isPromptLoading
        petView.allowsClickWhenNotReady = isPromptLoading
        tabInterceptor?.disable()
        tabInterceptor = nil
        appIconView.isHidden = true
        petView.apply(state: .thinking, mode: currentMode)
        show()
    }

    func clearThinking() {
        isThinking = false
        isPromptLoading = false
        panel.ignoresMouseEvents = true
        petView.allowsClickWhenNotReady = false
        petView.apply(state: .idle, mode: currentMode)
        refreshAppIcon()
    }

    func pointTemporarily(at destination: NSPoint, holdDuration: TimeInterval = 3.0) {
        pointingReturnTimer?.invalidate()
        pendingPointArrival = nil
        pointingTarget = destination
        selectedText = nil
        onTranslate = nil
        onRewrite = nil
        onSmartReply = nil
        isReadyLockedUntilPanelCloses = false
        isThinking = false
        panel.ignoresMouseEvents = true
        tabInterceptor?.disable()
        tabInterceptor = nil
        appIconView.isHidden = true
        petView.apply(state: .run, mode: currentMode)
        show()

        let timer = Timer(timeInterval: holdDuration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pointingTarget = nil
                self?.pointingReturnTimer = nil
                self?.refreshAppIcon()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointingReturnTimer = timer
    }

    private func cancelPointingAnimation() {
        pointingReturnTimer?.invalidate()
        pointingReturnTimer = nil
        pointingArrivalFallbackTimer?.invalidate()
        pointingArrivalFallbackTimer = nil
        pointingTarget = nil
        pendingPointArrival = nil
    }

    private func schedulePointingArrivalFallback() {
        pointingArrivalFallbackTimer?.invalidate()
        let timer = Timer(timeInterval: Self.pointingArrivalFallbackDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.completePendingPointArrival()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointingArrivalFallbackTimer = timer
    }

    private func completePendingPointArrival() {
        guard let pendingPointArrival else { return }
        pointingArrivalFallbackTimer?.invalidate()
        pointingArrivalFallbackTimer = nil
        pointingTarget = nil
        self.pendingPointArrival = nil
        pendingPointArrival()
    }

    func setActionMode(_ mode: TranslationMode) {
        currentMode = mode
        guard !isPromptVisible else { return }
        petView.apply(state: selectedText == nil && !isReadyLockedUntilPanelCloses ? .idle : .ready, mode: currentMode)
        refreshAppIcon()
    }

    private func startTracking() {
        guard trackingTimer == nil else { return }

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private func updateTracking() {
        guard panel.isVisible else { return }

        petView.advanceAnimationFrame()
        if isAnswerOpen {
            promptBubbleView.advanceTargetMarkerBlink()
            targetMarkerView.advanceTargetMarkerBlink()
        }
        if let pointingTarget {
            let targetOrigin = Self.originNearPoint(pointingTarget, size: Self.panelSize)
            let currentOrigin = panel.frame.origin
            let dx = targetOrigin.x - currentOrigin.x
            let dy = targetOrigin.y - currentOrigin.y
            let nextOrigin = NSPoint(
                x: currentOrigin.x + dx * 0.18,
                y: currentOrigin.y + dy * 0.18
            )
            panel.setFrameOrigin(nextOrigin)
            let distance = hypot(dx, dy)
            let hasPendingArrival = pendingPointArrival != nil
            let didArrive = distance <= Self.pointingArrivalThreshold
            petView.apply(state: didArrive ? .ready : .run, mode: currentMode)
            if didArrive, hasPendingArrival {
                completePendingPointArrival()
            }
            return
        }
        guard selectedText == nil, !isReadyLockedUntilPanelCloses, !isThinking, !isPromptVisible else {
            return
        }

        let cursorLocation = NSEvent.mouseLocation
        let cursorMovement = hypot(
            cursorLocation.x - lastCursorLocation.x,
            cursorLocation.y - lastCursorLocation.y
        )
        if cursorMovement > 0.75 {
            cursorOffset = Self.trailingOffset(
                forMovement: NSPoint(
                    x: cursorLocation.x - lastCursorLocation.x,
                    y: cursorLocation.y - lastCursorLocation.y
                ),
                size: Self.panelSize
            )
            lastCursorLocation = cursorLocation
            lastCursorMovementDate = Date()
        }

        let targetOrigin = Self.originNearCursor(
            for: cursorLocation,
            size: Self.panelSize,
            offset: cursorOffset
        )
        let currentOrigin = panel.frame.origin
        let dx = targetOrigin.x - currentOrigin.x
        let dy = targetOrigin.y - currentOrigin.y
        let nextOrigin = NSPoint(
            x: currentOrigin.x + dx * 0.22,
            y: currentOrigin.y + dy * 0.22
        )
        panel.setFrameOrigin(nextOrigin)
        let cursorMovedRecently = Date().timeIntervalSince(lastCursorMovementDate) < 0.16
        petView.apply(state: cursorMovedRecently ? .run : .idle, mode: currentMode)
    }

    private func enableTabInterceptor() {
        tabInterceptor?.disable()
        let interceptor = TabKeyInterceptor { [weak self] in
            self?.toggleMode()
        }
        tabInterceptor = interceptor
        interceptor.enable()
    }

    private func toggleMode() {
        currentMode = currentMode == .smartReply ? .selection : .smartReply
        petView.apply(state: selectedText == nil && !isReadyLockedUntilPanelCloses ? .idle : .ready, mode: currentMode)
    }

    private func invokeCurrentMode() {
        guard let selectedText, !isReadyLockedUntilPanelCloses else { return }

        switch currentMode {
        case .selection:
            onTranslate?(selectedText)
        case .draftMessage:
            onRewrite?(selectedText)
        case .smartReply:
            onSmartReply?(selectedText)
        }
    }

    private func invokeRewriteMode() {
        guard let selectedText,
              !isReadyLockedUntilPanelCloses,
              currentMode == .selection
        else { return }

        onRewrite?(selectedText)
    }

    private static func originNearCursor(for cursor: NSPoint, size: NSSize, offset: NSPoint) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: cursor.x + offset.x, y: cursor.y + offset.y)

        if origin.y < visibleFrame.minY + edgeMargin {
            origin.y = cursor.y + 12
        }
        if origin.y + size.height > visibleFrame.maxY - edgeMargin {
            origin.y = cursor.y - size.height - 8
        }
        if origin.x < visibleFrame.minX + edgeMargin {
            origin.x = cursor.x + 12
        }
        if origin.x + size.width > visibleFrame.maxX - edgeMargin {
            origin.x = cursor.x - size.width - 12
        }

        origin.x = min(max(origin.x, visibleFrame.minX + edgeMargin), visibleFrame.maxX - size.width - edgeMargin)
        origin.y = min(max(origin.y, visibleFrame.minY + edgeMargin), visibleFrame.maxY - size.height - edgeMargin)
        return origin
    }

    private static func originNearPoint(_ point: NSPoint, size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        origin.x = min(max(origin.x, visibleFrame.minX + edgeMargin), visibleFrame.maxX - size.width - edgeMargin)
        origin.y = min(max(origin.y, visibleFrame.minY + edgeMargin), visibleFrame.maxY - size.height - edgeMargin)
        return origin
    }

    private static func clampedOrigin(_ origin: NSPoint, size: NSSize, visibleFrame: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, visibleFrame.minX + edgeMargin), visibleFrame.maxX - size.width - edgeMargin),
            y: min(max(origin.y, visibleFrame.minY + edgeMargin), visibleFrame.maxY - size.height - edgeMargin)
        )
    }

    private static func trailingOffset(forMovement movement: NSPoint, size: NSSize) -> NSPoint {
        if abs(movement.x) >= abs(movement.y) {
            let xOffset = movement.x > 0 ? -size.width - 12 : 12
            return NSPoint(x: xOffset, y: -size.height / 2)
        }

        let yOffset = movement.y > 0 ? -size.height - 8 : 12
        return NSPoint(x: -size.width / 2, y: yOffset)
    }
}

@MainActor
final class PetMascotView: NSView {
    enum State: Equatable {
        case idle
        case run
        case ready
        case thinking
    }

    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    var allowsClickWhenNotReady = false

    private var state: State = .idle
    private var mode: TranslationMode = .selection
    private var emotion: AskNugumiEmotion = .neutral
    private var animationFrame = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "Nugumi"
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard state == .ready || allowsClickWhenNotReady else { return }
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard state == .ready else { return }
        onRightClick?()
    }

    func apply(state: State, mode: TranslationMode, emotion: AskNugumiEmotion = .neutral) {
        let didChange = self.state != state || self.mode != mode || self.emotion != emotion
        self.state = state
        self.mode = mode
        self.emotion = emotion
        toolTip = tooltip(for: state, mode: mode)
        if didChange {
            needsDisplay = true
        }
    }

    func advanceAnimationFrame() {
        animationFrame = (animationFrame + 1) % 240
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = false
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        let rows = spriteRows()
        let cellSize: CGFloat = 2
        let maxColumns = rows.map(\.count).max() ?? 0
        let spriteSize = NSSize(width: CGFloat(maxColumns) * cellSize, height: CGFloat(rows.count) * cellSize)
        let spriteYOffset = spriteYOffset()
        let origin = NSPoint(
            x: floor((bounds.width - spriteSize.width) / 2),
            y: floor((bounds.height - spriteSize.height) / 2) + 1 + spriteYOffset
        )

        drawPixelShadow(origin: origin)
        drawPixelTail(origin: origin, cellSize: cellSize)
        drawPixelRows(rows, origin: origin, cellSize: cellSize)
        if state == .ready {
            drawPixelActionBadge()
        }
        if state == .thinking {
            drawThinkingBadge()
        }
    }

    private func spriteYOffset() -> CGFloat {
        switch state {
        case .idle:
            return animationFrame % 90 >= 72 ? 0.5 : 0
        case .run:
            return (animationFrame / 4) % 2 == 0 ? 1 : 0
        case .ready:
            return animationFrame % 64 < 8 ? 0.75 : 0
        case .thinking:
            let phase = animationFrame % 32
            if phase < 8 { return 0 }
            if phase < 16 { return 0.5 }
            if phase < 24 { return 1 }
            return 0.5
        }
    }

    private func idleFaceOffset() -> Int {
        switch (animationFrame / 32) % 4 {
        case 1:
            return -1
        case 3:
            return 1
        default:
            return 0
        }
    }

    private func spriteRows() -> [String] {
        switch state {
        case .idle:
            if emotion != .neutral {
                return emotionSpriteRows(emotion)
            }
            return spriteRows(faceOffset: idleFaceOffset(), noseWidth: 1)
        case .run:
            if (animationFrame / 5) % 2 == 0 {
                return [
                    "................",
                    "..WG........GW..",
                    ".GWWW......WWWG.",
                    ".GWWWWWWWWWWWWG.",
                    "GWWWWWWWWWWWWWWG",
                    "WWWWKKWWWWKKWWWW",
                    "WWWWKKWWWWKKWWWW",
                    "GWWWWWWPWWWWWWWG",
                    "WWGWWWWWWWWWWGWW",
                    ".GWWWWWWWWWWWWG.",
                    "...WW......WWW..",
                    "................"
                ]
            } else {
                return [
                    "................",
                    "..WG........GW..",
                    ".GWWW......WWWG.",
                    ".GWWWWWWWWWWWWG.",
                    "GWWWWWWWWWWWWWWG",
                    "WWWWKKWWWWKKWWWW",
                    "WWWWKKWWWWKKWWWW",
                    "GWWWWWWPWWWWWWWG",
                    "WWGWWWWWWWWWWGWW",
                    ".GWWWWWWWWWWWWG.",
                    "..WWW......WW...",
                    "................"
                ]
            }
        case .ready:
            return spriteRows(faceOffset: 0, noseWidth: 1)
        case .thinking:
            return spriteRows(faceOffset: 0, noseWidth: 1)
        }
    }

    private func emotionSpriteRows(_ emotion: AskNugumiEmotion) -> [String] {
        switch emotion {
        case .neutral:
            return spriteRows(faceOffset: 0, noseWidth: 1)
        case .happy:
            return spriteRows(
                eyeRow: "WWWKWWWWWWKWWWWW",
                noseRow: "GWWWWWPPWWWWWWWG"
            )
        case .surprised:
            return spriteRows(
                eyeRow: "WWWWKKWWWWKKWWWW",
                noseRow: "GWWWWWKKWWWWWWWG"
            )
        case .confused:
            return spriteRows(
                eyeRow: "WWWKKWWWWWKWWWWW",
                noseRow: "GWWWWWWPWWWWWWWG"
            )
        case .concerned:
            return spriteRows(
                eyeRow: "WWWWKWWWWWWKWWWW",
                noseRow: "GWWWWKKWWWWWWWWG"
            )
        }
    }

    private func spriteRows(eyeRow: String, noseRow: String) -> [String] {
        [
            "................",
            "..WG........GW..",
            ".GWWW......WWWG.",
            ".GWWWWWWWWWWWWG.",
            "GWWWWWWWWWWWWWWG",
            eyeRow,
            eyeRow,
            noseRow,
            "WWGWWWWWWWWWWGWW",
            ".GWWWWWWWWWWWWG.",
            "...WW......WW...",
            "................"
        ]
    }

    private func spriteRows(faceOffset: Int, noseWidth: Int) -> [String] {
        let eyeRow: String
        let noseRow: String
        switch faceOffset {
        case ..<0:
            eyeRow = "WWWKKWWWWKKWWWWW"
            noseRow = noseWidth == 1 ? "GWWWWWPWWWWWWWWG" : "GWWWWWPPWWWWWWWG"
        case 1...:
            eyeRow = "WWWWWKKWWWWKKWWW"
            noseRow = noseWidth == 1 ? "GWWWWWWWPWWWWWWG" : "GWWWWWWPPWWWWWWG"
        default:
            eyeRow = "WWWWKKWWWWKKWWWW"
            noseRow = noseWidth == 1 ? "GWWWWWWPWWWWWWWG" : "GWWWWWPPWWWWWWG."
        }

        return spriteRows(eyeRow: eyeRow, noseRow: noseRow)
    }

    private func drawPixelRows(_ rows: [String], origin: NSPoint, cellSize: CGFloat) {
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, pixel) in row.enumerated() {
                guard let color = color(for: pixel) else { continue }
                color.setFill()
                let rect = NSRect(
                    x: origin.x + CGFloat(columnIndex) * cellSize,
                    y: origin.y + CGFloat(rows.count - rowIndex - 1) * cellSize,
                    width: cellSize,
                    height: cellSize
                )
                NSBezierPath(rect: rect).fill()
            }
        }
    }

    private func drawPixelTail(origin: NSPoint, cellSize: CGFloat) {
        let cells: [(Int, Int)]
        switch state {
        case .idle:
            switch (animationFrame / 24) % 3 {
            case 0:
                cells = [(7, 9), (7, 10), (8, 11), (9, 12), (10, 12)]
            case 1:
                cells = [(7, 9), (8, 10), (8, 11), (8, 12), (9, 12)]
            default:
                cells = [(7, 9), (8, 10), (7, 11), (6, 12), (5, 12)]
            }
        case .run:
            if (animationFrame / 5) % 2 == 0 {
                cells = [(7, 9), (7, 10), (8, 11), (10, 12), (11, 12)]
            } else {
                cells = [(8, 9), (8, 10), (7, 11), (5, 12), (4, 12)]
            }
        case .ready, .thinking:
            switch (animationFrame / 16) % 2 {
            case 0:
                cells = [(7, 9), (8, 10), (8, 11), (9, 12), (10, 12)]
            default:
                cells = [(7, 9), (7, 10), (8, 11), (8, 12), (9, 12)]
            }
        }

        let tailColor = NSColor(srgbRed: 0.93, green: 0.94, blue: 0.90, alpha: 1.0)
        let tailShade = NSColor(srgbRed: 0.68, green: 0.72, blue: 0.73, alpha: 1.0)
        for (index, cell) in cells.enumerated() {
            (index == cells.count - 1 ? tailShade : tailColor).setFill()
            let rect = NSRect(
                x: origin.x + CGFloat(cell.0) * cellSize,
                y: origin.y + CGFloat(cell.1) * cellSize,
                width: cellSize,
                height: cellSize
            )
            NSBezierPath(rect: rect).fill()
        }
    }

    private func drawPixelShadow(origin: NSPoint) {
        NSColor(calibratedWhite: 0.0, alpha: 0.18).setFill()
        NSBezierPath(rect: NSRect(x: origin.x + 4, y: origin.y - 1, width: 22, height: 2)).fill()
        NSBezierPath(rect: NSRect(x: origin.x + 8, y: origin.y - 3, width: 14, height: 2)).fill()
    }

    private func drawPixelActionBadge() {
        switch mode {
        case .selection:
            drawTranslateBadge()
        case .draftMessage:
            drawRewriteBadge()
        case .smartReply:
            drawReplyBadge()
        }
    }

    private func badgeOrigin(width: CGFloat, height: CGFloat) -> NSPoint {
        NSPoint(x: bounds.width - width, y: bounds.height - height)
    }

    private func drawTranslateBadge() {
        let frame = NSRect(origin: badgeOrigin(width: 19, height: 14), size: NSSize(width: 19, height: 14))

        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = true
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        NSColor(calibratedWhite: 0.0, alpha: 0.25).setFill()
        NSBezierPath(roundedRect: NSRect(x: frame.minX + 2, y: frame.minY - 1, width: 15, height: 3), xRadius: 1.5, yRadius: 1.5).fill()

        let borderColor = NSColor(srgbRed: 0.42, green: 0.46, blue: 0.47, alpha: 1.0)
        let shape = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
        borderColor.setFill()
        shape.fill()

        let inner = frame.insetBy(dx: 1.5, dy: 1.5)
        let leftRect = NSRect(x: inner.minX, y: inner.minY, width: inner.width * 0.52, height: inner.height)
        let rightRect = NSRect(x: leftRect.maxX, y: inner.minY, width: inner.maxX - leftRect.maxX, height: inner.height)

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor(srgbRed: 0.02, green: 0.55, blue: 0.76, alpha: 1.0).setFill()
        NSBezierPath(rect: leftRect).fill()
        NSColor(srgbRed: 0.80, green: 0.86, blue: 0.87, alpha: 1.0).setFill()
        NSBezierPath(rect: rightRect).fill()
        NSGraphicsContext.restoreGraphicsState()

        drawBadgeText("A", color: .white, fontSize: 8.5, in: NSRect(x: inner.minX - 0.5, y: inner.minY + 0.5, width: leftRect.width, height: inner.height))
        drawBadgeText("文", color: NSColor(srgbRed: 0.19, green: 0.34, blue: 0.39, alpha: 1.0), fontSize: 8, in: NSRect(x: rightRect.minX - 0.5, y: rightRect.minY + 0.5, width: rightRect.width + 1, height: rightRect.height))
    }

    private func drawRewriteBadge() {
        let frame = NSRect(origin: badgeOrigin(width: 18, height: 15), size: NSSize(width: 18, height: 15))

        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = true
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        NSColor(calibratedWhite: 0.0, alpha: 0.25).setFill()
        NSBezierPath(roundedRect: NSRect(x: frame.minX + 2, y: frame.minY - 1, width: 14, height: 3), xRadius: 1.5, yRadius: 1.5).fill()

        let outline = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
        NSColor(srgbRed: 0.42, green: 0.46, blue: 0.47, alpha: 1.0).setFill()
        outline.fill()

        let inner = frame.insetBy(dx: 1.7, dy: 1.7)
        NSColor(srgbRed: 0.98, green: 0.98, blue: 0.96, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: inner, xRadius: 2, yRadius: 2).fill()
        drawBadgeText("✎", color: NSColor(srgbRed: 0.14, green: 0.18, blue: 0.20, alpha: 1.0), fontSize: 10.5, in: NSRect(x: inner.minX, y: inner.minY + 0.5, width: inner.width, height: inner.height))
    }

    private func drawReplyBadge() {
        let origin = badgeOrigin(width: 18, height: 16)
        let bubbleRect = NSRect(x: origin.x, y: origin.y + 3, width: 18, height: 13)

        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = true
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        NSColor(calibratedWhite: 0.0, alpha: 0.22).setFill()
        NSBezierPath(roundedRect: NSRect(x: origin.x + 2, y: origin.y + 1, width: 14, height: 3), xRadius: 1.5, yRadius: 1.5).fill()

        let outline = NSBezierPath(roundedRect: bubbleRect, xRadius: 3, yRadius: 3)
        outline.move(to: NSPoint(x: bubbleRect.midX - 2, y: bubbleRect.minY + 1))
        outline.line(to: NSPoint(x: bubbleRect.midX, y: origin.y))
        outline.line(to: NSPoint(x: bubbleRect.midX + 2, y: bubbleRect.minY + 1))
        outline.close()
        NSColor(srgbRed: 0.42, green: 0.46, blue: 0.47, alpha: 1.0).setFill()
        outline.fill()

        let fill = NSBezierPath(roundedRect: bubbleRect.insetBy(dx: 1.7, dy: 1.7), xRadius: 2, yRadius: 2)
        NSColor(srgbRed: 0.98, green: 0.98, blue: 0.96, alpha: 1.0).setFill()
        fill.fill()
        let tailFill = NSBezierPath()
        tailFill.move(to: NSPoint(x: bubbleRect.midX - 1.2, y: bubbleRect.minY + 2))
        tailFill.line(to: NSPoint(x: bubbleRect.midX, y: origin.y + 2))
        tailFill.line(to: NSPoint(x: bubbleRect.midX + 1.2, y: bubbleRect.minY + 2))
        tailFill.close()
        tailFill.fill()

        NSColor(srgbRed: 0.12, green: 0.13, blue: 0.13, alpha: 1.0).setFill()
        for x in [bubbleRect.minX + 5, bubbleRect.midX, bubbleRect.maxX - 5] {
            NSBezierPath(ovalIn: NSRect(x: x - 1.1, y: bubbleRect.midY - 1.1, width: 2.2, height: 2.2)).fill()
        }
    }

    private func drawThinkingBadge() {
        let origin = badgeOrigin(width: 18, height: 16)
        let bubbleRect = NSRect(x: origin.x, y: origin.y + 3, width: 18, height: 13)

        let context = NSGraphicsContext.current
        let previousAntialiasing = context?.shouldAntialias
        context?.shouldAntialias = true
        defer {
            if let previousAntialiasing {
                context?.shouldAntialias = previousAntialiasing
            }
        }

        NSColor(calibratedWhite: 0.0, alpha: 0.22).setFill()
        NSBezierPath(roundedRect: NSRect(x: origin.x + 2, y: origin.y + 1, width: 14, height: 3), xRadius: 1.5, yRadius: 1.5).fill()

        let outline = NSBezierPath(roundedRect: bubbleRect, xRadius: 3, yRadius: 3)
        outline.move(to: NSPoint(x: bubbleRect.midX - 2, y: bubbleRect.minY + 1))
        outline.line(to: NSPoint(x: bubbleRect.midX, y: origin.y))
        outline.line(to: NSPoint(x: bubbleRect.midX + 2, y: bubbleRect.minY + 1))
        outline.close()
        NSColor(srgbRed: 0.42, green: 0.46, blue: 0.47, alpha: 1.0).setFill()
        outline.fill()

        let fill = NSBezierPath(roundedRect: bubbleRect.insetBy(dx: 1.7, dy: 1.7), xRadius: 2, yRadius: 2)
        NSColor(srgbRed: 0.98, green: 0.98, blue: 0.96, alpha: 1.0).setFill()
        fill.fill()
        let tailFill = NSBezierPath()
        tailFill.move(to: NSPoint(x: bubbleRect.midX - 1.2, y: bubbleRect.minY + 2))
        tailFill.line(to: NSPoint(x: bubbleRect.midX, y: origin.y + 2))
        tailFill.line(to: NSPoint(x: bubbleRect.midX + 1.2, y: bubbleRect.minY + 2))
        tailFill.close()
        tailFill.fill()

        // Animated dots: cycle one bright dot at a time
        let activeDot = (animationFrame / 8) % 3
        for (index, x) in [bubbleRect.minX + 5, bubbleRect.midX, bubbleRect.maxX - 5].enumerated() {
            let isActive = index == activeDot
            let color = isActive
                ? NSColor(srgbRed: 0.12, green: 0.13, blue: 0.13, alpha: 1.0)
                : NSColor(srgbRed: 0.55, green: 0.57, blue: 0.58, alpha: 1.0)
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 1.1, y: bubbleRect.midY - 1.1, width: 2.2, height: 2.2)).fill()
        }
    }

    private func drawBadgeText(_ text: String, color: NSColor, fontSize: CGFloat, in rect: NSRect) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .black),
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func color(for pixel: Character) -> NSColor? {
        switch pixel {
        case "W":
            return NSColor(srgbRed: 0.95, green: 0.96, blue: 0.92, alpha: 1)
        case "G":
            return NSColor(srgbRed: 0.70, green: 0.75, blue: 0.76, alpha: 1)
        case "K":
            return NSColor(srgbRed: 0.07, green: 0.09, blue: 0.12, alpha: 1)
        case "P":
            return NSColor(srgbRed: 0.96, green: 0.55, blue: 0.65, alpha: 1)
        case "B":
            return NSColor(srgbRed: 0.97, green: 0.96, blue: 0.86, alpha: 1)
        case "D":
            return NSColor(srgbRed: 0.08, green: 0.16, blue: 0.20, alpha: 1)
        default:
            return nil
        }
    }

    private func tooltip(for state: State, mode: TranslationMode) -> String {
        switch state {
        case .idle, .run:
            return "Nugumi pet"
        case .ready:
            switch mode {
            case .selection:
                return "Translate selection - right-click to Rewrite, Tab to switch to Reply"
            case .draftMessage:
                return "Rewrite my text - Tab to switch to Reply"
            case .smartReply:
                return "Generate reply - Tab to switch back"
            }
        case .thinking:
            return "Thinking…"
        }
    }
}

@MainActor
final class FloatingTranslateButtonController {
    private let panel: NSPanel
    private let selectedText: String
    private let onTranslate: (String) -> Void
    private let onRewrite: (String) -> Void
    private let onSmartReply: (String) -> Void
    private let buttonView: FloatingTranslateButtonView
    private var currentMode: TranslationMode
    private var tabInterceptor: TabKeyInterceptor?

    init(
        screenPoint: NSPoint,
        selectedText: String,
        initialMode: TranslationMode,
        onTranslate: @escaping (String) -> Void,
        onRewrite: @escaping (String) -> Void,
        onSmartReply: @escaping (String) -> Void
    ) {
        self.selectedText = selectedText
        self.onTranslate = onTranslate
        self.onRewrite = onRewrite
        self.onSmartReply = onSmartReply
        self.currentMode = initialMode

        let buttonSize = AskNugumiFloatingTargetPresentationPolicy.buttonSize
        let shadowPadding = AskNugumiFloatingTargetPresentationPolicy.shadowPadding
        let totalSize = AskNugumiFloatingTargetPresentationPolicy.totalSize
        let origin = NSPoint(
            x: screenPoint.x + 5 - shadowPadding,
            y: screenPoint.y - buttonSize - 5 - shadowPadding
        )
        panel = NSPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: totalSize, height: totalSize)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false

        let container = NSView(frame: NSRect(origin: .zero, size: NSSize(width: totalSize, height: totalSize)))
        buttonView = FloatingTranslateButtonView(initialMode: initialMode)
        buttonView.frame = NSRect(x: shadowPadding, y: shadowPadding, width: buttonSize, height: buttonSize)
        buttonView.wantsLayer = true
        container.addSubview(buttonView)
        panel.contentView = container

        buttonView.onClick = { [weak self] in
            guard let self else { return }
            self.invokeCurrentMode()
        }
        buttonView.onRightClick = { [weak self] in
            self?.invokeRewriteMode()
        }
    }

    func show() {
        panel.orderFrontRegardless()
        let interceptor = TabKeyInterceptor { [weak self] in
            self?.toggleMode()
        }
        tabInterceptor = interceptor
        interceptor.enable()
    }

    func close() {
        tabInterceptor?.disable()
        tabInterceptor = nil
        panel.close()
    }

    func setLoading() {
        panel.ignoresMouseEvents = true
        tabInterceptor?.disable()
        tabInterceptor = nil
        buttonView.setLoading(true)
    }

    func pointAt(_ targetPoint: NSPoint, visibleFrame: NSRect) {
        let presentation = AskNugumiFloatingTargetPresentationPolicy.presentation(
            targetPoint: targetPoint,
            visibleFrame: visibleFrame
        )
        panel.ignoresMouseEvents = true
        tabInterceptor?.disable()
        tabInterceptor = nil
        buttonView.setTargetArrow(angle: presentation.arrowAngleRadians)
        panel.orderFrontRegardless()

        // Slower glide so the trip from the pet to the target reads clearly,
        // then a pop on arrival so the destination is unmistakable.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.42
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(presentation.panelFrame, display: true)
        }, completionHandler: {
            // AppKit invokes this on the main thread.
            MainActor.assumeIsolated { [weak self] in
                self?.playArrivalPulse()
            }
        })
    }

    /// Quick scale "pop" on the button, centered, after it lands on target.
    private func playArrivalPulse() {
        let base = AskNugumiFloatingTargetPresentationPolicy.buttonSize
        let pad = AskNugumiFloatingTargetPresentationPolicy.shadowPadding
        let center = pad + base / 2
        let grownSide = base * 1.3
        let grown = NSRect(
            x: center - grownSide / 2,
            y: center - grownSide / 2,
            width: grownSide,
            height: grownSide
        )
        let normal = NSRect(x: pad, y: pad, width: base, height: base)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            buttonView.animator().frame = grown
        }, completionHandler: {
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    self.buttonView.animator().frame = normal
                }
            }
        })
    }

    private func toggleMode() {
        currentMode = (currentMode == .smartReply) ? .selection : .smartReply
        buttonView.apply(mode: currentMode)
    }

    private func invokeCurrentMode() {
        switch currentMode {
        case .selection:
            onTranslate(selectedText)
        case .draftMessage:
            onRewrite(selectedText)
        case .smartReply:
            onSmartReply(selectedText)
        }
    }

    private func invokeRewriteMode() {
        guard currentMode == .selection else { return }
        onRewrite(selectedText)
    }
}

private final class AskPromptTextField: NSTextField {
    var onEscape: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = AskPromptTextFieldCell(textCell: "")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

private final class AskPromptTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        verticallyCenteredRect(forBounds: rect)
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: verticallyCenteredRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: verticallyCenteredRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
    }

    private func verticallyCenteredRect(forBounds rect: NSRect) -> NSRect {
        var centeredRect = super.drawingRect(forBounds: rect)
        let textHeight = cellSize(forBounds: rect).height
        centeredRect.origin.y = rect.origin.y + (rect.height - textHeight) / 2
        centeredRect.size.height = textHeight
        return centeredRect
    }
}

private final class AskPromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class AskPromptChromeView: NSView {
    var cornerRadius: CGFloat = 16

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()

        if let leftGlow = NSGradient(colors: [
            NSColor(srgbRed: 0.08, green: 0.32, blue: 1.0, alpha: 0.22),
            NSColor(srgbRed: 0.08, green: 0.32, blue: 1.0, alpha: 0.08),
            NSColor.clear
        ]) {
            let glowRect = NSRect(x: rect.minX, y: rect.minY, width: 150, height: rect.height)
            leftGlow.draw(in: glowRect, angle: 0)
        }

        if let topSheen = NSGradient(colors: [
            NSColor(calibratedWhite: 1.0, alpha: 0.22),
            NSColor(calibratedWhite: 1.0, alpha: 0.04),
            NSColor.clear
        ]) {
            let sheenRect = NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
            topSheen.draw(in: sheenRect, angle: 90)
        }

        NSGraphicsContext.restoreGraphicsState()

        NSColor(calibratedWhite: 1.0, alpha: 0.28).setStroke()
        path.lineWidth = 0.9
        path.stroke()

        let innerRect = bounds.insetBy(dx: 2.5, dy: 2.5)
        let innerPath = NSBezierPath(
            roundedRect: innerRect,
            xRadius: max(0, cornerRadius - 2),
            yRadius: max(0, cornerRadius - 2)
        )
        NSColor(calibratedWhite: 1.0, alpha: 0.08).setStroke()
        innerPath.lineWidth = 0.8
        innerPath.stroke()
    }
}

@MainActor
final class AskPromptController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private static let textMovementUserInfoKey = "NSTextMovement"

    private let panel: NSPanel
    private let textField: AskPromptTextField
    private let onSubmit: (String) -> Void
    private let onClose: () -> Void
    private var didClose = false
    private var isSubmitting = false
    private var globalOutsideClickMonitor: Any?
    private var localOutsideClickMonitor: Any?
    private var promptInput = AskNugumiPromptInputBuffer()
    private var keyInterceptor: PromptKeyInterceptor?

    var isVisible: Bool { panel.isVisible }

    init(
        near screenPoint: NSPoint,
        onSubmit: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onSubmit = onSubmit
        self.onClose = onClose

        let layout = AskNugumiFloatingPromptMetrics.layout
        let origin = Self.origin(near: screenPoint, size: layout.panelSize)
        panel = AskPromptPanel(
            contentRect: NSRect(origin: origin, size: layout.panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        textField = AskPromptTextField(frame: .zero)

        super.init()

        panel.delegate = self
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: panel)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true

        buildUI()
    }

    func show() {
        promptInput.reset()
        renderPromptText()
        textField.isEnabled = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textField)
        installKeyInterceptor()
        installOutsideClickMonitors()
    }

    func setLoading() {
        removeKeyInterceptor()
        panel.sharingType = .none
        textField.isEnabled = false
        promptInput.reset()
        renderPromptText()
        setPlaceholder("Looking...")
    }

    func showError(_ message: String) {
        isSubmitting = false
        textField.isEnabled = true
        promptInput.reset()
        renderPromptText()
        setPlaceholder(message)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textField)
        installKeyInterceptor()
    }

    func close() {
        guard !didClose else { return }
        didClose = true
        removeKeyInterceptor()
        removeOutsideClickMonitors()
        panel.close()
        onClose()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, !self.didClose else { return }
            self.didClose = true
            self.removeKeyInterceptor()
            self.removeOutsideClickMonitors()
            self.onClose()
        }
    }

    deinit {
        keyInterceptor?.disable()
        keyInterceptor = nil
        if let globalOutsideClickMonitor {
            NSEvent.removeMonitor(globalOutsideClickMonitor)
        }
        if let localOutsideClickMonitor {
            NSEvent.removeMonitor(localOutsideClickMonitor)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard textMovement(from: notification) == NSTextMovement.return.rawValue else {
            return
        }
        promptInput.replace(with: textField.stringValue)
        submit()
    }

    private func buildUI() {
        let layout = AskNugumiFloatingPromptMetrics.layout
        let rootView = NSView(frame: NSRect(origin: .zero, size: layout.panelSize))
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.layer?.masksToBounds = false

        let glass = GlassHostView(
            frame: layout.pillFrame,
            cornerRadius: layout.cornerRadius,
            tintColor: nil,
            style: .regular
        )
        glass.autoresizingMask = [.width, .height]
        glass.wantsLayer = true
        glass.layer?.masksToBounds = false
        glass.layer?.shadowColor = NSColor.black.cgColor
        glass.layer?.shadowOpacity = 0.16
        glass.layer?.shadowRadius = 10
        glass.layer?.shadowOffset = CGSize(width: 0, height: -2)
        glass.layer?.shadowPath = CGPath(
            roundedRect: NSRect(origin: .zero, size: layout.pillFrame.size),
            cornerWidth: layout.cornerRadius,
            cornerHeight: layout.cornerRadius,
            transform: nil
        )
        rootView.addSubview(glass)

        let chrome = AskPromptChromeView(frame: glass.contentView.bounds)
        chrome.cornerRadius = layout.cornerRadius
        chrome.autoresizingMask = [.width, .height]
        glass.contentView.addSubview(chrome)

        textField.delegate = self
        textField.onEscape = { [weak self] in
            self?.close()
        }
        setPlaceholder("Ask Nugumi")
        textField.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        textField.textColor = NSColor(calibratedWhite: 1.0, alpha: 0.88)
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.backgroundColor = .clear
        textField.focusRingType = .none
        textField.usesSingleLineMode = true
        textField.maximumNumberOfLines = 1
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.cell?.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(textField)

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(
                equalTo: glass.contentView.leadingAnchor,
                constant: layout.textFrame.minX - layout.pillFrame.minX
            ),
            textField.trailingAnchor.constraint(
                equalTo: glass.contentView.trailingAnchor,
                constant: -(layout.pillFrame.maxX - layout.textFrame.maxX)
            ),
            textField.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
            textField.heightAnchor.constraint(equalToConstant: layout.textFrame.height)
        ])

        panel.contentView = rootView
    }

    private func submit() {
        guard textField.isEnabled, !isSubmitting else { return }
        if promptInput.text != textField.stringValue {
            promptInput.replace(with: textField.stringValue)
        }
        let text = promptInput.trimmedText
        guard !text.isEmpty else {
            panel.makeFirstResponder(textField)
            return
        }
        isSubmitting = true
        removeKeyInterceptor()
        onSubmit(text)
    }

    private func renderPromptText() {
        textField.stringValue = promptInput.text
    }

    private func insertPromptText(_ text: String) {
        guard textField.isEnabled, !isSubmitting else { return }
        promptInput.insert(text)
        renderPromptText()
    }

    private func deletePromptBackward() {
        guard textField.isEnabled, !isSubmitting else { return }
        promptInput.deleteBackward()
        renderPromptText()
    }

    private func pastePromptText() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return
        }
        insertPromptText(text)
    }

    private func selectAllPromptText() {
        guard textField.isEnabled, !isSubmitting else { return }
        promptInput.selectAll()
    }

    private func installKeyInterceptor() {
        guard keyInterceptor == nil else { return }
        let interceptor = PromptKeyInterceptor(
            onInsertText: { [weak self] text in
                self?.insertPromptText(text)
            },
            onBackspace: { [weak self] in
                self?.deletePromptBackward()
            },
            onSubmit: { [weak self] in
                self?.submit()
            },
            onCancel: { [weak self] in
                self?.close()
            },
            onPaste: { [weak self] in
                self?.pastePromptText()
            },
            onSelectAll: { [weak self] in
                self?.selectAllPromptText()
            }
        )
        keyInterceptor = interceptor
        interceptor.enable()
    }

    private func removeKeyInterceptor() {
        keyInterceptor?.disable()
        keyInterceptor = nil
    }

    private func setPlaceholder(_ text: String) {
        textField.placeholderString = text
        textField.placeholderAttributedString = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.44),
                .font: textField.font ?? NSFont.systemFont(ofSize: 14, weight: .regular)
            ]
        )
    }

    private func textMovement(from notification: Notification) -> Int? {
        notification.userInfo?[Self.textMovementUserInfoKey] as? Int
    }

    private func installOutsideClickMonitors() {
        guard globalOutsideClickMonitor == nil, localOutsideClickMonitor == nil else {
            return
        }

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.closeIfClickIsOutside(event)
        }

        localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.closeIfClickIsOutside(event)
            return event
        }
    }

    private func removeOutsideClickMonitors() {
        if let globalOutsideClickMonitor {
            NSEvent.removeMonitor(globalOutsideClickMonitor)
            self.globalOutsideClickMonitor = nil
        }

        if let localOutsideClickMonitor {
            NSEvent.removeMonitor(localOutsideClickMonitor)
            self.localOutsideClickMonitor = nil
        }
    }

    private func closeIfClickIsOutside(_ event: NSEvent) {
        guard panel.isVisible else {
            return
        }

        let screenPoint = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        guard !panel.frame.insetBy(dx: -4, dy: -4).contains(screenPoint) else {
            return
        }

        close()
    }

    private static func origin(near point: NSPoint, size: NSSize) -> NSPoint {
        let visibleFrame = NSScreen.visibleFrame(containing: point)
        let edgeMargin = AskNugumiFloatingPromptMetrics.edgeMargin
        let preferredGap: CGFloat = 10
        let preferredBelowY = point.y - size.height - preferredGap
        let preferredAboveY = point.y + preferredGap
        let desiredY: CGFloat
        if preferredBelowY < visibleFrame.minY + edgeMargin,
           preferredAboveY + size.height <= visibleFrame.maxY - edgeMargin {
            desiredY = preferredAboveY
        } else {
            desiredY = preferredBelowY
        }

        return NSPoint(
            x: clamped(point.x - size.width / 2, min: visibleFrame.minX + edgeMargin, max: visibleFrame.maxX - size.width - edgeMargin),
            y: clamped(desiredY, min: visibleFrame.minY + edgeMargin, max: visibleFrame.maxY - size.height - edgeMargin)
        )
    }

    private static func clamped(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        guard minValue <= maxValue else {
            return (minValue + maxValue) / 2
        }
        return Swift.min(Swift.max(value, minValue), maxValue)
    }
}

private final class RightClickableButton: NSButton {
    var onRightClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}

private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class FloatingTranslateButtonView: NSView {
    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    private let actionButton = RightClickableButton()
    private let progressIndicator = NSProgressIndicator()
    private var currentMode: TranslationMode
    private var isLoading = false

    init(initialMode: TranslationMode) {
        self.currentMode = initialMode
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        wantsLayer = true
        buildUI()
        apply(mode: initialMode)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer = self.layer else { return }
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.38
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: -3)
        layer.shadowPath = CGPath(ellipseIn: bounds, transform: nil)
        layer.masksToBounds = false
    }

    private func buildUI() {
        let glass = GlassHostView(
            frame: bounds,
            cornerRadius: bounds.width / 2,
            tintColor: NSColor(srgbRed: 0.06, green: 0.12, blue: 0.22, alpha: 0.55),
            style: .regular
        )
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)

        actionButton.target = self
        actionButton.action = #selector(buttonTapped)
        actionButton.onRightClick = { [weak self] in
            self?.onRightClick?()
        }
        actionButton.frame = bounds
        actionButton.autoresizingMask = [.width, .height]
        actionButton.isBordered = false
        actionButton.contentTintColor = .white
        actionButton.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        actionButton.imageScaling = .scaleNone
        glass.contentView.addSubview(actionButton)

        let indicatorSize: CGFloat = 16
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        progressIndicator.appearance = NSAppearance(named: .darkAqua)
        progressIndicator.frame = NSRect(
            x: (bounds.width - indicatorSize) / 2,
            y: (bounds.height - indicatorSize) / 2,
            width: indicatorSize,
            height: indicatorSize
        )
        progressIndicator.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        progressIndicator.isHidden = true
        glass.contentView.addSubview(progressIndicator)
    }

    func apply(mode: TranslationMode) {
        currentMode = mode
        guard !isLoading else { return }
        applyModeVisuals()
    }

    func setLoading(_ loading: Bool) {
        guard isLoading != loading else { return }
        isLoading = loading
        if loading {
            actionButton.isHidden = true
            actionButton.toolTip = nil
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            actionButton.isHidden = false
            applyModeVisuals()
        }
    }

    func setTargetArrow(angle: CGFloat) {
        isLoading = false
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        actionButton.isHidden = false
        actionButton.image = Self.targetArrowImage(angle: angle)
        actionButton.title = ""
        actionButton.imagePosition = .imageOnly
        actionButton.toolTip = "Target"
    }

    private func applyModeVisuals() {
        switch currentMode {
        case .selection:
            actionButton.image = nil
            actionButton.title = "あ"
            actionButton.imagePosition = .noImage
            actionButton.toolTip = "Translate selection — right-click to Rewrite, Tab to switch to Reply"
        case .draftMessage:
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            if let image = NSImage(systemSymbolName: "text.insert", accessibilityDescription: "Rewrite my text")
                ?? NSImage(systemSymbolName: "pencil.line", accessibilityDescription: "Rewrite my text") {
                actionButton.image = image.withSymbolConfiguration(config)
                actionButton.title = ""
                actionButton.imagePosition = .imageOnly
            } else {
                actionButton.image = nil
                actionButton.title = "✎"
                actionButton.imagePosition = .noImage
            }
            actionButton.toolTip = "Rewrite my text — Tab to switch to Reply"
        case .smartReply:
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            actionButton.image = NSImage(
                systemSymbolName: "bubble.left.fill",
                accessibilityDescription: "Generate reply or answer"
            )?.withSymbolConfiguration(config)
            actionButton.title = ""
            actionButton.imagePosition = .imageOnly
            actionButton.toolTip = "Generate reply — Tab to switch back"
        }
    }

    @objc private func buttonTapped() {
        onClick?()
    }

    private static func targetArrowImage(angle: CGFloat) -> NSImage {
        let imageSize = NSSize(width: 18, height: 18)
        let image = NSImage(size: imageSize)
        image.lockFocus()
        NSGraphicsContext.saveGraphicsState()

        let transform = NSAffineTransform()
        transform.translateX(by: imageSize.width / 2, yBy: imageSize.height / 2)
        transform.rotate(byRadians: angle)
        transform.concat()

        let shaft = NSBezierPath()
        shaft.lineWidth = 2.2
        shaft.lineCapStyle = .round
        shaft.move(to: NSPoint(x: -5.5, y: 0))
        shaft.line(to: NSPoint(x: 4.3, y: 0))
        NSColor.white.setStroke()
        shaft.stroke()

        let head = NSBezierPath()
        head.move(to: NSPoint(x: 6.2, y: 0))
        head.line(to: NSPoint(x: 0.6, y: 4.3))
        head.line(to: NSPoint(x: 0.6, y: -4.3))
        head.close()
        NSColor.white.setFill()
        head.fill()

        NSGraphicsContext.restoreGraphicsState()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

final class TranslationPanelController {
    enum Side { case left, right }

    enum Anchor {
        // Click point with explicit side. .right = panel goes right of point
        // (default for LTR drags / unknown direction). .left = panel goes left
        // of point (used when user dragged right-to-left in non-AX apps).
        case point(NSPoint, panelSide: Side)
        case selection(NSRect)      // selection rect, NSScreen coords (bottom-left origin)
    }

    private static let sideGap: CGFloat = 10
    private static let edgeMargin: CGFloat = 16

    private let panel: NSPanel
    private let contentView: TranslationContentView
    private let anchor: Anchor
    private var activeRequestID = UUID()
    private var globalOutsideClickMonitor: Any?
    private var localOutsideClickMonitor: Any?
    private var commandCopyInterceptor: CommandCopyInterceptor?
    private var returnKeyInterceptor: ReturnKeyInterceptor?
    private var didClose = false
    private let onClose: (() -> Void)?
    private let replaceShortcutSourcePID: pid_t?

    var panelFrame: NSRect { panel.frame }
    var isVisible: Bool { panel.isVisible }

    private let loadingPlaceholder: String

    init(
        anchor: Anchor,
        sourceText: String,
        targetLanguage: TranslationLanguage,
        resultLabel: String? = nil,
        loadingPlaceholder: String = "Translating",
        onTargetLanguageSelected: ((TranslationLanguage) -> Void)? = nil,
        onReplace: ((String) -> Void)? = nil,
        replaceShortcutSourcePID: pid_t? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.loadingPlaceholder = loadingPlaceholder
        self.anchor = anchor
        self.onClose = onClose
        self.replaceShortcutSourcePID = replaceShortcutSourcePID
        let referencePoint = Self.anchorReferencePoint(for: anchor)
        let visibleFrame = NSScreen.visibleFrame(containing: referencePoint)
        let panelHeight = min(
            TranslationContentView.preferredHeight(sourceText: sourceText, resultText: "\(loadingPlaceholder)..."),
            visibleFrame.height - 32
        )
        let panelSize = NSSize(width: TranslationContentView.preferredWidth, height: panelHeight)
        let origin = Self.panelOrigin(anchor: anchor, panelSize: panelSize, visibleFrame: visibleFrame)
        let anchorY = TranslationContentView.anchorY(
            for: Self.anchorY(for: anchor),
            panelOriginY: origin.y,
            panelHeight: panelHeight
        )

        contentView = TranslationContentView(
            sourceText: sourceText,
            targetLanguage: targetLanguage,
            resultLabel: resultLabel,
            anchorY: anchorY,
            onTargetLanguageSelected: onTargetLanguageSelected,
            onReplace: onReplace
        )
        panel = NSPanel(
            contentRect: NSRect(origin: origin, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        InvisibilityState.apply(to: panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        // Keeps the source app's text view key so the action buttons fire on
        // the first click. Without this, the panel grabs key on initial click
        // and the button-tap is swallowed by the activation.
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = contentView
        contentView.onClose = { [weak self] in self?.close() }
        contentView.onNeedsResize = { [weak self] in
            self?.resizeToFitContent(animated: true)
        }
    }

    deinit {
        removeOutsideClickMonitors()
        removeCommandCopyInterceptor()
        removeReturnKeyInterceptor()
    }

    @discardableResult
    func showLoading(targetLanguage: TranslationLanguage? = nil) -> UUID {
        activeRequestID = UUID()
        if let targetLanguage {
            contentView.setTargetLanguage(targetLanguage)
        }
        contentView.startLoadingAnimation(baseText: loadingPlaceholder)
        resizeToFitContent(animated: false)
        panel.orderFrontRegardless()
        installOutsideClickMonitors()
        installCommandCopyInterceptor()
        installReturnKeyInterceptor()
        return activeRequestID
    }

    func showTranslation(_ text: String, requestID: UUID? = nil) {
        guard requestIsCurrent(requestID) else {
            return
        }

        contentView.setResult(text)
        resizeToFitContent(animated: false)
    }

    func showError(_ message: String, requestID: UUID? = nil) {
        guard requestIsCurrent(requestID) else {
            return
        }

        contentView.setError(message)
        resizeToFitContent(animated: true)
    }

    func close() {
        guard !didClose else {
            return
        }

        didClose = true
        contentView.stopLoadingAnimation()
        removeOutsideClickMonitors()
        removeCommandCopyInterceptor()
        removeReturnKeyInterceptor()
        panel.close()
        onClose?()
    }

    private func installOutsideClickMonitors() {
        guard globalOutsideClickMonitor == nil, localOutsideClickMonitor == nil else {
            return
        }

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.closeIfClickIsOutside(event)
        }

        localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.closeIfClickIsOutside(event)
            return event
        }
    }

    private func removeOutsideClickMonitors() {
        if let globalOutsideClickMonitor {
            NSEvent.removeMonitor(globalOutsideClickMonitor)
            self.globalOutsideClickMonitor = nil
        }

        if let localOutsideClickMonitor {
            NSEvent.removeMonitor(localOutsideClickMonitor)
            self.localOutsideClickMonitor = nil
        }
    }

    private func installCommandCopyInterceptor() {
        guard commandCopyInterceptor == nil else {
            return
        }

        let interceptor = CommandCopyInterceptor { [weak self] in
            self?.copyResultAndClose()
        }
        commandCopyInterceptor = interceptor
        interceptor.enable()
    }

    private func removeCommandCopyInterceptor() {
        commandCopyInterceptor?.disable()
        commandCopyInterceptor = nil
    }

    private func installReturnKeyInterceptor() {
        guard returnKeyInterceptor == nil, let pid = replaceShortcutSourcePID else {
            return
        }

        let interceptor = ReturnKeyInterceptor(sourcePID: pid) { [weak self] in
            self?.triggerReplaceFromShortcut()
        }
        returnKeyInterceptor = interceptor
        interceptor.enable()
    }

    private func removeReturnKeyInterceptor() {
        returnKeyInterceptor?.disable()
        returnKeyInterceptor = nil
    }

    private func triggerReplaceFromShortcut() {
        guard panel.isVisible else { return }
        contentView.triggerReplaceProgrammatically()
    }

    private func copyResultAndClose() {
        guard panel.isVisible else {
            return
        }

        contentView.copyResultToPasteboard()
        close()
    }

    private func closeIfClickIsOutside(_ event: NSEvent) {
        guard panel.isVisible else {
            return
        }

        guard !contentView.isTargetLanguageMenuOpen else {
            return
        }

        let screenPoint = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        guard !panel.frame.insetBy(dx: -4, dy: -4).contains(screenPoint) else {
            return
        }

        close()
    }

    private func requestIsCurrent(_ requestID: UUID?) -> Bool {
        guard let requestID else {
            return true
        }

        return requestID == activeRequestID
    }

    private func resizeToFitContent(animated: Bool) {
        let currentFrame = panel.frame
        let visibleFrame = NSScreen.visibleFrame(containing: NSPoint(x: currentFrame.midX, y: currentFrame.midY))
        let targetHeight = min(contentView.preferredHeightForCurrentContent(), visibleFrame.height - 32)
        let targetWidth = TranslationContentView.preferredWidth
        let preserveCurrentPosition = panel.isVisible
        let targetSize = NSSize(width: targetWidth, height: targetHeight)

        let targetOrigin: NSPoint
        if preserveCurrentPosition {
            // Resize-in-place: preserve top edge (panel.maxY) and X. Works
            // identically for both .point and .selection anchors.
            let preservedY = min(
                max(currentFrame.maxY - targetHeight, visibleFrame.minY + Self.edgeMargin),
                visibleFrame.maxY - targetHeight - Self.edgeMargin
            )
            let preservedX = min(
                max(currentFrame.minX, visibleFrame.minX + Self.edgeMargin),
                visibleFrame.maxX - targetWidth - Self.edgeMargin
            )
            targetOrigin = NSPoint(x: preservedX, y: preservedY)
        } else {
            targetOrigin = Self.panelOrigin(
                anchor: anchor,
                panelSize: targetSize,
                visibleFrame: visibleFrame
            )
        }

        let targetAnchorY = TranslationContentView.anchorY(
            for: Self.anchorY(for: anchor),
            panelOriginY: targetOrigin.y,
            panelHeight: targetHeight
        )
        contentView.setAnchorY(targetAnchorY)

        let targetFrame = NSRect(
            x: targetOrigin.x,
            y: targetOrigin.y,
            width: targetWidth,
            height: targetHeight
        )

        let frameUnchanged = abs(targetFrame.minX - currentFrame.minX) < 0.5
            && abs(targetFrame.minY - currentFrame.minY) < 0.5
            && abs(targetFrame.width - currentFrame.width) < 0.5
            && abs(targetFrame.height - currentFrame.height) < 0.5
        if frameUnchanged {
            contentView.layoutForCurrentSize()
            return
        }

        let heightDelta = abs(targetFrame.height - currentFrame.height)
        if !animated || heightDelta < 1.5 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.setFrame(targetFrame, display: true)
            CATransaction.commit()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    private static func anchorReferencePoint(for anchor: Anchor) -> NSPoint {
        switch anchor {
        case .point(let p, _):    return p
        case .selection(let r):   return NSPoint(x: r.midX, y: r.midY)
        }
    }

    private static func anchorY(for anchor: Anchor) -> CGFloat {
        switch anchor {
        case .point(let p, _):    return p.y
        case .selection(let r):   return r.midY
        }
    }

    private static func panelOrigin(
        anchor: Anchor,
        panelSize: NSSize,
        visibleFrame: NSRect
    ) -> NSPoint {
        switch anchor {
        case .point(let p, let panelSide):
            // X depends on which side we want the panel relative to the point.
            // .right is the historical default (panel goes right of click point);
            // .left is used when the user dragged RTL so the panel flips to the
            // left to avoid overlapping the selection in non-AX apps.
            let desiredX: CGFloat
            switch panelSide {
            case .right: desiredX = p.x + sideGap
            case .left:  desiredX = p.x - sideGap - panelSize.width
            }
            let desiredY = p.y - panelSize.height * 0.52
            let clampedX = min(max(desiredX, visibleFrame.minX + edgeMargin),
                               visibleFrame.maxX - panelSize.width - edgeMargin)
            let clampedY = min(max(desiredY, visibleFrame.minY + edgeMargin),
                               visibleFrame.maxY - panelSize.height - edgeMargin)
            return NSPoint(x: clampedX, y: clampedY)

        case .selection(let sel):
            // Prefer right of the selection; fall back to left; if neither side
            // fits, gracefully degrade to .point at the selection center.
            let rightX = sel.maxX + sideGap
            let leftX  = sel.minX - sideGap - panelSize.width
            let rightFits = rightX + panelSize.width <= visibleFrame.maxX - edgeMargin
            let leftFits  = leftX >= visibleFrame.minX + edgeMargin

            let chosenX: CGFloat
            if rightFits {
                chosenX = rightX
            } else if leftFits {
                chosenX = leftX
            } else {
                return panelOrigin(
                    anchor: .point(NSPoint(x: sel.midX, y: sel.midY), panelSide: .right),
                    panelSize: panelSize,
                    visibleFrame: visibleFrame
                )
            }

            // Center-align: panel.midY lines up with sel.midY (vertical center of
            // the selection). Clamp inside the visible frame so a tall panel beside
            // a short selection doesn't escape the screen.
            let desiredY = sel.midY - panelSize.height / 2
            let clampedY = min(max(desiredY, visibleFrame.minY + edgeMargin),
                               visibleFrame.maxY - panelSize.height - edgeMargin)
            let clampedX = min(max(chosenX, visibleFrame.minX + edgeMargin),
                               visibleFrame.maxX - panelSize.width - edgeMargin)
            return NSPoint(x: clampedX, y: clampedY)
        }
    }
}

private extension NSScreen {
    static func visibleFrame(containing point: NSPoint) -> NSRect {
        NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
    }
}

enum GlassHostStyle {
    case regular
    case clear
}

final class GlassHostView: NSView {
    let contentView = NSView()

    init(frame: NSRect, cornerRadius: CGFloat, tintColor: NSColor?, style: GlassHostStyle) {
        super.init(frame: frame)
        wantsLayer = true
        contentView.frame = bounds
        contentView.autoresizingMask = [.width, .height]

        // Keep this compatible with the current public macOS SDK used by CI/release builds.
        // Referencing NSGlassEffectView directly breaks compilation on Xcode versions whose
        // SDK does not yet define that symbol, even inside an #available(macOS 26.0, *) block.
        let material = NSVisualEffectView(frame: bounds)
        material.autoresizingMask = [.width, .height]
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = cornerRadius
        material.layer?.masksToBounds = true
        addSubview(material)
        material.addSubview(contentView)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

final class GlassChromeOverlayView: NSView {
    var cornerRadius: CGFloat = 22

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor(calibratedWhite: 1.0, alpha: 0.16).setStroke()
        path.lineWidth = 1
        path.stroke()

        let innerRect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let innerPath = NSBezierPath(roundedRect: innerRect, xRadius: max(0, cornerRadius - 1), yRadius: max(0, cornerRadius - 1))
        NSColor(calibratedWhite: 1.0, alpha: 0.06).setStroke()
        innerPath.lineWidth = 1
        innerPath.stroke()
    }
}

final class HairlineSeparatorView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 1.0, alpha: 0.14).setFill()
        bounds.fill()
    }
}

private enum TranslationPanelPalette {
    static let targetTitle = NSColor(calibratedWhite: 1.0, alpha: 0.84)
    static let resultText = NSColor(calibratedWhite: 0.94, alpha: 0.96)
    static let resultLink = NSColor(calibratedWhite: 1.0, alpha: 0.82)
    static let actionIconEnabled = NSColor(calibratedWhite: 1.0, alpha: 0.68)
    static let actionIconDisabled = NSColor(calibratedWhite: 1.0, alpha: 0.30)
    static let sourceAction = NSColor(calibratedWhite: 1.0, alpha: 0.70)
}

final class LanguagePickerButton: NSButton {
    static let titleLeadingInset: CGFloat = 8

    private static let horizontalPadding: CGFloat = 8
    private static let chevronGap: CGFloat = 8
    private static let chevronWidth: CGFloat = 10
    private static let chevronHeight: CGFloat = 16
    private static let chevronBackgroundSize: CGFloat = 18

    private let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private let titleColor = TranslationPanelPalette.targetTitle

    private var hoverTrackingArea: NSTrackingArea?
    private var displayTitle = ""
    private var isHovered = false
    private var isMenuOpen = false
    private var pickerEnabled = true

    var preferredWidth: CGFloat {
        let titleWidth = ceil((displayTitle as NSString).size(withAttributes: [.font: titleFont]).width)
        let affordanceWidth = pickerEnabled ? Self.chevronGap + Self.chevronBackgroundSize : 0
        let paddedWidth = titleWidth + Self.horizontalPadding * 2 + affordanceWidth
        return min(max(paddedWidth, 64), 220)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isBordered = false
        alignment = .left
        focusRingType = .none
        title = ""
        setButtonType(.momentaryChange)
        applyStyle()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        guard pickerEnabled else {
            return
        }

        isHovered = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyStyle()
    }

    override func draw(_ dirtyRect: NSRect) {
        let title = NSAttributedString(string: displayTitle, attributes: [
            .font: titleFont,
            .foregroundColor: titleColor,
            .kern: 0
        ])
        let titleSize = title.size()
        let titleOrigin = NSPoint(
            x: Self.horizontalPadding,
            y: floor((bounds.height - titleSize.height) / 2) - 1
        )
        title.draw(at: titleOrigin)

        guard pickerEnabled && (isHovered || isMenuOpen || isHighlighted),
              bounds.width > Self.horizontalPadding * 2 + Self.chevronBackgroundSize
        else {
            return
        }

        drawChevronPair()
    }

    private func drawChevronPair() {
        let backgroundRect = NSRect(
            x: bounds.maxX - Self.horizontalPadding - Self.chevronBackgroundSize,
            y: floor((bounds.height - Self.chevronBackgroundSize) / 2),
            width: Self.chevronBackgroundSize,
            height: Self.chevronBackgroundSize
        )
        NSColor(calibratedWhite: 1.0, alpha: 0.11).setFill()
        NSBezierPath(ovalIn: backgroundRect).fill()

        let origin = NSPoint(
            x: backgroundRect.midX - Self.chevronWidth / 2,
            y: floor((bounds.height - Self.chevronHeight) / 2)
        )
        let midX = origin.x + Self.chevronWidth / 2
        let rightX = origin.x + Self.chevronWidth

        NSColor(calibratedWhite: 1.0, alpha: 0.88).setStroke()

        let up = NSBezierPath()
        up.lineWidth = 2.0
        up.lineCapStyle = .round
        up.lineJoinStyle = .round
        up.move(to: NSPoint(x: origin.x + 1, y: origin.y + 10))
        up.line(to: NSPoint(x: midX, y: origin.y + 14))
        up.line(to: NSPoint(x: rightX - 1, y: origin.y + 10))
        up.stroke()

        let down = NSBezierPath()
        down.lineWidth = 2.0
        down.lineCapStyle = .round
        down.lineJoinStyle = .round
        down.move(to: NSPoint(x: origin.x + 1, y: origin.y + 6))
        down.line(to: NSPoint(x: midX, y: origin.y + 2))
        down.line(to: NSPoint(x: rightX - 1, y: origin.y + 6))
        down.stroke()
    }

    func setTitle(_ title: String, pickerEnabled: Bool) {
        displayTitle = title
        self.pickerEnabled = pickerEnabled
        toolTip = pickerEnabled ? "Choose translation language" : nil
        isEnabled = true
        applyStyle()
        needsLayout = true
    }

    func setMenuOpen(_ isMenuOpen: Bool) {
        self.isMenuOpen = isMenuOpen
        applyStyle()
    }

    private func applyStyle() {
        layer?.cornerRadius = 0
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        layer?.borderColor = NSColor.clear.cgColor
        needsDisplay = true
    }
}

final class SourcePreviewView: NSView {
    private static let moreButtonWidth: CGFloat = 50
    private static let moreGap: CGFloat = 8
    private static let sourceTextYOffset: CGFloat = 2
    private static let moreButtonYOffset: CGFloat = 1

    private let textLabel = NSTextField(labelWithString: "")
    private let moreButton = NSButton(title: "more", target: nil, action: nil)
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false
    private var canExpand = false

    var onMore: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        textLabel.font = NSFont.systemFont(ofSize: TranslationContentView.sourceFontSize, weight: .semibold)
        textLabel.textColor = NSColor(calibratedWhite: 1.0, alpha: 0.90)
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 1
        textLabel.usesSingleLineMode = true
        addSubview(textLabel)

        moreButton.target = self
        moreButton.action = #selector(moreTapped)
        moreButton.isBordered = false
        moreButton.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        moreButton.contentTintColor = TranslationPanelPalette.sourceAction
        moreButton.isHidden = true
        moreButton.toolTip = "Show full source"
        addSubview(moreButton)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateMoreVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateMoreVisibility()
    }

    override func layout() {
        super.layout()
        let buttonVisible = !moreButton.isHidden
        let labelWidth = buttonVisible
            ? max(0, bounds.width - Self.moreButtonWidth - Self.moreGap)
            : bounds.width
        let sourceTextHeight = ceil(textLabel.intrinsicContentSize.height)
        let moreButtonHeight = ceil(moreButton.intrinsicContentSize.height)
        let rowHeight = max(sourceTextHeight, moreButtonHeight)
        let rowY = floor((bounds.height - rowHeight) / 2)
        textLabel.frame = NSRect(
            x: 0,
            y: rowY + Self.sourceTextYOffset,
            width: labelWidth,
            height: rowHeight
        )
        moreButton.frame = NSRect(
            x: bounds.maxX - Self.moreButtonWidth,
            y: rowY + Self.moreButtonYOffset,
            width: Self.moreButtonWidth,
            height: rowHeight
        )
    }

    func configure(text: String, canExpand: Bool) {
        textLabel.stringValue = text
        self.canExpand = canExpand
        updateMoreVisibility()
    }

    private func updateMoreVisibility() {
        moreButton.isHidden = !(canExpand && isHovered)
        needsLayout = true
    }

    @objc private func moreTapped() {
        onMore?()
    }
}

final class TranslationContentView: NSView {
    private enum ResultTone {
        case normal
        case error

        var color: NSColor {
            switch self {
            case .normal:
                return TranslationPanelPalette.resultText
            case .error:
                return NSColor(calibratedRed: 1.0, green: 0.48, blue: 0.30, alpha: 0.96)
            }
        }
    }

    static let bodyWidth: CGFloat = 400
    static let preferredWidth: CGFloat = bodyWidth
    private static let minHeight: CGFloat = 168
    private static let maxHeight: CGFloat = 540
    private static let contentWidth: CGFloat = 364
    static let sourceFontSize: CGFloat = 16
    private static let collapsedSourceBoxHeight: CGFloat = 34
    private static let minimumExpandedSourceBoxHeight: CGFloat = 48
    private static let minimumResultBoxHeight: CGFloat = 58
    private static let maximumSourceBoxHeight: CGFloat = 140
    private static let maximumResultBoxHeight: CGFloat = 340

    private static let panelPaddingX: CGFloat = 18
    private static let panelPaddingTop: CGFloat = 20
    private static let panelPaddingBottom: CGFloat = 18
    private static let labelHeight: CGFloat = 18
    private static let labelToBoxGap: CGFloat = 8
    private static let sourceToDividerGap: CGFloat = 13
    private static let dividerToTargetGap: CGFloat = 16
    private static let dividerHeight: CGFloat = 1
    private static let buttonSize: CGFloat = 18
    private static let resultFontSize: CGFloat = 18
    private static let resultParagraphSpacingFactor: CGFloat = 0.35
    private static let textInsetY: CGFloat = 3
    private static let scrollableTextBottomPadding: CGFloat = 18

    var onClose: (() -> Void)?
    var onNeedsResize: (() -> Void)?

    private let sourceText: String
    private var targetLanguage: TranslationLanguage
    private let resultLabel: String?
    private var resultText = "Translating..."
    private var resultDisplayText = "Translating..."
    private var resultTone: ResultTone = .normal
    private let resultTextView = NSTextView()
    private let sourceTitleLabel = NSTextField(labelWithString: "")
    private let sourcePreviewView = SourcePreviewView(frame: .zero)
    private let targetTitleButton = LanguagePickerButton(frame: .zero)
    private let sourceTextView = NSTextView()
    private let sourceScrollView = NSScrollView()
    private let resultScrollView = NSScrollView()
    private let sourceDivider = HairlineSeparatorView()
    private var panelGlass: GlassHostView?
    private var chromeOverlay: GlassChromeOverlayView?
    private var closeButton: NSButton?
    private var copyButton: NSButton?
    private var replaceButton: NSButton?
    private var sourceExpanded = false
    private var shouldScrollSourceToTop = true
    private var shouldScrollResultToTop = true
    private var anchorYValue: CGFloat
    private let onTargetLanguageSelected: ((TranslationLanguage) -> Void)?
    private let onReplace: ((String) -> Void)?
    private var loadingBaseText: String?
    private var loadingTimer: Timer?
    private var loadingDotCount = 0
    private var isInternalLoadingUpdate = false

    var isTargetLanguageMenuOpen = false

    init(
        sourceText: String,
        targetLanguage: TranslationLanguage,
        resultLabel: String? = nil,
        anchorY: CGFloat,
        onTargetLanguageSelected: ((TranslationLanguage) -> Void)? = nil,
        onReplace: ((String) -> Void)? = nil
    ) {
        self.sourceText = sourceText
        self.targetLanguage = targetLanguage
        self.resultLabel = resultLabel
        self.anchorYValue = anchorY
        self.onTargetLanguageSelected = onTargetLanguageSelected
        self.onReplace = onReplace
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: Self.preferredWidth,
            height: Self.preferredHeight(sourceText: sourceText, resultText: "Translating...")
        ))
        wantsLayer = true
        buildUI()
    }

    required init?(coder: NSCoder) {
        nil
    }

    static func preferredHeight(sourceText: String, resultText: String, sourceExpanded: Bool = false) -> CGFloat {
        let sourceBoxHeight = sourceHeight(for: sourceText, expanded: sourceExpanded)
        let resultBoxHeight = boxHeight(
            for: resultText,
            font: NSFont.systemFont(ofSize: resultFontSize, weight: .semibold),
            width: contentWidth,
            minimum: minimumResultBoxHeight,
            maximum: maximumResultBoxHeight,
            paragraphSpacing: resultFontSize * resultParagraphSpacingFactor
        )

        let fixedHeight = panelPaddingTop
            + labelHeight + labelToBoxGap
            + sourceToDividerGap + dividerHeight + dividerToTargetGap
            + labelHeight + labelToBoxGap
            + panelPaddingBottom
        return min(max(fixedHeight + sourceBoxHeight + resultBoxHeight, minHeight), maxHeight)
    }

    func preferredHeightForCurrentContent() -> CGFloat {
        Self.preferredHeight(sourceText: sourceText, resultText: resultDisplayText, sourceExpanded: sourceExpanded)
    }

    static func anchorY(for screenY: CGFloat, panelOriginY: CGFloat, panelHeight: CGFloat) -> CGFloat {
        min(max(screenY - panelOriginY, 0), panelHeight)
    }

    func setAnchorY(_ anchorY: CGFloat) {
        guard abs(anchorYValue - anchorY) >= 0.5 else {
            return
        }
        anchorYValue = anchorY
        layoutForCurrentSize()
    }

    func setTargetLanguage(_ language: TranslationLanguage) {
        guard resultLabel == nil else {
            return
        }

        targetLanguage = language
        targetTitleButton.setTitle(language.displayName, pickerEnabled: true)
        layoutForCurrentSize()
    }

    private func expandSource() {
        guard !sourceExpanded else {
            return
        }

        sourceExpanded = true
        shouldScrollSourceToTop = true
        onNeedsResize?()
        layoutForCurrentSize()
    }

    private static func boxHeight(
        for text: String,
        font: NSFont,
        width: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat,
        paragraphSpacing: CGFloat = 0
    ) -> CGFloat {
        let height = textHeight(for: text, font: font, width: width, paragraphSpacing: paragraphSpacing) + textInsetY * 2 + 4
        return min(max(height, minimum), maximum)
    }

    private static func sourceHeight(for text: String, expanded: Bool) -> CGFloat {
        guard expanded else {
            return collapsedSourceBoxHeight
        }

        return boxHeight(
            for: text,
            font: NSFont.systemFont(ofSize: sourceFontSize, weight: .semibold),
            width: contentWidth,
            minimum: minimumExpandedSourceBoxHeight,
            maximum: maximumSourceBoxHeight
        )
    }

    private static func singleLineWidth(for text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func collapsedSourceText(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func layoutScrollableTextView(
        _ textView: NSTextView,
        inside scrollView: NSScrollView,
        scrollFrame: NSRect,
        rawTextHeight: CGFloat,
        showsOverflowScroller: Bool = true
    ) {
        scrollView.frame = scrollFrame

        let minimumVerticalTextPadding: CGFloat = 4
        let fitsInScrollFrame = rawTextHeight + minimumVerticalTextPadding * 2 <= scrollFrame.height
        let verticalInset: CGFloat
        let textViewHeight: CGFloat
        if fitsInScrollFrame {
            verticalInset = floor(max(2, (scrollFrame.height - rawTextHeight) / 2))
            textViewHeight = scrollFrame.height
        } else {
            verticalInset = minimumVerticalTextPadding
            textViewHeight = max(
                scrollFrame.height + 1,
                rawTextHeight + verticalInset * 2 + scrollableTextBottomPadding
            )
        }

        let scrollerInset: CGFloat = 8
        textView.textContainerInset = NSSize(width: 0, height: verticalInset)
        textView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: scrollFrame.width, height: textViewHeight)
        )
        textView.minSize = NSSize(width: 0, height: scrollFrame.height)
        textView.textContainer?.containerSize = NSSize(
            width: max(0, scrollFrame.width - scrollerInset),
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.hasVerticalScroller = showsOverflowScroller && !fitsInScrollFrame
    }

    private static func textHeight(
        for text: String,
        font: NSFont,
        width: CGFloat,
        paragraphSpacing: CGFloat = 0
    ) -> CGFloat {
        let cleanText = text.isEmpty ? " " : text
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacing = paragraphSpacing
        let storage = NSTextStorage(string: cleanText, attributes: [
            .font: font,
            .paragraphStyle: paragraph
        ])
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height)
    }

    private static func renderedMarkdownText(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let rendered = (try? AttributedString(markdown: text, options: options))
            .map { NSMutableAttributedString($0) }
            ?? NSMutableAttributedString(string: text)

        guard rendered.length > 0 else {
            return rendered
        }

        let fullRange = NSRange(location: 0, length: rendered.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacing = font.pointSize * resultParagraphSpacingFactor
        rendered.addAttributes([
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ], range: fullRange)

        var fontRuns: [(NSRange, NSFont)] = []
        rendered.enumerateAttribute(.inlinePresentationIntent, in: fullRange) { value, range, _ in
            guard let intent = (value as? NSNumber)?.intValue else {
                return
            }

            if let styledFont = markdownFont(for: intent, baseFont: font) {
                fontRuns.append((range, styledFont))
            }
        }
        for (range, styledFont) in fontRuns {
            rendered.addAttribute(.font, value: styledFont, range: range)
        }

        var linkRuns: [NSRange] = []
        rendered.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            if value != nil {
                linkRuns.append(range)
            }
        }
        for range in linkRuns {
            rendered.addAttributes([
                .foregroundColor: TranslationPanelPalette.resultLink,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: range)
        }

        return rendered
    }

    private static func markdownFont(for intent: Int, baseFont: NSFont) -> NSFont? {
        let emphasized = 1
        let stronglyEmphasized = 2
        let code = 4

        if intent & code != 0 {
            return NSFont.monospacedSystemFont(ofSize: baseFont.pointSize * 0.94, weight: .regular)
        }

        var font = baseFont
        var changed = false
        if intent & stronglyEmphasized != 0 {
            font = NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)
            changed = true
        }
        if intent & emphasized != 0 {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            changed = true
        }
        return changed ? font : nil
    }

    private func buildUI() {
        let panelGlass = GlassHostView(
            frame: NSRect(x: 0, y: 0, width: Self.bodyWidth, height: bounds.height),
            cornerRadius: 22,
            tintColor: NSColor(calibratedRed: 0.10, green: 0.095, blue: 0.045, alpha: 0.72),
            style: .regular
        )
        panelGlass.autoresizingMask = [.height]
        addSubview(panelGlass)
        let content = panelGlass.contentView
        self.panelGlass = panelGlass

        configureSectionLabel(
            sourceTitleLabel,
            text: "Source",
            color: NSColor(calibratedWhite: 1.0, alpha: 0.74)
        )
        content.addSubview(sourceTitleLabel)

        closeButton = makeIconButton(
            symbolName: "xmark",
            accessibilityDescription: "Close",
            pointSize: 10,
            target: self,
            action: #selector(closeTapped),
            to: content
        )

        configureScrollView(sourceScrollView)
        configureTextView(
            sourceTextView,
            text: sourceText,
            font: NSFont.systemFont(ofSize: Self.sourceFontSize, weight: .semibold),
            color: NSColor(calibratedWhite: 1.0, alpha: 0.90)
        )
        sourceScrollView.documentView = sourceTextView
        sourceScrollView.isHidden = true
        sourcePreviewView.onMore = { [weak self] in
            self?.expandSource()
        }
        content.addSubview(sourcePreviewView)
        content.addSubview(sourceScrollView)
        content.addSubview(sourceDivider)

        targetTitleButton.target = self
        targetTitleButton.action = #selector(showTargetLanguageMenu)
        targetTitleButton.setTitle(resultLabel ?? targetLanguage.displayName, pickerEnabled: resultLabel == nil)
        content.addSubview(targetTitleButton)

        copyButton = makeIconButton(
            symbolName: "doc.on.doc",
            accessibilityDescription: "Copy translation",
            pointSize: 11,
            target: self,
            action: #selector(copyResult),
            to: content
        )
        copyButton?.contentTintColor = TranslationPanelPalette.actionIconEnabled

        if onReplace != nil {
            let replaceButton = makeIconButton(
                symbolName: "text.insert",
                accessibilityDescription: "Replace selected text",
                pointSize: 12,
                target: self,
                action: #selector(replaceSelectedText),
                to: content
            )
            replaceButton.isEnabled = false
            replaceButton.contentTintColor = TranslationPanelPalette.actionIconDisabled
            self.replaceButton = replaceButton
        }

        configureScrollView(resultScrollView)
        configureTextView(
            resultTextView,
            text: resultText,
            font: NSFont.systemFont(ofSize: Self.resultFontSize, weight: .semibold),
            color: ResultTone.normal.color
        )
        resultScrollView.documentView = resultTextView
        content.addSubview(resultScrollView)

        let chromeOverlay = GlassChromeOverlayView(frame: content.bounds)
        chromeOverlay.autoresizingMask = [.width, .height]
        content.addSubview(chromeOverlay)
        self.chromeOverlay = chromeOverlay

        setResult(resultText)
    }

    private func configureScrollView(_ scrollView: NSScrollView) {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller?.knobStyle = .light
        scrollView.borderType = .noBorder
    }

    private func configureTextView(_ textView: NSTextView, text: String, font: NSFont, color: NSColor) {
        textView.string = text
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.textColor = color
        textView.font = font
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 0, height: 2)
    }

    @discardableResult
    private func makeIconButton(
        symbolName: String,
        accessibilityDescription: String,
        pointSize: CGFloat,
        target: AnyObject,
        action: Selector,
        to parent: NSView
    ) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription) ?? NSImage()
        let image = baseImage.withSymbolConfiguration(config) ?? baseImage
        let button = FirstMouseButton(image: image, target: target, action: action)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = NSColor(calibratedWhite: 1.0, alpha: 0.55)
        button.toolTip = accessibilityDescription
        parent.addSubview(button)
        return button
    }

    private func configureSectionLabel(_ label: NSTextField, text: String, color: NSColor) {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: color,
            .kern: 0
        ])
        label.attributedStringValue = attributed
    }

    func layoutForCurrentSize() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let bodyHeight = bounds.height
        panelGlass?.frame = NSRect(
            x: 0,
            y: 0,
            width: Self.bodyWidth,
            height: bodyHeight
        )
        chromeOverlay?.frame = NSRect(x: 0, y: 0, width: Self.bodyWidth, height: bodyHeight)

        let sourceBoxHeight = Self.sourceHeight(for: sourceText, expanded: sourceExpanded)
        let fixedHeight = Self.panelPaddingTop
            + Self.labelHeight + Self.labelToBoxGap
            + Self.sourceToDividerGap + Self.dividerHeight + Self.dividerToTargetGap
            + Self.labelHeight + Self.labelToBoxGap
            + Self.panelPaddingBottom
        let availableBoxHeight = max(
            Self.collapsedSourceBoxHeight + Self.minimumResultBoxHeight,
            bounds.height - fixedHeight
        )
        let resolvedSourceBoxHeight = min(
            sourceBoxHeight,
            max(Self.collapsedSourceBoxHeight, availableBoxHeight - Self.minimumResultBoxHeight)
        )
        let resolvedResultBoxHeight = max(Self.minimumResultBoxHeight, availableBoxHeight - resolvedSourceBoxHeight)

        var y = bodyHeight - Self.panelPaddingTop - Self.labelHeight
        sourceTitleLabel.frame = NSRect(
            x: Self.panelPaddingX,
            y: y,
            width: Self.contentWidth - Self.buttonSize - 8,
            height: Self.labelHeight
        )
        closeButton?.frame = NSRect(
            x: Self.bodyWidth - Self.panelPaddingX - Self.buttonSize,
            y: y + (Self.labelHeight - Self.buttonSize) / 2,
            width: Self.buttonSize,
            height: Self.buttonSize
        )

        y -= Self.labelToBoxGap + resolvedSourceBoxHeight
        let sourceScrollFrame = NSRect(
            x: Self.panelPaddingX,
            y: y,
            width: Self.contentWidth,
            height: resolvedSourceBoxHeight
        )
        let collapsedSourceText = Self.collapsedSourceText(sourceText)
        let sourceCanExpand = Self.singleLineWidth(
            for: collapsedSourceText,
            font: NSFont.systemFont(ofSize: Self.sourceFontSize, weight: .semibold)
        ) > Self.contentWidth
            || collapsedSourceText != sourceText.trimmingCharacters(in: .whitespacesAndNewlines)

        sourcePreviewView.frame = sourceScrollFrame
        sourcePreviewView.configure(text: collapsedSourceText, canExpand: sourceCanExpand)
        sourcePreviewView.isHidden = sourceExpanded
        sourceScrollView.isHidden = !sourceExpanded

        if sourceExpanded {
            let sourceRawTextHeight = Self.textHeight(
                for: sourceText,
                font: NSFont.systemFont(ofSize: Self.sourceFontSize, weight: .semibold),
                width: sourceScrollFrame.width
            )
            Self.layoutScrollableTextView(
                sourceTextView,
                inside: sourceScrollView,
                scrollFrame: sourceScrollFrame,
                rawTextHeight: sourceRawTextHeight,
                showsOverflowScroller: true
            )
            if shouldScrollSourceToTop {
                scrollToTop(sourceScrollView)
                shouldScrollSourceToTop = false
            }
        }

        y -= Self.sourceToDividerGap + Self.dividerHeight
        sourceDivider.frame = NSRect(
            x: Self.panelPaddingX,
            y: y,
            width: Self.contentWidth,
            height: Self.dividerHeight
        )

        y -= Self.dividerToTargetGap + Self.labelHeight
        let targetActionButtonCount = replaceButton == nil ? 1 : 2
        let targetActionWidth = CGFloat(targetActionButtonCount) * Self.buttonSize
            + CGFloat(max(0, targetActionButtonCount - 1)) * 8
        let targetTitleLeadingInset = LanguagePickerButton.titleLeadingInset
        targetTitleButton.frame = NSRect(
            x: Self.panelPaddingX - targetTitleLeadingInset,
            y: y + (Self.labelHeight - Self.buttonSize) / 2,
            width: min(
                targetTitleButton.preferredWidth,
                Self.contentWidth - targetActionWidth - 8 + targetTitleLeadingInset
            ),
            height: Self.buttonSize
        )
        copyButton?.frame = NSRect(
            x: Self.bodyWidth - Self.panelPaddingX - Self.buttonSize,
            y: y + (Self.labelHeight - Self.buttonSize) / 2,
            width: Self.buttonSize,
            height: Self.buttonSize
        )
        replaceButton?.frame = NSRect(
            x: Self.bodyWidth - Self.panelPaddingX - Self.buttonSize * 2 - 8,
            y: y + (Self.labelHeight - Self.buttonSize) / 2,
            width: Self.buttonSize,
            height: Self.buttonSize
        )

        y -= Self.labelToBoxGap + resolvedResultBoxHeight
        let resultScrollFrame = NSRect(
            x: Self.panelPaddingX,
            y: y,
            width: Self.contentWidth,
            height: resolvedResultBoxHeight
        )
        let resultRawTextHeight = Self.textHeight(
            for: resultDisplayText,
            font: NSFont.systemFont(ofSize: Self.resultFontSize, weight: .semibold),
            width: resultScrollFrame.width,
            paragraphSpacing: Self.resultFontSize * Self.resultParagraphSpacingFactor
        )
        Self.layoutScrollableTextView(
            resultTextView,
            inside: resultScrollView,
            scrollFrame: resultScrollFrame,
            rawTextHeight: resultRawTextHeight
        )
        if shouldScrollResultToTop {
            scrollToTop(resultScrollView)
            shouldScrollResultToTop = false
        }
    }

    func setResult(_ text: String) {
        setResult(text, tone: .normal)
    }

    func setError(_ text: String) {
        setResult(text, tone: .error)
    }

    private func setResult(_ text: String, tone: ResultTone) {
        if !isInternalLoadingUpdate {
            stopLoadingAnimation()
        }
        let cleanedText = TextNormalizer.cleanedTranslation(text)

        if cleanedText == resultText, tone == resultTone {
            return
        }

        if !cleanedText.hasPrefix(resultText) || tone != resultTone {
            shouldScrollResultToTop = true
        }

        resultTone = tone
        resultTextView.textColor = tone.color
        let renderedText = Self.renderedMarkdownText(
            cleanedText,
            font: resultTextView.font ?? NSFont.systemFont(ofSize: Self.resultFontSize, weight: .regular),
            color: tone.color
        )
        if let textStorage = resultTextView.textStorage {
            textStorage.setAttributedString(renderedText)
        } else {
            resultTextView.string = renderedText.string
        }

        resultText = cleanedText
        resultDisplayText = resultTextView.string
        updateActionButtonStates()
        layoutForCurrentSize()
    }

    func startLoadingAnimation(baseText: String) {
        stopLoadingAnimation()
        loadingBaseText = baseText
        loadingDotCount = 0
        renderLoadingFrame()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickLoadingAnimation() }
        }
        loadingTimer = timer
    }

    func stopLoadingAnimation() {
        loadingTimer?.invalidate()
        loadingTimer = nil
        loadingBaseText = nil
    }

    var isShowingLoadingState: Bool { loadingBaseText != nil }

    private func tickLoadingAnimation() {
        guard loadingBaseText != nil else { return }
        loadingDotCount = (loadingDotCount + 1) % 4
        renderLoadingFrame()
    }

    private func renderLoadingFrame() {
        guard let baseText = loadingBaseText else { return }
        let dots = String(repeating: ".", count: loadingDotCount)
        isInternalLoadingUpdate = true
        setResult("\(baseText)\(dots)")
        isInternalLoadingUpdate = false
    }

    private func scrollToTop(_ scrollView: NSScrollView) {
        guard let documentView = scrollView.documentView else {
            return
        }

        let clipView = scrollView.contentView
        let y = documentView.isFlipped
            ? CGFloat.zero
            : max(0, documentView.bounds.height - clipView.bounds.height)
        clipView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clipView)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutForCurrentSize()
    }

    @objc private func showTargetLanguageMenu() {
        guard resultLabel == nil else {
            return
        }

        let menu = NSMenu()
        for language in TranslationLanguage.all {
            let item = NSMenuItem(
                title: language.displayName,
                action: #selector(selectTemporaryTargetLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language.id
            item.state = language.id == targetLanguage.id ? .on : .off
            menu.addItem(item)
        }

        isTargetLanguageMenuOpen = true
        targetTitleButton.setMenuOpen(true)
        _ = menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: -4),
            in: targetTitleButton
        )
        targetTitleButton.setMenuOpen(false)
        isTargetLanguageMenuOpen = false
    }

    @objc private func selectTemporaryTargetLanguage(_ sender: NSMenuItem) {
        guard let languageID = sender.representedObject as? String else {
            return
        }

        let language = TranslationLanguage.language(id: languageID)
        guard language != targetLanguage else {
            return
        }

        setTargetLanguage(language)
        onTargetLanguageSelected?(language)
    }

    @objc private func copyResult() {
        copyResultToPasteboard()
        onClose?()
    }

    func copyResultToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultTextView.string, forType: .string)
    }

    @objc private func replaceSelectedText() {
        let replacement = TextNormalizer.cleanedTranslation(resultTextView.string)
        guard !replacement.isEmpty,
              !isShowingLoadingState,
              resultTone != .error
        else {
            return
        }

        onReplace?(replacement)
    }

    func triggerReplaceProgrammatically() {
        replaceSelectedText()
    }

    @objc private func closeTapped() {
        onClose?()
    }

    private func updateActionButtonStates() {
        let result = TextNormalizer.cleanedTranslation(resultTextView.string)
        let canUseResult = !result.isEmpty
            && !isShowingLoadingState
            && resultTone != .error

        copyButton?.isEnabled = canUseResult
        copyButton?.contentTintColor = canUseResult
            ? TranslationPanelPalette.actionIconEnabled
            : TranslationPanelPalette.actionIconDisabled

        guard let replaceButton else {
            return
        }
        replaceButton.isEnabled = canUseResult
        replaceButton.contentTintColor = canUseResult
            ? TranslationPanelPalette.actionIconEnabled
            : TranslationPanelPalette.actionIconDisabled
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

enum TranslationMode {
    case selection
    case draftMessage
    case smartReply

    var usesCompositionSettings: Bool {
        switch self {
        case .selection:
            return false
        case .draftMessage, .smartReply:
            return true
        }
    }

    var resultLabel: String? {
        switch self {
        case .selection, .draftMessage:
            return nil
        case .smartReply:
            return "Reply"
        }
    }

    var loadingPlaceholder: String {
        switch self {
        case .smartReply:
            return "Thinking"
        case .draftMessage:
            return "Rewriting"
        case .selection:
            return "Translating"
        }
    }

    func systemPrompt(
        targetLanguage: TranslationLanguage,
        appCategory: AppCategory,
        composition: CompositionSettings?
    ) -> String {
        switch self {
        case .selection:
            """
            Translate the user's text into natural \(targetLanguage.promptName) by preserving the intended meaning, not by translating word-for-word. Treat a single `\\n` as a wrapped line inside one paragraph — join it silently. Treat a blank line (`\\n\\n`) as a deliberate paragraph break that the user wants to keep — render it as a blank line in the output. Clean repeated spaces, OCR artifacts, and hyphenated line wraps. Preserve proper names, dates, numbers, URLs, concrete facts, and paragraph/bullet/list structure. If the source has no paragraph breaks but is long or dense, split the translation into readable paragraphs instead of returning one wall of text.

            Same-language mode — if the entire source text is already in \(targetLanguage.promptName), do not translate and do not echo it back unchanged. Instead, rewrite it for a curious ~12-year-old reader with no background in the field — accessible, but not babyish or condescending. Break long sentences into shorter ones, replace jargon and rare or technical vocabulary with plain everyday words, unwind passive voice and nested clauses, and prefer concrete wording over abstract phrasing. Where a concept stays abstract after a plain-word swap, anchor it inline with a short concrete example or everyday analogy in parentheses or em-dashes — e.g. "a queue (like the line at a coffee shop — first in, first served)". Keep every fact, name, date, number, quotation, URL, and the original paragraph/bullet/list structure exactly. Do not summarize, do not drop content, do not add new claims, opinions, or facts — examples and analogies must only illustrate what is already there, never extend it. If your rewrite differs from the source only by swapping a few synonyms (e.g. "specialized" → "special", "utilize" → "use") or replacing punctuation, you have not simplified — go further: add an illustrative example, restructure the sentence, or name the topic in plainer terms. If only part of the source is in \(targetLanguage.promptName) and the rest is in another language, translate the foreign parts and lightly simplify the rest.

            Context — the source text is from \(appCategory.promptHint)

            Return only the \(targetLanguage.promptName) translation. No preamble, no commentary, no quotes around the output. Never write a wrapper like "Here is the translation:" — output the translated text directly.
            """
        case .draftMessage:
            if composition?.cleanup == CleanupLevel.none {
                """
                Translate the user's drafted outgoing message into \(targetLanguage.promptName). Preserve the user's phrasing, sentence structure, and word choices as faithfully as the target language allows — even if the result reads slightly stiff or non-idiomatic. Do not polish, smooth, naturalize, or rewrite the draft beyond what literal translation strictly requires. If the draft is already entirely in \(targetLanguage.promptName), return it essentially unchanged; correct only outright errors.

                The selected Writing style controls register, honorifics, and formality — apply it for those purposes only, not as a license to rephrase or stylize. Preserve verbatim: emojis, URLs, usernames, product names, numbers, line breaks. If the draft is a fragment, translate the fragment as-is without inventing extra context.

                Context — the user is composing this message in \(appCategory.promptHint)

                Writing style — \(composition?.style.promptDescription ?? "")\(TranslationMode.glossarySection(for: composition?.snippets ?? [], includeSnippets: true))

                Return only the final \(targetLanguage.promptName) message, with no commentary, labels, alternatives, quotes, or explanations.
                """
            } else {
                """
                Translate the user's drafted outgoing message into natural \(targetLanguage.promptName). Infer the user's actual intent, emotion, and social situation, then say it the way a native \(targetLanguage.promptName) speaker would send it in a chat or message. If the draft is already entirely in \(targetLanguage.promptName), do not translate it; lightly rewrite/polish it only when needed so it sounds natural and sendable.

                The selected Writing style is authoritative. The source draft tells you meaning, intent, emotion, and how direct the user wants to be, but it must not override the selected Writing style. When goals conflict, follow this priority: (1) meaning, (2) selected Writing style, (3) intended directness and emotional signal within that style, (4) cultural naturalness — idioms, honorifics, word order, (5) surface details to preserve verbatim — emojis, URLs, usernames, product names, numbers, line breaks, (6) literal wording (always lowest). If the draft is blunt, keep the result concise and direct, but still use the selected Writing style. Do not pad a curt one-liner into a long paragraph unless the meaning requires it. If the draft is awkward or phrased like a direct translation, smooth it while keeping the same intent. If the draft is a fragment, return a natural sendable fragment without inventing extra context.

                Context — the user is composing this message in \(appCategory.promptHint)

                Writing style — \(composition?.style.promptDescription ?? "")

                Cleanup — \(composition?.cleanup.promptDescription ?? "")\(TranslationMode.glossarySection(for: composition?.snippets ?? [], includeSnippets: true))

                Return only the final \(targetLanguage.promptName) message, with no commentary, labels, alternatives, quotes, or explanations.
                """
            }
        case .smartReply:
            """
            The user has selected text in another app. The text is either (a) a message they received — email, chat message, DM, comment, support ticket, or similar; or (b) a question they need to answer — a quiz item, exam question, multiple-choice question, or open question. Decide which it is from the text itself, then respond appropriately. Always respond in the SAME language as the source text. Never translate.

            If it is a received message: write a natural, ready-to-send reply as if the user is sending it now. Match the intent, emotional signal, and approximate length of the original, but use the selected Writing style below for register and formality. Be concise. Don't restate or quote the original. Don't add greetings or sign-offs unless the original suggests them. Don't address the user — produce only the message body they would paste into the reply field.

            If it is a multiple-choice question: identify the correct option and respond with the option letter or number followed by the option text, then a brief one-sentence justification. Example: "B. Mitochondria — they generate most of the cell's ATP."

            If it is an open question: give a clear, direct answer. Keep it short unless the question demands depth.

            Context — the user is replying inside \(appCategory.promptHint)

            Writing style — \(composition?.style.promptDescription ?? "")

            Cleanup — \(composition?.cleanup.promptDescription ?? "")\(TranslationMode.glossarySection(for: composition?.snippets ?? [], includeSnippets: true))

            Return only the reply or answer text. No commentary, no labels, no preface, no explanation of what you're doing, no quotes around the answer.
            """
        }
    }

    private static func glossarySection(for snippets: [Snippet], includeSnippets: Bool) -> String {
        let usable = snippets.filter(\.isUsable)
        guard !usable.isEmpty else { return "" }

        let expansions = includeSnippets ? usable.filter { $0.kind == .snippet } : []
        let dictionaryTerms = usable.filter { $0.kind == .dictionaryTerm }
        guard !expansions.isEmpty || !dictionaryTerms.isEmpty else { return "" }

        var sections: [String] = []
        sections.append(#"Glossary — apply these user-saved rules exactly when relevant."#)

        if !expansions.isEmpty {
            let lines = expansions.map { snippet -> String in
                let trigger = promptLine(snippet.trigger)
                let value = promptLine(snippet.value)
                return "- \"\(trigger)\" → \(value)"
            }
            sections.append("Snippets — expand BEFORE rewriting for tone/style. After expansion, treat the expanded text as canonical and do not paraphrase it:\n" + lines.joined(separator: "\n"))
        }

        if !dictionaryTerms.isEmpty {
            let lines = dictionaryTerms.map { "- \(promptLine($0.trigger))" }
            sections.append("Dictionary — preserve these terms verbatim. Never translate, paraphrase, or alter spelling/capitalization:\n" + lines.joined(separator: "\n"))
        }

        return "\n\n" + sections.joined(separator: "\n\n")
    }

    private static func promptLine(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum AppCategory: String, CaseIterable, Codable {
    case personalMessages
    case workMessages
    case email
    case other

    var displayName: String {
        switch self {
        case .personalMessages: return "Personal messages"
        case .workMessages: return "Work messages"
        case .email: return "Email"
        case .other: return "Other"
        }
    }

    var promptHint: String {
        switch self {
        case .personalMessages:
            return "a personal messaging app — chats with friends, family, partner, or close contacts. Short fragments are common, but the writing style setting decides the register."
        case .workMessages:
            return "a workplace messaging app — Slack, Teams, LinkedIn. Colleagues and clients. Conversational but professional; complete thoughts but not stiff."
        case .email:
            return "an email client. Longer-form medium where greetings, full sentences, and sign-offs are normal."
        case .other:
            return "an unspecified app. No strong medium expectation — defer to the user's chosen style."
        }
    }
}

enum WritingStyle: String, CaseIterable, Codable {
    case formal
    case polite
    case casual

    var displayName: String {
        switch self {
        case .formal: return "Formal"
        case .polite: return "Polite"
        case .casual: return "Casual"
        }
    }

    var promptDescription: String {
        switch self {
        case .formal:
            return "highest formal register — the way you'd write to a senior client, superior, or in a business letter. In English: full sentences, no contractions, deferential tone. In Korean: use 합쇼체 (-습니다 / -십시오), never 해요체 and never 반말. In Japanese: use です/ます with deferential phrasing. In Russian: use Вы with full formal constructions. No exclamation marks unless the source had them. This register overrides any informality implied by the app context."
        case .polite:
            return "polite, friendly register — the way you'd write to a colleague, acquaintance, or in a warm but professional message. In English: complete sentences, contractions OK, warm but professional. In Korean: use 해요체 (-아요 / -어요 / -해요), not 합쇼체 and not 반말. In Japanese: use です/ます in their everyday softer form. In Russian: use Вы with conversational warmth. This register overrides any informality implied by the app context."
        case .casual:
            return "casual register — the way you'd write to a close friend. In English: natural casual capitalization (still capitalize names and sentence starts). In Korean: use 반말 (-해, -야, -지), never 해요체 and never 합쇼체. In Japanese: use plain form (だ/する). In Russian: use ты-forms. Lighter punctuation — periods optional at the ends of short messages. Conversational rhythm."
        }
    }
}

enum CleanupLevel: String, CaseIterable, Codable {
    case none
    case light
    case medium
    case high

    var displayName: String {
        switch self {
        case .none: return "None"
        case .light: return "Light"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var promptDescription: String {
        switch self {
        case .none:
            return "do not polish wording — preserve the source phrasing as faithfully as the target language allows."
        case .light:
            return "fix obvious typos, grammar errors, OCR/line-break artifacts. Do not rewrite for style."
        case .medium:
            return "edit lightly for clarity and flow — fix typos and awkward phrasing, but do not rephrase aggressively."
        case .high:
            return "polish thoroughly for brevity and clarity. Tighten verbose sentences, drop filler words, keep meaning intact."
        }
    }
}

enum AppCategoryClassifier {
    static let bundleIDMap: [String: AppCategory] = [
        "com.apple.mail": .email,
        "com.microsoft.Outlook": .email,
        "com.readdle.smartemail-Mac": .email,
        "com.superhuman.electron": .email,
        "com.tinyspeck.slackmacgap": .workMessages,
        "com.microsoft.teams2": .workMessages,
        "com.microsoft.teams": .workMessages,
        "com.linkedin.LinkedIn": .workMessages,
        "com.apple.MobileSMS": .personalMessages,
        "com.apple.iChat": .personalMessages,
        "ru.keepcoder.Telegram": .personalMessages,
        "org.telegram.desktop": .personalMessages,
        "net.whatsapp.WhatsApp": .personalMessages,
        "com.kakao.KakaoTalk": .personalMessages,
        "com.kakao.KakaoTalkMac": .personalMessages,
        "com.hnc.Discord": .personalMessages,
    ]

    static func category(for bundleID: String?) -> AppCategory {
        guard let id = bundleID else { return .other }
        if let mapped = bundleIDMap[id] { return mapped }
        let lower = id.lowercased()
        if lower.contains("mail") || lower.contains("outlook") { return .email }
        if lower.contains("slack") || lower.contains("teams") { return .workMessages }
        return .other
    }

    static func detectFrontmost() -> (bundleID: String?, category: AppCategory) {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return (bundleID, category(for: bundleID))
    }
}

enum CloudProvider: String, Codable, CaseIterable {
    case openAI
    case anthropic
    case gemini

    var baseURL: URL {
        switch self {
        case .openAI:    URL(string: "https://api.openai.com/v1/chat/completions")!
        case .anthropic: URL(string: "https://api.anthropic.com/v1/chat/completions")!
        case .gemini:    URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
        }
    }

    var keychainService: String { "com.nugumi.app.\(rawValue.lowercased())" }

    var displayName: String {
        switch self {
        case .openAI:    "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini:    "Google Gemini"
        }
    }

    var apiKeyHelpURL: URL {
        switch self {
        case .openAI:    URL(string: "https://platform.openai.com/api-keys")!
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        case .gemini:    URL(string: "https://aistudio.google.com/app/apikey")!
        }
    }

    var modelsURL: URL {
        switch self {
        case .openAI:    URL(string: "https://api.openai.com/v1/models")!
        case .anthropic: URL(string: "https://api.anthropic.com/v1/models")!
        case .gemini:    URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/models")!
        }
    }
}

enum APIKeyValidator {
    enum Outcome {
        case valid
        case invalid(reason: String)
        case networkUnreachable(detail: String)
    }

    static func validate(_ apiKey: String, for provider: CloudProvider) async -> Outcome {
        var request = URLRequest(url: provider.modelsURL)
        request.httpMethod = "GET"
        switch provider {
        case .openAI, .gemini:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            // Native Anthropic /v1/models requires x-api-key + anthropic-version,
            // not the OpenAI-compat Bearer header (compat only covers /chat/completions).
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.timeoutInterval = 10
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .invalid(reason: "Invalid response from \(provider.displayName).")
            }
            switch http.statusCode {
            case 200..<300:
                return .valid
            case 401, 403:
                return .invalid(reason: "\(provider.displayName) rejected this key.")
            case 429:
                return .invalid(reason: "\(provider.displayName) rate-limited the check. Try later.")
            default:
                return .invalid(reason: "\(provider.displayName) returned HTTP \(http.statusCode).")
            }
        } catch let urlError as URLError where urlError.code == .notConnectedToInternet
            || urlError.code == .cannotConnectToHost
            || urlError.code == .cannotFindHost
            || urlError.code == .timedOut
            || urlError.code == .networkConnectionLost {
            return .networkUnreachable(detail: urlError.localizedDescription)
        } catch {
            return .networkUnreachable(detail: error.localizedDescription)
        }
    }
}

enum KeychainStore {
    private enum CacheEntry {
        case missing
        case present(String)
    }
    private static var cache: [CloudProvider: CacheEntry] = [:]

    private static let storageDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appending(path: "Nugumi", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func apiKey(for provider: CloudProvider) -> String? {
        if let entry = cache[provider] {
            switch entry {
            case .missing: return nil
            case .present(let key): return key
            }
        }
        let key = readFromFile(for: provider)
        cache[provider] = key.map { .present($0) } ?? .missing
        return key
    }

    static func setAPIKey(_ key: String?, for provider: CloudProvider) {
        let url = fileURL(for: provider)
        guard let key, !key.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            cache[provider] = .missing
            return
        }
        do {
            try key.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // If we can't write, at least keep the in-memory cache so this session works.
        }
        cache[provider] = .present(key)
    }

    private static func readFromFile(for provider: CloudProvider) -> String? {
        let url = fileURL(for: provider)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func fileURL(for provider: CloudProvider) -> URL {
        storageDirectory.appending(path: "\(provider.rawValue).key", directoryHint: .notDirectory)
    }
}

struct ImageInput {
    let data: Data
    let mediaType: String

    var base64String: String { data.base64EncodedString() }
    var openAIDataURI: String { "data:\(mediaType);base64,\(base64String)" }
}

protocol LLMBackend {
    func translate(
        _ text: String,
        images: [ImageInput],
        to targetLanguage: TranslationLanguage,
        mode: TranslationMode,
        appCategory: AppCategory,
        composition: CompositionSettings?,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String

    func ask(
        history: [AskNugumiTurn],
        question: String,
        image: ImageInput?,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> AskNugumiResponse
}

struct OllamaClient: LLMBackend {
    let baseURL: URL
    let model: String

    func ask(
        history: [AskNugumiTurn],
        question: String,
        image: ImageInput?,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> AskNugumiResponse {
        throw TranslationError.ollama("Ask Nugumi is available with a cloud provider.")
    }

    func translate(
        _ text: String,
        images: [ImageInput] = [],
        to targetLanguage: TranslationLanguage,
        mode: TranslationMode = .selection,
        appCategory: AppCategory,
        composition: CompositionSettings? = nil,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        let sourceText: String
        switch mode {
        case .selection, .smartReply:
            sourceText = TextNormalizer.cleanedSelection(text)
        case .draftMessage:
            sourceText = TextNormalizer.cleanedDraftMessage(text)
        }
        guard !sourceText.isEmpty else {
            throw TranslationError.emptyResponse
        }

        let url = baseURL.appending(path: "api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        if !images.isEmpty, !LLMModel.option(id: model).supportsImages {
            throw TranslationError.ollama("Selected Ollama model doesn't support images.")
        }

        let imageStrings = images.isEmpty ? nil : images.map(\.base64String)
        let body = ChatRequest(
            model: model,
            stream: true,
            think: thinkingLevel.rawValue,
            messages: [
                ChatMessage(
                    role: "system",
                    content: mode.systemPrompt(
                        targetLanguage: targetLanguage,
                        appCategory: appCategory,
                        composition: composition
                    )
                ),
                ChatMessage(role: "user", content: sourceText, images: imageStrings)
            ]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
            || urlError.code == .cannotFindHost
            || urlError.code == .networkConnectionLost
            || urlError.code == .notConnectedToInternet {
            throw TranslationError.serverUnavailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.ollama("invalid response")
        }

        if httpResponse.statusCode == 404 {
            throw TranslationError.modelMissing(model)
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw TranslationError.signInRequired
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TranslationError.ollama("HTTP \(httpResponse.statusCode)")
        }

        var translated = ""
        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8) else {
                continue
            }

            if let streamError = try? decoder.decode(StreamError.self, from: data),
               let message = streamError.error {
                throw OllamaClient.classifyStreamError(message: message, model: model)
            }

            let decoded = try decoder.decode(ChatResponse.self, from: data)
            translated += decoded.message.content

            let partial = TextNormalizer.cleanedTranslation(translated)
            if !partial.isEmpty {
                onPartial(partial)
            }

            if decoded.done {
                break
            }
        }

        let finalTranslation = TextNormalizer.cleanedTranslation(translated)
        guard !finalTranslation.isEmpty else {
            throw TranslationError.emptyResponse
        }

        return finalTranslation
    }

    static func classifyStreamError(message: String, model: String) -> TranslationError {
        let lowered = message.lowercased()
        if lowered.contains("not found") && (lowered.contains("model") || lowered.contains("manifest")) {
            return .modelMissing(model)
        }
        if lowered.contains("unauthorized")
            || lowered.contains("sign in")
            || lowered.contains("not signed in")
            || lowered.contains("signin")
            || lowered.contains("authenticate")
            || lowered.contains("forbidden") {
            return .signInRequired
        }
        return .ollama(message)
    }
}

struct OpenAIChatClient: LLMBackend {
    let provider: CloudProvider
    let apiKey: String
    let model: String

    private static let maxImageBytes = 5 * 1024 * 1024

    func ask(
        history: [AskNugumiTurn],
        question: String,
        image: ImageInput?,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> AskNugumiResponse {
        guard !apiKey.isEmpty else {
            throw TranslationError.invalidAPIKey(provider)
        }

        if let image {
            guard LLMModel.option(id: model).supportsImages else {
                throw TranslationError.cloudError(provider, "Ask Nugumi with a screenshot needs a vision model.")
            }
            guard image.data.count <= Self.maxImageBytes else {
                throw TranslationError.cloudError(provider, "Image too large (limit 5 MB)")
            }
        }

        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty else {
            return AskNugumiResponse(message: "", petTarget: nil, emotion: nil)
        }

        let currentPrompt = AskNugumiPromptBuilder.prompt(question: cleanQuestion, hasImage: image != nil)
        let currentUserContent: OpenAIContent
        if let image {
            currentUserContent = .parts([
                .text(currentPrompt),
                .imageURL(image.openAIDataURI)
            ])
        } else {
            currentUserContent = .string(currentPrompt)
        }

        var messages: [OpenAIMessage] = [
            OpenAIMessage(role: "system", content: .string(AskNugumiPromptBuilder.systemPrompt))
        ]
        for turn in history {
            messages.append(OpenAIMessage(role: "user", content: .string(turn.question)))
            messages.append(OpenAIMessage(role: "assistant", content: .string(turn.answer)))
        }
        messages.append(OpenAIMessage(role: "user", content: currentUserContent))

        let body = OpenAIRequest(
            model: model,
            stream: true,
            messages: messages,
            thinkingOptions: CloudThinkingOptions(
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel
            )
        )

        var request = URLRequest(url: provider.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(body)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
            || urlError.code == .cannotFindHost
            || urlError.code == .networkConnectionLost
            || urlError.code == .notConnectedToInternet
            || urlError.code == .timedOut {
            throw TranslationError.cloudError(provider, urlError.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.cloudError(provider, "invalid response")
        }

        switch httpResponse.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw TranslationError.invalidAPIKey(provider)
        case 429:
            throw TranslationError.rateLimited(provider)
        default:
            throw TranslationError.cloudError(provider, "HTTP \(httpResponse.statusCode)")
        }

        var answer = ""
        let decoder = JSONDecoder()
        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(":") { continue }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }
            if let streamError = try? decoder.decode(OpenAIStreamError.self, from: data) {
                throw TranslationError.cloudError(provider, streamError.displayMessage)
            }
            guard let chunk = try? decoder.decode(OpenAIStreamChunk.self, from: data) else {
                throw TranslationError.cloudError(provider, "Unexpected stream payload")
            }
            if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                answer += delta
                onPartial(answer)
            }
            if chunk.choices.first?.finishReason != nil { break }
        }

        let parsed = AskNugumiResponse.parse(answer)
        guard !parsed.message.isEmpty else {
            throw TranslationError.emptyResponse
        }
        return parsed
    }

    func translate(
        _ text: String,
        images: [ImageInput] = [],
        to targetLanguage: TranslationLanguage,
        mode: TranslationMode = .selection,
        appCategory: AppCategory,
        composition: CompositionSettings? = nil,
        thinkingLevel: ThinkingLevel,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw TranslationError.invalidAPIKey(provider)
        }

        let sourceText: String
        switch mode {
        case .selection, .smartReply:
            sourceText = TextNormalizer.cleanedSelection(text)
        case .draftMessage:
            sourceText = TextNormalizer.cleanedDraftMessage(text)
        }
        guard !sourceText.isEmpty || !images.isEmpty else {
            throw TranslationError.emptyResponse
        }

        for image in images where image.data.count > Self.maxImageBytes {
            throw TranslationError.cloudError(provider, "Image too large (limit 5 MB)")
        }

        let systemPrompt = mode.systemPrompt(
            targetLanguage: targetLanguage,
            appCategory: appCategory,
            composition: composition
        )
        let userContent: OpenAIContent = images.isEmpty
            ? .string(sourceText)
            : .parts([.text(sourceText)] + images.map { .imageURL($0.openAIDataURI) })

        let body = OpenAIRequest(
            model: model,
            stream: true,
            messages: [
                OpenAIMessage(role: "system", content: .string(systemPrompt)),
                OpenAIMessage(role: "user", content: userContent)
            ],
            thinkingOptions: CloudThinkingOptions(
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel
            )
        )

        var request = URLRequest(url: provider.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(body)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
            || urlError.code == .cannotFindHost
            || urlError.code == .networkConnectionLost
            || urlError.code == .notConnectedToInternet
            || urlError.code == .timedOut {
            throw TranslationError.cloudError(provider, urlError.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.cloudError(provider, "invalid response")
        }

        switch httpResponse.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw TranslationError.invalidAPIKey(provider)
        case 429:
            throw TranslationError.rateLimited(provider)
        default:
            throw TranslationError.cloudError(provider, "HTTP \(httpResponse.statusCode)")
        }

        var translated = ""
        let decoder = JSONDecoder()
        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(":") { continue }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }
            if let streamError = try? decoder.decode(OpenAIStreamError.self, from: data) {
                throw TranslationError.cloudError(provider, streamError.displayMessage)
            }
            guard let chunk = try? decoder.decode(OpenAIStreamChunk.self, from: data) else {
                throw TranslationError.cloudError(provider, "Unexpected stream payload")
            }
            if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                translated += delta
                let partial = TextNormalizer.cleanedTranslation(translated)
                if !partial.isEmpty {
                    onPartial(partial)
                }
            }
            if chunk.choices.first?.finishReason != nil { break }
        }

        let finalTranslation = TextNormalizer.cleanedTranslation(translated)
        guard !finalTranslation.isEmpty else {
            throw TranslationError.emptyResponse
        }
        return finalTranslation
    }
}

private enum OpenAIContent: Encodable {
    case string(String)
    case parts([OpenAIPart])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let text):
            try container.encode(text)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
}

private enum OpenAIPart: Encodable {
    case text(String)
    case imageURL(String)

    private enum CodingKeys: String, CodingKey {
        case type, text, image_url
    }

    private struct ImageURLBox: Encodable {
        let url: String
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageURL(let url):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageURLBox(url: url), forKey: .image_url)
        }
    }
}

private struct OpenAIMessage: Encodable {
    let role: String
    let content: OpenAIContent
}

struct CloudThinkingOptions: Encodable, Equatable {
    let reasoningEffort: String?
    let thinking: AnthropicThinkingConfig?
    let outputConfig: AnthropicOutputConfig?

    init(provider: CloudProvider, model: String, thinkingLevel: ThinkingLevel) {
        switch provider {
        case .openAI, .gemini:
            reasoningEffort = thinkingLevel.cloudReasoningEffort
            thinking = nil
            outputConfig = nil
        case .anthropic:
            reasoningEffort = nil
            if Self.usesAdaptiveClaudeThinking(model: model) {
                thinking = AnthropicThinkingConfig(type: "adaptive")
                outputConfig = AnthropicOutputConfig(effort: thinkingLevel.cloudReasoningEffort)
            } else {
                thinking = AnthropicThinkingConfig(
                    type: "enabled",
                    budgetTokens: thinkingLevel.claudeThinkingBudgetTokens
                )
                outputConfig = nil
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case reasoningEffort = "reasoning_effort"
        case thinking
        case outputConfig = "output_config"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(thinking, forKey: .thinking)
        try container.encodeIfPresent(outputConfig, forKey: .outputConfig)
    }

    private static func usesAdaptiveClaudeThinking(model: String) -> Bool {
        let normalized = model.lowercased()
        return normalized.contains("claude-opus-4-7")
            || normalized.contains("claude-opus-4-6")
            || normalized.contains("claude-sonnet-4-6")
            || normalized.contains("claude-mythos")
    }
}

struct AnthropicThinkingConfig: Encodable, Equatable {
    let type: String
    let budgetTokens: Int?

    init(type: String, budgetTokens: Int? = nil) {
        self.type = type
        self.budgetTokens = budgetTokens
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case budgetTokens = "budget_tokens"
    }
}

struct AnthropicOutputConfig: Encodable, Equatable {
    let effort: String
}

private extension ThinkingLevel {
    var cloudReasoningEffort: String { rawValue }

    var claudeThinkingBudgetTokens: Int {
        switch self {
        case .low: return 1_024
        case .medium: return 2_048
        case .high: return 4_096
        }
    }
}

private struct OpenAIRequest: Encodable {
    let model: String
    let stream: Bool
    let messages: [OpenAIMessage]
    let thinkingOptions: CloudThinkingOptions?

    private enum CodingKeys: String, CodingKey {
        case model
        case stream
        case messages
        case reasoningEffort = "reasoning_effort"
        case thinking
        case outputConfig = "output_config"
    }

    init(
        model: String,
        stream: Bool,
        messages: [OpenAIMessage],
        thinkingOptions: CloudThinkingOptions? = nil
    ) {
        self.model = model
        self.stream = stream
        self.messages = messages
        self.thinkingOptions = thinkingOptions
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(stream, forKey: .stream)
        try container.encode(messages, forKey: .messages)
        try container.encodeIfPresent(thinkingOptions?.reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(thinkingOptions?.thinking, forKey: .thinking)
        try container.encodeIfPresent(thinkingOptions?.outputConfig, forKey: .outputConfig)
    }
}

private struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }
        let delta: Delta
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }
    let choices: [Choice]
}

private struct OpenAIStreamError: Decodable {
    struct ErrorBody: Decodable {
        let message: String?
        let type: String?
        let code: String?
    }

    let error: ErrorBody

    var displayMessage: String {
        error.message ?? error.type ?? error.code ?? "stream error"
    }
}

struct ChatRequest: Encodable {
    let model: String
    let stream: Bool
    let think: String
    let messages: [ChatMessage]
}

struct ChatMessage: Codable {
    let role: String
    let content: String
    let images: [String]?

    init(role: String, content: String, images: [String]? = nil) {
        self.role = role
        self.content = content
        self.images = images
    }
}

struct ChatResponse: Decodable {
    let message: ChatMessage
    let done: Bool
}

struct StreamError: Decodable {
    let error: String?
}

enum TranslationError: LocalizedError {
    case ollama(String)
    case emptyResponse
    case serverUnavailable
    case modelMissing(String)
    case signInRequired
    case modelDownloading(String)
    case invalidAPIKey(CloudProvider)
    case rateLimited(CloudProvider)
    case cloudError(CloudProvider, String)

    var errorDescription: String? {
        switch self {
        case .ollama(let message):
            "Translation request failed: \(message)"
        case .emptyResponse:
            "Got an empty translation. Try again."
        case .serverUnavailable:
            "The translator isn't running. Open setup to fix it."
        case .modelMissing:
            "The translator isn't downloaded yet. Open setup to download it."
        case .signInRequired:
            "Sign in to Ollama to use the online translator. Open setup to finish."
        case .modelDownloading(let detail):
            "\(detail) Try again when the translator is ready."
        case .invalidAPIKey(let provider):
            "\(provider.displayName) rejected the API key. Open settings to update it."
        case .rateLimited(let provider):
            "\(provider.displayName) rate limit reached. Try again in a minute, or switch model."
        case .cloudError(let provider, let detail):
            "\(provider.displayName): \(detail)"
        }
    }
}

extension NugumiApp: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        usageStatsStore.refresh()
        updateMenuState()
        if let usageItem = menu.item(withTag: MenuItemTag.usageStatsSummary.rawValue) as? UsageStatsMenuItem {
            usageItem.refitFrame()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard shouldReopenStatusMenuAfterClose else { return }
        shouldReopenStatusMenuAfterClose = false
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.button?.performClick(nil)
        }
    }
}
