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

/// Contextual ring entry that reveals the chat-summary time-range layer. Non-nil
/// only when the frontmost app is a supported messenger — see
/// `NugumiApp.makeSummarizeOption`. `run` is coordinator-owned: it opens the
/// chat archive, matches the frontmost chat, fetches messages in the chosen
/// range, and panels the summary through the existing `translate(...)` path.
/// Reads the text of the web page open in a browser window straight off the
/// Accessibility tree. No Apple Events entitlement, no per-browser TCC
/// Automation prompt, no "Allow JavaScript from Apple Events" toggle — it
/// rides on the Accessibility permission Gizmo already holds.
enum BrowserPageReader {
    /// Frontmost apps that get the ring's summarize-page button. WebKit
    /// builds its AX tree eagerly; Chromium-based browsers build it lazily
    /// (see the attribute pokes in `pageText`).
    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",   // Arc
        "com.naver.whale",
        "org.mozilla.firefox",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    static func isBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return browserBundleIDs.contains(bundleID)
    }

    enum PageError: Error, CustomStringConvertible {
        case noWebArea
        case emptyPage
        var description: String {
            switch self {
            case .noWebArea: return "Couldn't find a readable web page in the browser window."
            case .emptyPage: return "The page has no readable text."
            }
        }
    }

    /// Matches the chat transcript's ~12k-token budget.
    private static let characterBudget = 48_000
    // ponytail: hard node cap bounds the AX IPC walk on pathological pages;
    // raise if real pages come back truncated.
    private static let nodeBudget = 20_000

    /// Collects the page text of `pid`'s focused browser window, top to
    /// bottom. Every AX call is a blocking mach IPC round-trip — call off
    /// the main thread.
    static func pageText(pid: pid_t) throws -> String {
        let appEl = AXUIElementCreateApplication(pid)
        // Chromium only builds its renderer AX tree once an assistive client
        // shows up. AXManualAccessibility is its "an app wants the tree, not
        // VoiceOver" switch; a harmless no-op on Safari/WebKit.
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var webArea: AXUIElement?
        for attempt in 0..<10 {
            if attempt > 0 { usleep(200_000) }
            // Older Chromium ignores AXManualAccessibility — fall back to the
            // VoiceOver flag, but only after the polite switch produced
            // nothing (it has known window-manager side effects).
            if attempt == 4 {
                AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
            guard let window = focusedWindow(of: appEl) else { continue }
            var areas: [AXUIElement] = []
            collectWebAreas(in: window, depth: 0, into: &areas)
            // A window can hold several web areas (sidebars, extension
            // popovers) — the page is the biggest one.
            if let biggest = areas.max(by: { area($0) < area($1) }), area(biggest) > 10_000 {
                webArea = biggest
                break
            }
        }
        guard let webArea else { throw PageError.noWebArea }

        var parts: [String] = []
        var characters = characterBudget
        var nodes = nodeBudget
        collectText(webArea, into: &parts, characters: &characters, nodes: &nodes, depth: 0)
        let text = parts.joined(separator: "\n")
        guard text.count >= 40 else { throw PageError.emptyPage }
        return text
    }

    private static func focusedWindow(of appEl: AXUIElement) -> AXUIElement? {
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let winEl = win, CFGetTypeID(winEl) == AXUIElementGetTypeID() else { return nil }
        return (winEl as! AXUIElement)
    }

    private static func children(of el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success,
              let arr = v as? [AXUIElement] else { return [] }
        return arr
    }

    private static func role(of el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func area(_ el: AXUIElement) -> CGFloat {
        var v: CFTypeRef?
        var size = CGSize.zero
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &v) == .success,
              let val = v, CFGetTypeID(val) == AXValueGetTypeID(),
              AXValueGetValue((val as! AXValue), .cgSize, &size) else { return 0 }
        return size.width * size.height
    }

    private static func collectWebAreas(in el: AXUIElement, depth: Int, into out: inout [AXUIElement]) {
        if depth > 24 || out.count >= 8 { return }
        if role(of: el) == "AXWebArea" { out.append(el); return }
        for child in children(of: el) { collectWebAreas(in: child, depth: depth + 1, into: &out) }
    }

    /// Depth-first, matching the page's visual top-to-bottom reading order.
    /// Buttons/links/headings all bottom out in AXStaticText leaves, so one
    /// role check covers the whole page (nav noise is the prompt's job).
    private static func collectText(
        _ el: AXUIElement,
        into parts: inout [String],
        characters: inout Int,
        nodes: inout Int,
        depth: Int
    ) {
        guard characters > 0, nodes > 0, depth <= 64 else { return }
        nodes -= 1
        if role(of: el) == kAXStaticTextRole {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success,
               let s = v as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parts.append(trimmed)
                    characters -= trimmed.count + 1
                }
            }
            return
        }
        for child in children(of: el) {
            collectText(child, into: &parts, characters: &characters, nodes: &nodes, depth: depth + 1)
            if characters <= 0 || nodes <= 0 { return }
        }
    }
}

