import AppKit
import AVKit
import Combine
import SwiftUI

// MARK: - Window controller

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static var hasCompletedFeatureTour: Bool { OnboardingModel.hasCompletedFeatureTour }

    /// True when the window closed only to make room for a macOS permission
    /// dialog (it will be re-presented by the trust watchers) — distinguishes
    /// that from the user actually finishing or dismissing onboarding.
    private(set) var closedForSystemDialog = false

    /// 16:9 so the 1920×1080 intro clip fills the window edge to edge.
    private static let introContentSize = NSSize(width: 960, height: 540)
    private static let standardContentSize = NSSize(width: 900, height: 640)
    /// Feature tour: a full-width 16:9 video hero on top (720×405) with the
    /// title, how-to card and buttons stacked beneath it. Height is sized to
    /// hug the content so the buttons sit just under the steps, not way below.
    private static let featureContentSize = NSSize(width: 720, height: 735)

    private let model: OnboardingModel
    private let onClose: () -> Void

    init(
        mode: OnboardingModel.Mode,
        onPickEngine: @escaping (EngineSetupFocus) -> Void,
        onTourFinished: ((_ skipped: Bool) -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        let model = OnboardingModel(mode: mode)
        self.model = model
        self.onClose = onClose
        model.openEngineSetup = onPickEngine
        model.onTourFinished = onTourFinished

        let contentSize = Self.contentSize(for: model.page)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Set up Gizmate"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()

        super.init(window: window)
        window.delegate = self

        // Same liquid-glass backdrop as the main window.
        let hosting = NSHostingView(rootView: OnboardingRootView(model: model))
        // Don't let SwiftUI's ideal size drive the window frame — the layout
        // stretches to .infinity, which would balloon the window. The window
        // size is controlled here (960×540 for the intro, 900×640 after)
        // and SwiftUI fills it.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.appearance = NSAppearance(named: .darkAqua)
        backdrop.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: backdrop.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        window.contentView = backdrop

        model.requestClose = { [weak self] in
            self?.close()
        }
        model.closeBeforeSystemDialog = { [weak self] in
            self?.closedForSystemDialog = true
            self?.window?.orderOut(nil)
            self?.close()
        }
        model.pageDidChange = { [weak self] page in
            self?.resizeWindow(for: page)
        }
    }

    /// Grows the window from the widescreen intro frame to the standard
    /// two-column frame (and back, in theory), keeping it centered in place.
    private static func contentSize(for page: OnboardingModel.Page) -> NSSize {
        switch page {
        case .intro: return introContentSize
        case .feature: return featureContentSize
        case .permissions, .finale: return standardContentSize
        }
    }

    private func resizeWindow(for page: OnboardingModel.Page) {
        guard let window else { return }
        let target = Self.contentSize(for: page)
        let current = window.contentRect(forFrameRect: window.frame).size
        guard abs(current.width - target.width) > 0.5 || abs(current.height - target.height) > 0.5 else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: target))
        frame.origin.x = window.frame.midX - frame.width / 2
        frame.origin.y = window.frame.midY - frame.height / 2
        window.setFrame(frame, display: true, animate: true)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func presentAndActivate() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            switch self.model.page {
            case .feature:
                self.model.finishTour(skipped: true)
            case .finale:
                self.model.finishTour(skipped: false)
            case .intro, .permissions:
                break
            }
            self.onClose()
        }
    }
}
