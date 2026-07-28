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

