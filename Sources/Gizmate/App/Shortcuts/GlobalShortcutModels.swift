import AppKit
import Carbon.HIToolbox
import Foundation

enum GlobalShortcutAction: String, CaseIterable {
    case translateOrReply
    case translateSelection
    case screenshotArea
    case toggleInvisibility
    case askGizmate
    case toggleWritingLanguage
    case liveTranslation
    case quickMenu

    var id: UInt32 {
        switch self {
        case .translateOrReply: return 1
        case .translateSelection: return 2
        case .screenshotArea: return 3
        case .toggleInvisibility: return 4
        case .askGizmate: return 5
        case .toggleWritingLanguage: return 6
        case .liveTranslation: return 7
        case .quickMenu: return 8
        }
    }

    var defaultsKey: String {
        "globalShortcut.\(rawValue)"
    }

    var menuTitle: String {
        switch self {
        case .translateOrReply: return "Translate selected text"
        case .translateSelection: return "Rewrite my text"
        case .screenshotArea: return "Translate screen area"
        case .toggleInvisibility: return "Toggle invisibility mode"
        case .askGizmate: return "Ask Gizmate"
        case .toggleWritingLanguage: return "Toggle writing language"
        case .liveTranslation: return "Live translation captions"
        case .quickMenu: return "Open quick menu"
        }
    }

    var recorderTitle: String {
        "Set \(menuTitle) shortcut"
    }

    var group: ShortcutGroup {
        switch self {
        case .translateOrReply, .translateSelection, .toggleWritingLanguage:
            return .text
        case .screenshotArea, .liveTranslation:
            return .capture
        case .askGizmate:
            return .assistant
        case .toggleInvisibility, .quickMenu:
            return .app
        }
    }

    var defaultShortcut: GlobalShortcut {
        switch self {
        case .translateOrReply:
            return Self.comboDefault(keyCode: UInt32(kVK_ANSI_T), letter: "T")
        case .translateSelection:
            return Self.comboDefault(keyCode: UInt32(kVK_ANSI_R), letter: "R")
        case .screenshotArea:
            return Self.comboDefault(keyCode: UInt32(kVK_ANSI_S), letter: "S")
        case .toggleInvisibility:
            return Self.comboDefault(keyCode: UInt32(kVK_ANSI_I), letter: "I")
        case .askGizmate:
            // Signature gesture — double-tap ⌃. Stays rebindable so a user
            // plagued by accidental misfires can move it to a plain combo. The
            // always-on ⌃⌥A alias (askGizmateAlias) is the discoverable,
            // menu-visible way in; it is NOT user-rebindable.
            return GlobalShortcut(doubleTapModifier: .control)
        case .toggleWritingLanguage:
            return Self.comboDefault(keyCode: UInt32(kVK_ANSI_G), letter: "G")
        case .liveTranslation:
            return Self.comboDefault(keyCode: UInt32(kVK_ANSI_L), letter: "L")
        case .quickMenu:
            // Middle click ("Mouse 3") — the ring opens at the cursor, so a
            // mouse trigger is the natural default. Rebindable to a key combo.
            return GlobalShortcut(mouseButton: 2)
        }
    }

    /// Always-on secondary trigger for Ask Gizmate (⌃⌥A). Registered alongside
    /// the rebindable double-tap ⌃ and reserved by the conflict checker so no
    /// other action can shadow it.
    static let askGizmateAlias = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_A),
        modifiers: [.control, .option],
        keyEquivalent: "a",
        keyDisplay: "A"
    )

    /// All combo defaults share the ⌃⌥ ("Control+Option") base — the documented
    /// safe zone for global hotkeys: clear of ⌘-menu commands, ⌃-letter terminal
    /// bindings, and ⌥-letter accented-character entry. Letters stay mnemonic.
    private static func comboDefault(keyCode: UInt32, letter: String) -> GlobalShortcut {
        GlobalShortcut(
            keyCode: keyCode,
            modifiers: [.control, .option],
            keyEquivalent: letter.lowercased(),
            keyDisplay: letter
        )
    }
}

/// Display grouping for the Shortcuts settings panel — chunks the 7 actions by
/// the object they act on, so the list reads as a few categories, not a flat wall.
enum ShortcutGroup: String, CaseIterable {
    case text, capture, assistant, app

    var title: String {
        switch self {
        case .text: return "Text"
        case .capture: return "Capture"
        case .assistant: return "Assistant"
        case .app: return "App"
        }
    }
}

struct GlobalShortcut: Codable, Equatable {
    static let supportedModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    static let singleModifierOptions: [NSEvent.ModifierFlags] = [.control, .option, .shift, .command]

    enum Kind: String, Codable {
        case combo
        case doubleTap
        case mouseButton
    }

    let kind: Kind
    let keyCode: UInt32
    private let modifiersRawValue: UInt
    let keyEquivalent: String
    let keyDisplay: String

    init(
        keyCode: UInt32,
        modifiers: NSEvent.ModifierFlags,
        keyEquivalent: String,
        keyDisplay: String
    ) {
        self.kind = .combo
        self.keyCode = keyCode
        self.modifiersRawValue = modifiers.intersection(Self.supportedModifiers).rawValue
        self.keyEquivalent = keyEquivalent
        self.keyDisplay = keyDisplay
    }

    init(doubleTapModifier modifier: NSEvent.ModifierFlags) {
        self.kind = .doubleTap
        self.keyCode = 0
        self.modifiersRawValue = modifier.intersection(Self.supportedModifiers).rawValue
        self.keyEquivalent = ""
        self.keyDisplay = ""
    }

    /// `buttonNumber` is the `NSEvent.buttonNumber` (0 = left, 1 = right,
    /// 2 = middle, …). Only buttons ≥ 2 are valid — left/right clicks can
    /// never become global shortcuts.
    init(mouseButton buttonNumber: UInt32) {
        self.kind = .mouseButton
        self.keyCode = buttonNumber
        self.modifiersRawValue = 0
        self.keyEquivalent = ""
        self.keyDisplay = ""
    }

    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(Self.supportedModifiers)
        guard !modifiers.isEmpty else {
            return nil
        }

        let characters = event.charactersIgnoringModifiers
        let keyDisplay = ShortcutKeyFormatter.displayName(
            keyCode: UInt32(event.keyCode),
            characters: characters
        )
        guard !keyDisplay.isEmpty else {
            return nil
        }

        self.init(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers,
            keyEquivalent: ShortcutKeyFormatter.menuEquivalent(
                keyCode: UInt32(event.keyCode),
                characters: characters
            ),
            keyDisplay: keyDisplay
        )
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case keyCode
        case modifiersRawValue
        case keyEquivalent
        case keyDisplay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Old encodings (pre-Ask-Gizmate) have no `kind` field — treat as .combo.
        self.kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .combo
        self.keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        self.modifiersRawValue = try container.decode(UInt.self, forKey: .modifiersRawValue)
        self.keyEquivalent = try container.decode(String.self, forKey: .keyEquivalent)
        self.keyDisplay = try container.decode(String.self, forKey: .keyDisplay)
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiersRawValue).intersection(Self.supportedModifiers)
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.control) {
            result |= UInt32(controlKey)
        }
        if modifiers.contains(.option) {
            result |= UInt32(optionKey)
        }
        if modifiers.contains(.shift) {
            result |= UInt32(shiftKey)
        }
        if modifiers.contains(.command) {
            result |= UInt32(cmdKey)
        }
        return result
    }

    var menuKeyEquivalent: String {
        kind == .combo ? keyEquivalent : ""
    }

    var keyEquivalentModifierMask: NSEvent.ModifierFlags {
        kind == .combo ? modifiers : []
    }

    var displayString: String {
        let modifierGlyphs = Self.modifierGlyphs(for: modifiers)
        switch kind {
        case .combo:
            return modifierGlyphs + keyDisplay
        case .doubleTap:
            // "⌃⌃" / "⌥⌥" / "⇧⇧" / "⌘⌘"
            return modifierGlyphs + modifierGlyphs
        case .mouseButton:
            // Humans number mouse buttons from 1; NSEvent from 0.
            return "Mouse \(keyCode + 1)"
        }
    }

    var isValid: Bool {
        switch kind {
        case .combo:
            return !modifiers.isEmpty && !keyDisplay.isEmpty
        case .doubleTap:
            return Self.singleModifierOptions.contains { modifiers == $0 }
        case .mouseButton:
            return keyCode >= 2
        }
    }

    private static func modifierGlyphs(for modifiers: NSEvent.ModifierFlags) -> String {
        var prefix = ""
        if modifiers.contains(.control) {
            prefix += "⌃"
        }
        if modifiers.contains(.option) {
            prefix += "⌥"
        }
        if modifiers.contains(.shift) {
            prefix += "⇧"
        }
        if modifiers.contains(.command) {
            prefix += "⌘"
        }
        return prefix
    }

    static func == (lhs: GlobalShortcut, rhs: GlobalShortcut) -> Bool {
        guard lhs.kind == rhs.kind, lhs.modifiers == rhs.modifiers else {
            return false
        }
        switch lhs.kind {
        case .combo, .mouseButton:
            return lhs.keyCode == rhs.keyCode
        case .doubleTap:
            return true
        }
    }
}

private enum ShortcutKeyFormatter {
    static func displayName(keyCode: UInt32, characters: String?) -> String {
        if let name = displayNames[keyCode] {
            return name
        }

        guard let characters, !characters.isEmpty else {
            return ""
        }

        return characters.uppercased()
    }

    static func menuEquivalent(keyCode: UInt32, characters: String?) -> String {
        if let equivalent = menuEquivalents[keyCode] {
            return equivalent
        }

        return characters?.lowercased() ?? ""
    }

    private static let displayNames: [UInt32: String] = [
        UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab",
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Delete): "Delete",
        UInt32(kVK_Escape): "Esc",
        UInt32(kVK_Command): "Command",
        UInt32(kVK_Shift): "Shift",
        UInt32(kVK_CapsLock): "Caps Lock",
        UInt32(kVK_Option): "Option",
        UInt32(kVK_Control): "Control",
        UInt32(kVK_RightCommand): "Command",
        UInt32(kVK_RightShift): "Shift",
        UInt32(kVK_RightOption): "Option",
        UInt32(kVK_RightControl): "Control",
        UInt32(kVK_F1): "F1",
        UInt32(kVK_F2): "F2",
        UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7",
        UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11",
        UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13",
        UInt32(kVK_F14): "F14",
        UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17",
        UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19",
        UInt32(kVK_F20): "F20",
        UInt32(kVK_Home): "Home",
        UInt32(kVK_End): "End",
        UInt32(kVK_PageUp): "Page Up",
        UInt32(kVK_PageDown): "Page Down",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_UpArrow): "↑"
    ]

    private static let menuEquivalents: [UInt32: String] = [
        UInt32(kVK_Return): "\r",
        UInt32(kVK_Tab): "\t",
        UInt32(kVK_Space): " ",
        UInt32(kVK_Delete): "\u{8}",
        UInt32(kVK_Escape): "\u{1B}",
        UInt32(kVK_LeftArrow): String(UnicodeScalar(NSLeftArrowFunctionKey)!),
        UInt32(kVK_RightArrow): String(UnicodeScalar(NSRightArrowFunctionKey)!),
        UInt32(kVK_DownArrow): String(UnicodeScalar(NSDownArrowFunctionKey)!),
        UInt32(kVK_UpArrow): String(UnicodeScalar(NSUpArrowFunctionKey)!)
    ]
}
