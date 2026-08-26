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

struct GlobalHotKeyDefinition {
    static let signature = OSType(0x54524E53) // TRNS

    /// Where per-gizmo hotkey ids start. Ids are process-local — nothing
    /// persists them, every launch registers afresh — so a tool's id is just
    /// base + its index in the current registration pass. The built-in actions
    /// own 2...13 and the Ask alias owns 100, all far below this.
    static let toolHotKeyIDBase: UInt32 = 1000

    let id: UInt32
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let modifierFlags: NSEvent.ModifierFlags
    let displayString: String

    init(action: GlobalShortcutAction, shortcut: GlobalShortcut) {
        self.init(id: action.id, shortcut: shortcut)
    }

    /// Explicit-id variant for fixed hotkeys that aren't backed by a
    /// `GlobalShortcutAction` slot (e.g. the always-on Ask Gizmate ⌃⌥A alias).
    init(id: UInt32, shortcut: GlobalShortcut) {
        self.id = id
        keyCode = shortcut.keyCode
        carbonModifiers = shortcut.carbonModifiers
        modifierFlags = shortcut.modifiers
        displayString = shortcut.displayString
    }
}

final class GlobalHotKey {
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

