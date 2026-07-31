import AppKit
import Foundation

@MainActor
final class LiveCaptionPanelController: NSObject {
    private let panel: NSPanel
    private let indicatorPanel: NSPanel
    // The summary is a fixed-width column parked just off one edge of the player.
    // Opening it GROWS THE WINDOW to reveal it — the player's own layout never
    // changes, so it cannot drift while the window animates.
    private let summaryColumn = NSView()
    private let summarySep = HairlineSeparatorView()
    private let playerGuide = NSLayoutGuide()
    private var playerLeadingPin: NSLayoutConstraint!    // player flush-left  → summary opens on the right
    private var playerTrailingPin: NSLayoutConstraint!   // player flush-right → summary opens on the left
    private var summaryRightPins: [NSLayoutConstraint] = []
    private var summaryLeftPins: [NSLayoutConstraint] = []
    private var summaryOnRight = true
    private let summaryTextView = NSTextView()
    private let summaryTitleLabel = NSTextField(labelWithString: "Summary")
    private let summaryShimmer = ShimmerTextLabel()   // replaces the title while working
    private let followUpField = FollowUpTextField()
    private var summaryText = ""
    private var isSummaryShown = false
    private var isProgrammaticResize = false
    private var preSummaryFrame: NSRect?   // player frame before the summary opened — restored on close
    private static let summaryColumnWidth: CGFloat = 300
    private static let baseContentWidth: CGFloat = 380   // the player's fixed width (collapsed window width)

    private let statusLabel = NSTextField(labelWithString: "")
    private let costLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView()
    private let scrollView = OverlayScrollView()

    // Glass palette — mirrors TranslationPanelPalette (which is private to App.swift)
    // so the captions window matches the translate window's white-on-glass look.
    private static let glassCornerRadius: CGFloat = 22
    private static let titleColor = NSColor(calibratedWhite: 1.0, alpha: 0.84)
    private static let costColor = NSColor(calibratedWhite: 1.0, alpha: 0.45)
    private static let bodyColor = NSColor(calibratedWhite: 0.94, alpha: 0.96)
    private static let sourceColor = NSColor(calibratedWhite: 1.0, alpha: 0.42)
    private static let iconColor = NSColor(calibratedWhite: 1.0, alpha: 0.6)
    private static let iconColorActive = NSColor(calibratedWhite: 1.0, alpha: 0.95)

    private var pauseButton: HoverIconButton?
    private var summaryCopyButton: HoverIconButton?
    private var copiedRevert: Timer?              // reverts the copy glyph after the "copied" flash
    private var sourceToggleButton: NSButton?     // 🅰 show-original toggle
    private var audioSourceButton: HoverIconButton?  // single 🔊/🎙 toggle — shows the active source
    private var currentSource: LiveAudioSource = .systemAudio
    private var recordIndicator: RecordIndicatorView?
    /// Shared bottom-center point (screen coords). The captions window and the
    /// collapsed pill are both placed by their bottom-center here, so the pill
    /// sits at the window's bottom edge — and the choice follows wherever the
    /// user drags either one.
    private var anchorBottom: NSPoint?

    var onStop: (() -> Void)?
    var onToggleCollapse: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onToggleSource: (() -> Void)?
    var onSummarize: (() -> Void)?
    var onFollowUp: ((String) -> Void)?
    var onRestart: (() -> Void)?
    var onSourceChange: ((LiveAudioSource) -> Void)?

    override init() {
        panel = KeyableLivePanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        indicatorPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 148, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        super.init()
        configureFloating(panel)
        configureFloating(indicatorPanel)
        buildCaptions()
        buildIndicator()

        // Track user drags of either window so they share one anchor.
        for window in [panel, indicatorPanel] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(panelDidMove(_:)),
                name: NSWindow.didMoveNotification, object: window)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Shared anchor: horizontal center, BOTTOM edge. Both the window and the
    /// pill are placed by their bottom-center on this point, so collapsing drops
    /// the pill at the window's bottom (centered horizontally), not its middle.
    private func bottomCenter(of p: NSPanel) -> NSPoint {
        NSPoint(x: p.frame.midX, y: p.frame.minY)
    }

    /// Visible frame of the screen containing the anchor (or main screen).
    private func anchorScreen() -> NSRect {
        if let c = anchorBottom, let screen = NSScreen.screens.first(where: { $0.frame.contains(c) }) {
            return screen.visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// Places a panel by its bottom-center on the shared anchor, then clamps it
    /// fully inside the visible screen. The anchor is NOT changed by clamping —
    /// only user drags move it — so the pill returns to where it was dragged.
    private func placeAtAnchor(_ p: NSPanel) {
        let size = p.frame.size
        if anchorBottom == nil {
            let v = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            // Default: bottom-right with equal side and bottom insets.
            let inset: CGFloat = 20
            anchorBottom = NSPoint(x: v.maxX - size.width / 2 - inset, y: v.minY + inset)
        }
        guard let c = anchorBottom else { return }
        let screen = anchorScreen()
        let margin: CGFloat = 8
        var x = c.x - size.width / 2
        var y = c.y
        x = min(max(x, screen.minX + margin), screen.maxX - size.width - margin)
        y = min(max(y, screen.minY + margin), screen.maxY - size.height - margin)
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc private func panelDidMove(_ note: Notification) {
        guard !isProgrammaticResize else { return }   // ignore the expand/collapse resize
        guard let moved = note.object as? NSWindow else { return }
        if moved === indicatorPanel, indicatorPanel.isVisible {
            anchorBottom = bottomCenter(of: indicatorPanel)
        } else if moved === panel, panel.isVisible {
            anchorBottom = bottomCenter(of: panel)
        }
    }

    private func configureFloating(_ p: NSPanel) {
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
    }

    /// Installs the shared glass card (blur + hairline border) into a panel and
    /// returns the content view to lay out into.
    private func installGlass(in panel: NSPanel, cornerRadius: CGFloat) -> NSView {
        let root = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        root.autoresizingMask = [.width, .height]

        let glass = GlassHostView(frame: root.bounds, cornerRadius: cornerRadius, tintColor: nil, style: .regular)
        glass.autoresizingMask = [.width, .height]
        root.addSubview(glass)

        let chrome = GlassChromeOverlayView(frame: root.bounds)
        chrome.cornerRadius = cornerRadius
        chrome.autoresizingMask = [.width, .height]
        root.addSubview(chrome)

        panel.contentView = root
        return glass.contentView
    }

    // Hover is shown by brightening the icon tint (no background to clip).
    private static let hoverNeutral = NSColor(calibratedWhite: 1.0, alpha: 0.92)
    private static let hoverDanger = NSColor.systemRed

    private static func symbolImage(_ name: String, _ description: String, pointSize: CGFloat = 11) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular, scale: .medium)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(config) else { return nil }
        // SF Symbols carry asymmetric baseline padding and a short alignmentRect;
        // NSButton (flipped, scaleNone) then draws the glyph off-center inside the
        // round disc. Re-draw the symbol into a SQUARE canvas with its optical box
        // (alignmentRect) centered, so the cell's geometric centering lands the
        // glyph in the middle of the disc.
        let optical = symbol.alignmentRect
        let side = ceil(max(symbol.size.width, symbol.size.height))
        let canvas = NSImage(size: NSSize(width: side, height: side))
        canvas.lockFocus()
        symbol.draw(
            at: NSPoint(x: side / 2 - optical.midX, y: side / 2 - optical.midY),
            from: .zero, operation: .sourceOver, fraction: 1
        )
        canvas.unlockFocus()
        canvas.isTemplate = true
        return canvas
    }

    private func iconButton(_ symbol: String, tint: NSColor, hover: NSColor,
                            action: Selector, help: String, pointSize: CGFloat = 11) -> HoverIconButton {
        let button = HoverIconButton(title: "", target: self, action: action)
        button.image = Self.symbolImage(symbol, help, pointSize: pointSize)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone          // render at the symbol's natural size — no squishing
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.baseTint = tint
        button.hoverTint = hover
        button.contentTintColor = tint
        button.toolTip = help
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// Active state is shown by a brighter icon tint only — no background chip.
    private func applySelection(_ button: NSButton?, selected: Bool) {
        guard let button = button as? HoverIconButton else { return }
        button.baseTint = selected ? Self.iconColorActive : Self.iconColor
        button.contentTintColor = button.baseTint
    }

    private static let roundRestingBG = NSColor(calibratedWhite: 1.0, alpha: 0.08)
    private static let roundHoverBG = NSColor(calibratedWhite: 1.0, alpha: 0.16)

    /// Circular icon button (translucent disc behind the glyph), brightening on
    /// hover — the bottom-toolbar style. Pass `tint`/`restingBG`/`hoverBG` to
    /// accent a button (e.g. red Stop).
    private func roundButton(_ symbol: String, action: Selector, help: String,
                             tint: NSColor? = nil,
                             restingBG: NSColor? = nil, hoverBG: NSColor? = nil,
                             pointSize: CGFloat = 13) -> HoverIconButton {
        let resolvedTint = tint ?? Self.iconColor
        let button = HoverIconButton(title: "", target: self, action: action)
        button.image = Self.symbolImage(symbol, help, pointSize: pointSize)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.roundedFull = true
        button.baseTint = resolvedTint
        button.contentTintColor = resolvedTint
        button.restingBG = restingBG ?? Self.roundRestingBG
        button.hoverBG = hoverBG ?? Self.roundHoverBG
        button.toolTip = help
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// Text-only "Summarize" pill — the primary action reads as a word.
    /// Rounded-rect background mode (vs. the round icon buttons).
    private func makeSummarizeButton() -> HoverIconButton {
        let button = HoverIconButton(title: "Summarize", target: self, action: #selector(summarizeTapped))
        button.imagePosition = .noImage
        button.attributedTitle = NSAttributedString(string: "Summarize", attributes: [
            .foregroundColor: Self.titleColor,
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        ])
        button.contentTintColor = Self.iconColorActive
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.corner = 14
        button.restingBG = Self.roundRestingBG
        button.hoverBG = Self.roundHoverBG
        button.toolTip = "Summarize the conversation so far"
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// Rounded translucent "inset card" that groups controls — replaces the
    /// hairline dividers with the Voice-Memos-style container look.
    private func insetContainer(draggable: Bool = false) -> NSView {
        let view = draggable ? DragHandleView() : NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.05).cgColor
        view.layer?.cornerRadius = 14
        view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor(calibratedWhite: 1.0, alpha: 0.08).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    private func buildCaptions() {
        let content = installGlass(in: panel, cornerRadius: Self.glassCornerRadius)

        // The player occupies a fixed-width layout guide pinned to one content
        // edge; the summary column sits just past the other edge of that guide,
        // off-window until the window grows to reveal it.
        content.addLayoutGuide(playerGuide)
        buildSummaryColumn(in: content)
        let lead = playerGuide.leadingAnchor
        let trail = playerGuide.trailingAnchor

        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = Self.titleColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        costLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        costLabel.textColor = Self.costColor
        costLabel.alignment = .right
        costLabel.translatesAutoresizingMaskIntoConstraints = false

        // Top-right window control — minimize only (Stop lives in the toolbar).
        let collapseButton = iconButton("minus", tint: Self.iconColor, hover: Self.hoverNeutral,
                                        action: #selector(collapseTapped), help: "Minimize")

        // Bottom toolbar — circular-bg icons: [⏮ ⏸ ⏹]  …  [🅰 🔊/🎙 ✨].
        // Left cluster: transport.
        let restartButton = roundButton("backward.end.fill", action: #selector(restartTapped),
                                        help: "Restart session")
        let pauseButton = roundButton("pause.fill", action: #selector(pauseTapped), help: "Pause",
                                      restingBG: NSColor(calibratedWhite: 1.0, alpha: 0.14))
        self.pauseButton = pauseButton
        let stopButton = roundButton("stop.fill", action: #selector(stopTapped), help: "Stop",
                                     tint: NSColor.systemRed.withAlphaComponent(0.92),
                                     restingBG: NSColor.systemRed.withAlphaComponent(0.16),
                                     hoverBG: NSColor.systemRed.withAlphaComponent(0.30))
        // Right cluster: view / mode.
        let sourceToggleButton = roundButton("character.bubble", action: #selector(sourceToggled),
                                             help: "Show original")
        self.sourceToggleButton = sourceToggleButton
        let audioSourceButton = roundButton("speaker.wave.2", action: #selector(cycleSourceTapped),
                                            help: "Audio source")
        self.audioSourceButton = audioSourceButton
        let summarizeButton = makeSummarizeButton()
        let summarizeWidth = summarizeButton.intrinsicContentSize.width + 20

        // Two inset containers replace the divider lines: a header card (status +
        // language + time·cost) up top, and the circular toolbar card below.
        let topContainer = insetContainer(draggable: true)   // header = drag handle
        let bottomContainer = insetContainer()

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 15)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerKnobStyle = .light
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(topContainer)
        content.addSubview(scrollView)
        content.addSubview(bottomContainer)
        [statusLabel, costLabel, collapseButton].forEach { topContainer.addSubview($0) }
        [restartButton, pauseButton, stopButton, sourceToggleButton, audioSourceButton, summarizeButton]
            .forEach { bottomContainer.addSubview($0) }

        let bs: CGFloat = 28        // circular button diameter
        let gap: CGFloat = 6        // within-cluster spacing
        // Keep the cluster-gap below required so it never fights the fixed widths.
        let clusterGap = sourceToggleButton.leadingAnchor.constraint(
            greaterThanOrEqualTo: stopButton.trailingAnchor, constant: 12)
        clusterGap.priority = .defaultHigh

        // Player area: fixed width, full height. Which content edge it pins to is
        // toggled by `applySummarySide`; the summary opens off the opposite edge.
        playerLeadingPin = playerGuide.leadingAnchor.constraint(equalTo: content.leadingAnchor)
        playerTrailingPin = playerGuide.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        summaryRightPins = [
            summaryColumn.leadingAnchor.constraint(equalTo: trail),
            summarySep.centerXAnchor.constraint(equalTo: trail),
        ]
        summaryLeftPins = [
            summaryColumn.trailingAnchor.constraint(equalTo: lead),
            summarySep.centerXAnchor.constraint(equalTo: lead),
        ]

        NSLayoutConstraint.activate([
            playerGuide.topAnchor.constraint(equalTo: content.topAnchor),
            playerGuide.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            playerGuide.widthAnchor.constraint(equalToConstant: Self.baseContentWidth),

            summaryColumn.topAnchor.constraint(equalTo: content.topAnchor),
            summaryColumn.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            summaryColumn.widthAnchor.constraint(equalToConstant: Self.summaryColumnWidth),

            summarySep.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            summarySep.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            summarySep.widthAnchor.constraint(equalToConstant: 1),

            // Header container: status + cost + minimize.
            topContainer.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            topContainer.leadingAnchor.constraint(equalTo: lead, constant: 12),
            topContainer.trailingAnchor.constraint(equalTo: trail, constant: -12),
            topContainer.heightAnchor.constraint(equalToConstant: 40),

            statusLabel.leadingAnchor.constraint(equalTo: topContainer.leadingAnchor, constant: 14),
            statusLabel.centerYAnchor.constraint(equalTo: topContainer.centerYAnchor),

            collapseButton.trailingAnchor.constraint(equalTo: topContainer.trailingAnchor, constant: -8),
            collapseButton.centerYAnchor.constraint(equalTo: topContainer.centerYAnchor),
            collapseButton.widthAnchor.constraint(equalToConstant: 24),
            collapseButton.heightAnchor.constraint(equalToConstant: 24),

            costLabel.trailingAnchor.constraint(equalTo: collapseButton.leadingAnchor, constant: -8),
            costLabel.centerYAnchor.constraint(equalTo: topContainer.centerYAnchor),
            costLabel.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 8),

            // Transcript (borderless) between the two containers.
            scrollView.topAnchor.constraint(equalTo: topContainer.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: lead, constant: 14),
            scrollView.trailingAnchor.constraint(equalTo: trail, constant: -14),
            scrollView.bottomAnchor.constraint(equalTo: bottomContainer.topAnchor, constant: -8),

            // Toolbar container.
            bottomContainer.leadingAnchor.constraint(equalTo: lead, constant: 12),
            bottomContainer.trailingAnchor.constraint(equalTo: trail, constant: -12),
            bottomContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            bottomContainer.heightAnchor.constraint(equalToConstant: 48),

            // Left cluster: restart · pause · stop.
            restartButton.leadingAnchor.constraint(equalTo: bottomContainer.leadingAnchor, constant: 10),
            restartButton.centerYAnchor.constraint(equalTo: bottomContainer.centerYAnchor),
            restartButton.widthAnchor.constraint(equalToConstant: bs),
            restartButton.heightAnchor.constraint(equalToConstant: bs),

            pauseButton.leadingAnchor.constraint(equalTo: restartButton.trailingAnchor, constant: gap),
            pauseButton.centerYAnchor.constraint(equalTo: bottomContainer.centerYAnchor),
            pauseButton.widthAnchor.constraint(equalToConstant: bs),
            pauseButton.heightAnchor.constraint(equalToConstant: bs),

            stopButton.leadingAnchor.constraint(equalTo: pauseButton.trailingAnchor, constant: gap),
            stopButton.centerYAnchor.constraint(equalTo: bottomContainer.centerYAnchor),
            stopButton.widthAnchor.constraint(equalToConstant: bs),
            stopButton.heightAnchor.constraint(equalToConstant: bs),

            // Right cluster: original · source · summarize (summarize at the edge).
            summarizeButton.trailingAnchor.constraint(equalTo: bottomContainer.trailingAnchor, constant: -10),
            summarizeButton.centerYAnchor.constraint(equalTo: bottomContainer.centerYAnchor),
            summarizeButton.widthAnchor.constraint(equalToConstant: summarizeWidth),
            summarizeButton.heightAnchor.constraint(equalToConstant: bs),

            audioSourceButton.trailingAnchor.constraint(equalTo: summarizeButton.leadingAnchor, constant: -gap),
            audioSourceButton.centerYAnchor.constraint(equalTo: bottomContainer.centerYAnchor),
            audioSourceButton.widthAnchor.constraint(equalToConstant: bs),
            audioSourceButton.heightAnchor.constraint(equalToConstant: bs),

            sourceToggleButton.trailingAnchor.constraint(equalTo: audioSourceButton.leadingAnchor, constant: -gap),
            sourceToggleButton.centerYAnchor.constraint(equalTo: bottomContainer.centerYAnchor),
            sourceToggleButton.widthAnchor.constraint(equalToConstant: bs),
            sourceToggleButton.heightAnchor.constraint(equalToConstant: bs),

            clusterGap,
        ])

        applySummarySide(onRight: true)   // default; re-decided each time the summary opens
    }

    /// Pins the player to one content edge and parks the summary off the other,
    /// so the summary opens on `onRight ? right : left`.
    private func applySummarySide(onRight: Bool) {
        summaryOnRight = onRight
        NSLayoutConstraint.deactivate(onRight ? summaryLeftPins : summaryRightPins)
        playerLeadingPin.isActive = onRight
        playerTrailingPin.isActive = !onRight
        NSLayoutConstraint.activate(onRight ? summaryRightPins : summaryLeftPins)
    }

    private func buildIndicator() {
        let content = installGlass(in: indicatorPanel, cornerRadius: 20)
        // We handle dragging ourselves (drag to move, click to expand), so don't
        // let the window also move on background drags.
        indicatorPanel.isMovableByWindowBackground = false

        let indicator = RecordIndicatorView(frame: content.bounds)
        indicator.autoresizingMask = [.width, .height]
        indicator.onClick = { [weak self] in self?.onToggleCollapse?() }
        indicator.onToggleRecord = { [weak self] in self?.onTogglePause?() }
        content.addSubview(indicator)
        recordIndicator = indicator
    }

    /// Single source toggle: shows only the active source's icon; tapping it
    /// switches to the other (handled by `cycleSourceTapped`).
    func setSource(_ source: LiveAudioSource) {
        currentSource = source
        let isSystem = source == .systemAudio
        audioSourceButton?.image = Self.symbolImage(isSystem ? "speaker.wave.2" : "mic",
                                                    source.title, pointSize: 13)
        audioSourceButton?.toolTip = isSystem ? "System audio - tap to use the microphone"
                                              : "Microphone - tap to use system audio"
    }

    func showCaptions() {
        indicatorPanel.orderOut(nil)
        placeAtAnchor(panel)            // bottom-center on the shared anchor, clamped to screen
        panel.orderFrontRegardless()
    }

    func showIndicator() {
        panel.orderOut(nil)
        placeAtAnchor(indicatorPanel)   // pill bottom-center on the same anchor, clamped
        indicatorPanel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
        indicatorPanel.orderOut(nil)
    }

    func update(status: String) { statusLabel.stringValue = status }

    func update(cost: String) {
        costLabel.stringValue = cost
        // The collapsed pill shows just the elapsed time (drop the cost tail).
        recordIndicator?.setTime(cost.components(separatedBy: " · ").first?
            .trimmingCharacters(in: .whitespaces) ?? cost)
    }

    func setPaused(_ paused: Bool) {
        pauseButton?.image = Self.symbolImage(paused ? "play.fill" : "pause.fill",
                                              paused ? "Resume" : "Pause", pointSize: 13)
        pauseButton?.toolTip = paused ? "Resume" : "Pause"
        recordIndicator?.setPaused(paused)
    }

    /// Renders order-paired rows — each translation with its source shown muted
    /// above (when enabled) — and the still-untranslated source as a trailing
    /// live row, so the original is paced and never races ahead.
    func render(_ dialogue: LiveDialogue, showSource: Bool) {
        let body = NSMutableAttributedString()
        for row in dialogue.rows {
            // Decoupled rows carry only one side. Source is the dim gray line, the
            // translation the bright primary one.
            if showSource, !row.source.isEmpty {
                body.append(NSAttributedString(string: row.source + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: Self.sourceColor
                ]))
            }
            if !row.translation.isEmpty {
                body.append(NSAttributedString(string: row.translation + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 15),
                    .foregroundColor: Self.bodyColor
                ]))
            }
            // Paragraph gap after each row.
            body.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
        }
        textView.textStorage?.setAttributedString(body)
        // Force layout of the freshly-appended text before scrolling, otherwise
        // scrollToEndOfDocument uses stale geometry and lags behind the partial line.
        if let container = textView.textContainer, let layoutManager = textView.layoutManager {
            layoutManager.ensureLayout(for: container)
        }
        textView.scrollToEndOfDocument(nil)
    }

    func setShowSource(_ on: Bool) {
        applySelection(sourceToggleButton, selected: on)
        sourceToggleButton?.toolTip = on ? "Hide original" : "Show original"
    }

    /// Builds the fixed-width summary column (header card + scrollable text). Its
    /// size/side constraints live in `buildCaptions`; here we just fill it. The
    /// column is parked off-window when collapsed and revealed by the window
    /// growing — no width animation, so no reflow.
    private func buildSummaryColumn(in content: NSView) {
        summaryColumn.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(summaryColumn)

        summarySep.translatesAutoresizingMaskIntoConstraints = false
        summarySep.alphaValue = 0   // only shown while the summary is open
        content.addSubview(summarySep)

        let title = summaryTitleLabel
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = Self.titleColor
        title.translatesAutoresizingMaskIntoConstraints = false

        // Shimmer overlays the title position while the model works.
        summaryShimmer.translatesAutoresizingMaskIntoConstraints = false
        summaryShimmer.isHidden = true

        let headerContainer = insetContainer(draggable: true)   // summary header = drag handle

        let copyButton = iconButton("doc.on.doc", tint: Self.iconColor, hover: Self.hoverNeutral,
                                    action: #selector(copySummaryTapped), help: "Copy summary")
        summaryCopyButton = copyButton
        let closeButton = iconButton("xmark", tint: Self.iconColor, hover: Self.hoverNeutral,
                                     action: #selector(closeSummaryTapped), help: "Close summary")

        summaryTextView.isEditable = false
        summaryTextView.isSelectable = true
        summaryTextView.drawsBackground = false
        summaryTextView.font = .systemFont(ofSize: 14)
        summaryTextView.textColor = Self.bodyColor
        summaryTextView.textContainerInset = NSSize(width: 6, height: 8)
        summaryTextView.isVerticallyResizable = true
        summaryTextView.isHorizontallyResizable = false
        summaryTextView.autoresizingMask = [.width]
        summaryTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        summaryTextView.textContainer?.widthTracksTextView = true

        let scroll = OverlayScrollView()
        scroll.documentView = summaryTextView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.scrollerKnobStyle = .light
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // Bottom follow-up input — wrapped in the same inset card as the player
        // toolbar (matching height/bg), with a trailing send button. Submits on
        // Return or the button.
        let inputContainer = insetContainer()

        followUpField.translatesAutoresizingMaskIntoConstraints = false
        followUpField.placeholderAttributedString = NSAttributedString(
            string: "Ask a follow-up…",
            attributes: [.font: NSFont.systemFont(ofSize: 13),
                         .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.42)])
        followUpField.font = .systemFont(ofSize: 13)
        followUpField.textColor = Self.bodyColor
        followUpField.isBezeled = false
        followUpField.isBordered = false
        followUpField.drawsBackground = false
        followUpField.focusRingType = .none
        followUpField.cell?.usesSingleLineMode = true
        followUpField.cell?.wraps = false
        followUpField.cell?.isScrollable = true
        followUpField.delegate = self
        followUpField.onEscape = { [weak self] in self?.setSummaryShown(false, animated: true) }

        let sendButton = roundButton("arrow.up", action: #selector(sendFollowUpTapped), help: "Send")

        summaryColumn.addSubview(headerContainer)
        summaryColumn.addSubview(scroll)
        summaryColumn.addSubview(inputContainer)
        inputContainer.addSubview(followUpField)
        inputContainer.addSubview(sendButton)
        [title, summaryShimmer, copyButton, closeButton].forEach { headerContainer.addSubview($0) }

        NSLayoutConstraint.activate([
            // Header card — matches the main panel's top container.
            headerContainer.topAnchor.constraint(equalTo: summaryColumn.topAnchor, constant: 12),
            headerContainer.leadingAnchor.constraint(equalTo: summaryColumn.leadingAnchor, constant: 12),
            headerContainer.trailingAnchor.constraint(equalTo: summaryColumn.trailingAnchor, constant: -12),
            headerContainer.heightAnchor.constraint(equalToConstant: 40),

            title.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 14),
            title.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),

            // Shimmer occupies the title slot (between leading edge and copy button).
            summaryShimmer.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 14),
            summaryShimmer.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            summaryShimmer.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -8),
            summaryShimmer.heightAnchor.constraint(equalToConstant: 18),

            closeButton.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
            copyButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            copyButton.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 24),
            copyButton.heightAnchor.constraint(equalToConstant: 24),

            scroll.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: summaryColumn.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: summaryColumn.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: inputContainer.topAnchor, constant: -8),

            // Input card — same inset style/height as the player toolbar.
            inputContainer.leadingAnchor.constraint(equalTo: summaryColumn.leadingAnchor, constant: 12),
            inputContainer.trailingAnchor.constraint(equalTo: summaryColumn.trailingAnchor, constant: -12),
            inputContainer.bottomAnchor.constraint(equalTo: summaryColumn.bottomAnchor, constant: -12),
            inputContainer.heightAnchor.constraint(equalToConstant: 48),

            followUpField.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor, constant: 14),
            followUpField.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            followUpField.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),

            sendButton.trailingAnchor.constraint(equalTo: inputContainer.trailingAnchor, constant: -10),
            sendButton.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 28),
            sendButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    /// Opens the summary panel and runs the shimmer while the model works, so
    /// tapping Summarize gives immediate "something's happening" feedback.
    func showSummaryLoading() {
        startShimmer("Summarizing…")
        setSummaryShown(true, animated: true)
    }

    /// Swaps the header title for the sweeping shimmer with the given label;
    /// the body is left untouched until the result replaces it.
    private func startShimmer(_ text: String) {
        summaryTitleLabel.isHidden = true
        summaryShimmer.configure(
            text: text,
            font: .systemFont(ofSize: 12, weight: .semibold),
            base: NSColor(calibratedWhite: 1.0, alpha: 0.30),
            highlight: NSColor(calibratedWhite: 1.0, alpha: 0.95))
        summaryShimmer.isHidden = false
        summaryShimmer.startAnimating()
    }

    private func stopSummaryLoading() {
        summaryShimmer.stopAnimating()
        summaryShimmer.isHidden = true
        summaryTitleLabel.isHidden = false
    }

    func showSummary(_ text: String) {
        stopSummaryLoading()
        summaryText = text
        summaryTextView.textStorage?.setAttributedString(Self.attributedSummary(text))
        setSummaryShown(true, animated: true)
    }

    /// Replace-mode follow-up: the answer alone takes over the summary body.
    /// Re-clicking Summarize restores the (still-cached) summary.
    func showFollowUpAnswer(_ answer: String) {
        stopSummaryLoading()
        summaryText = answer
        summaryTextView.textStorage?.setAttributedString(Self.attributedSummary(answer))
        summaryTextView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    /// Shimmer shown the instant a question is submitted, until the answer lands.
    func showFollowUpPending() {
        startShimmer("Thinking…")
    }

    private func submitFollowUp() {
        let text = followUpField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        followUpField.stringValue = ""
        onFollowUp?(text)
    }

    /// Renders the model's lightweight markdown (**bold**, *italic*, `- ` bullets,
    /// blank-line paragraphs) without a full markdown engine: inline parsing that
    /// preserves whitespace, then maps the strong/emphasis intents to fonts.
    private static func attributedSummary(_ markdown: String) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: 14)
        let strong = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = NSAttributedString(string: trimmed, attributes: [.font: base, .foregroundColor: bodyColor])

        guard let parsed = try? AttributedString(
            markdown: trimmed,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return plain }

        let result = NSMutableAttributedString(parsed)
        let full = NSRange(location: 0, length: result.length)
        result.addAttributes([.font: base, .foregroundColor: bodyColor], range: full)
        result.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            guard let raw = (value as? NSNumber)?.uintValue else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            if intent.contains(.stronglyEmphasized) {
                result.addAttribute(.font, value: strong, range: range)
            } else if intent.contains(.emphasized) {
                result.addAttribute(.font, value: NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask), range: range)
            }
        }
        return result
    }

    /// Opens/closes the summary by GROWING THE WINDOW only — the player's layout
    /// is fixed-width and pinned to the edge that stays put, so it never moves.
    /// The summary column is already laid out just off-window; the window growth
    /// reveals it. Single animation driver (the window frame) → no wobble.
    private func setSummaryShown(_ shown: Bool, animated: Bool) {
        guard shown != isSummaryShown else { return }
        isSummaryShown = shown
        let delta = Self.summaryColumnWidth
        // The relayout below otherwise snaps the transcript back to the top —
        // preserve where the user was reading (usually pinned to the bottom).
        let transcriptScroll = scrollView.contentView.bounds.origin

        let target: NSRect
        if shown {
            let f = panel.frame
            preSummaryFrame = f
            // Open toward whichever side has more screen room. The player pins to
            // the OPPOSITE (stationary) edge, so it stays put either way.
            let screen = anchorScreen()
            let onRight = (screen.maxX - f.maxX) >= (f.minX - screen.minX)
            applySummarySide(onRight: onRight)
            summarySep.alphaValue = 1
            panel.contentView?.layoutSubtreeIfNeeded()   // park the summary for the chosen side
            target = onRight
                ? NSRect(x: f.minX, y: f.minY, width: f.width + delta, height: f.height)          // grow right
                : NSRect(x: f.minX - delta, y: f.minY, width: f.width + delta, height: f.height)  // grow left
        } else {
            // Retract to the exact pre-open frame; the player doesn't move.
            let f = panel.frame
            target = preSummaryFrame
                ?? NSRect(x: summaryOnRight ? f.minX : f.minX + delta, y: f.minY,
                          width: f.width - delta, height: f.height)
            preSummaryFrame = nil
            summarySep.alphaValue = 0
        }
        restoreTranscriptScroll(transcriptScroll)

        guard animated else {
            panel.setFrame(target, display: false)
            restoreTranscriptScroll(transcriptScroll)
            panel.invalidateShadow()
            return
        }
        // A borderless, transparent window keeps a stale shadow when its frame
        // changes — drop it for the resize, restore + invalidate once settled.
        isProgrammaticResize = true
        panel.hasShadow = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.restoreTranscriptScroll(transcriptScroll)
                self.panel.hasShadow = true
                self.panel.invalidateShadow()
                self.isProgrammaticResize = false
            }
        })
    }

    private func restoreTranscriptScroll(_ origin: NSPoint) {
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Collapse any open summary (no animation) so a restarted session begins
    /// clean rather than showing the previous conversation's summary.
    func resetSummaryForNewSession() {
        stopSummaryLoading()
        summaryText = ""
        summaryTextView.string = ""
        followUpField.stringValue = ""
        setSummaryShown(false, animated: false)
    }

    func copySummary() {
        guard !summaryText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summaryText, forType: .string)
        flashCopied()
    }

    /// Brief "copied" confirmation: the copy glyph becomes a checkmark in the
    /// same gray as the neighbouring close icon (so the two read as a pair),
    /// then reverts. Re-tapping restarts the timer rather than stacking reverts.
    private func flashCopied() {
        guard let button = summaryCopyButton else { return }
        button.image = Self.symbolImage("checkmark", "Copied")
        button.contentTintColor = Self.iconColor
        copiedRevert?.invalidate()
        copiedRevert = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let button = self.summaryCopyButton else { return }
                button.image = Self.symbolImage("doc.on.doc", "Copy summary")
                button.contentTintColor = button.baseTint
            }
        }
    }

    @objc private func stopTapped() { onStop?() }
    @objc private func collapseTapped() { onToggleCollapse?() }
    @objc private func pauseTapped() { onTogglePause?() }
    @objc private func sourceToggled() { onToggleSource?() }
    @objc private func summarizeTapped() { onSummarize?() }
    @objc private func sendFollowUpTapped() { submitFollowUp() }
    @objc private func copySummaryTapped() { copySummary() }
    @objc private func closeSummaryTapped() { setSummaryShown(false, animated: true) }
    @objc private func restartTapped() { onRestart?() }
    @objc private func cycleSourceTapped() {
        onSourceChange?(currentSource == .systemAudio ? .microphone : .systemAudio)
    }
}

extension LiveCaptionPanelController: NSTextFieldDelegate {
    // Submit on Return only — swallow the keystroke so the field doesn't beep.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === followUpField,
              commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        submitFollowUp()
        return true
    }
}
