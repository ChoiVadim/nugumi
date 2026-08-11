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

final class TranslationContentView: NSView, NSTextFieldDelegate {
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

    // Footer "Revise or ask a follow-up" row (selection panel only).
    private static let followUpTopGap: CGFloat = 12
    // Equal to panelPaddingBottom so the field's center sits equidistant from the
    // divider above and the panel's bottom edge below.
    private static let followUpDividerToFieldGap: CGFloat = panelPaddingBottom
    private static let followUpFieldHeight: CGFloat = 20
    private static let followUpIconSize: CGFloat = 16
    static var followUpFooterHeight: CGFloat {
        followUpTopGap + dividerHeight + followUpDividerToFieldGap + followUpFieldHeight
    }
    private static let buttonSize: CGFloat = 18
    private static let resultFontSize: CGFloat = 18
    private static let resultParagraphSpacingFactor: CGFloat = 0.35
    // Gap between block paragraphs. Markdown collapses the blank line the model
    // emits between paragraphs, so spacing has to stand in for it — sized near a
    // full line so it reads like the literal blank line the plain-text render
    // shows. Paragraphs only; lists/headers keep the tighter base factor.
    private static let resultParagraphGapFactor: CGFloat = 1.1
    private static let textInsetY: CGFloat = 3
    private static let scrollableTextBottomPadding: CGFloat = 18

    var onClose: (() -> Void)?
    var onNeedsResize: (() -> Void)?
    /// Fires after an actual (throttled) result render so the panel resizes only
    /// when content really changed — not on every streamed chunk.
    var onResultRendered: (() -> Void)?
    /// Fires when the user submits the footer "Revise or ask a follow-up" field.
    var onFollowUp: ((String) -> Void)?
    /// Fires when the follow-up field gains (`true`) or loses (`false`) focus, so
    /// the controller can suspend the Return-key interceptor while the user is
    /// typing a follow-up (the rewrite flow otherwise steals Return to paste).
    var onFollowUpFocusChange: ((Bool) -> Void)?

    private let sourceText: String
    private var targetLanguage: TranslationLanguage
    private let showsSource: Bool
    private let showsFollowUp: Bool
    private let followUpDivider = HairlineSeparatorView()
    private let followUpField = FollowUpTextField()
    private let followUpIcon = NSImageView()
    private let resultLabel: String?
    private var resultText = "Thinking..."
    private var resultDisplayText = "Thinking..."
    /// The last non-loading result shown. Revise composes against this so a
    /// follow-up typed mid-revise builds on the real answer, not "Revising...".
    private var lastRealResultText = ""

    // Streaming throttle: just coalesces the per-chunk resize now that streaming
    // renders plain text (no markdown/NSTextTable re-layout to amortize). Kept
    // small so tokens land near word-by-word; first and final chunks always
    // render (leading + trailing edge).
    static let streamDebug = ProcessInfo.processInfo.environment["GIZMATE_STREAM_DEBUG"] == "1"
    private static let resultThrottleInterval: TimeInterval = 0.03
    private var pendingResultText: String?
    private var pendingResultTone: ResultTone = .normal
    private var resultThrottleScheduled = false
    private var lastResultRenderTime: TimeInterval = 0
    /// Whether the last render used the full block renderer (tables/headers) vs
    /// the inline streaming renderer — so the final block render isn't skipped
    /// just because its text matches the last streamed partial.
    private var lastRenderUsedBlock = false
    private var resultTone: ResultTone = .normal
    /// Streaming replaces the result storage ~33×/s; NSTextView's implicit
    /// insertion-point autoscroll (async, after didChangeText) then walks the
    /// viewport down a few px per chunk. All scrolling here is explicit
    /// (scrollToTop / clip pinning), so implicit autoscroll is never wanted.
    private final class NonAutoscrollingTextView: NSTextView {
        override func scrollRangeToVisible(_ range: NSRange) {}
    }

    /// GIZMATE_STREAM_DEBUG only: logs who moves the result clip's origin.
    private final class StreamDebugClipView: NSClipView {
        override func setBoundsOrigin(_ newOrigin: NSPoint) {
            if abs(newOrigin.y - bounds.origin.y) > 0.5 {
                print("[stream] CLIP setBoundsOrigin \(bounds.origin.y) -> \(newOrigin.y)")
                Thread.callStackSymbols.prefix(10).forEach { print("[stream]   \($0)") }
            }
            super.setBoundsOrigin(newOrigin)
        }
    }

    private let resultTextView = NonAutoscrollingTextView()
    private let sourceTitleLabel = NSTextField(labelWithString: "")
    private let sourcePreviewView = SourcePreviewView(frame: .zero)
    private let targetTitleButton = LanguagePickerButton(frame: .zero)
    private let sourceTextView = NSTextView()
    private let sourceScrollView = NSScrollView()
    private let resultScrollView = NSScrollView()
    private let sourceDivider = HairlineSeparatorView()
    private var panelGlass: GlassHostView?
    /// Drawn without its own glass, corners or fixed width — for a host that
    /// already provides all three. Glass inside glass is the thing this avoids:
    /// a panel pasted into a dock instead of content laid out on one.
    private let chromeless: Bool

    /// The width to lay out against. Fixed when this view *is* the panel; the
    /// host's width when it is only the contents of one.
    private var layoutWidth: CGFloat { chromeless ? bounds.width : Self.bodyWidth }
    private var layoutContentWidth: CGFloat {
        chromeless ? max(bounds.width - Self.panelPaddingX * 2, 1) : Self.contentWidth
    }
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
    private let loadingShimmer = ShimmerTextLabel()

    var isTargetLanguageMenuOpen = false

    init(
        sourceText: String,
        targetLanguage: TranslationLanguage,
        resultLabel: String? = nil,
        anchorY: CGFloat,
        showsSource: Bool = true,
        showsFollowUp: Bool = false,
        chromeless: Bool = false,
        onTargetLanguageSelected: ((TranslationLanguage) -> Void)? = nil,
        onReplace: ((String) -> Void)? = nil
    ) {
        self.chromeless = chromeless
        self.sourceText = sourceText
        self.targetLanguage = targetLanguage
        self.resultLabel = resultLabel
        self.anchorYValue = anchorY
        self.showsSource = showsSource
        self.showsFollowUp = showsFollowUp
        self.onTargetLanguageSelected = onTargetLanguageSelected
        self.onReplace = onReplace
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: Self.preferredWidth,
            height: Self.preferredHeight(sourceText: sourceText, resultText: "Thinking...", showsSource: showsSource, showsFollowUp: showsFollowUp)
        ))
        wantsLayer = true
        buildUI()
    }

    required init?(coder: NSCoder) {
        nil
    }

    static func preferredHeight(sourceText: String, resultText: String, sourceExpanded: Bool = false, showsSource: Bool = true, showsFollowUp: Bool = false) -> CGFloat {
        preferredHeight(
            sourceText: sourceText,
            resultBoxHeight: renderedResultHeight(markdown: resultText, width: contentWidth),
            sourceExpanded: sourceExpanded,
            showsSource: showsSource,
            showsFollowUp: showsFollowUp
        )
    }

    static func preferredHeight(sourceText: String, resultBoxHeight: CGFloat, sourceExpanded: Bool, showsSource: Bool, showsFollowUp: Bool) -> CGFloat {
        let sourceBoxHeight = sourceHeight(for: sourceText, expanded: sourceExpanded)

        // Source section (label + box + divider + gaps) is omitted entirely when
        // showsSource is false — the result becomes the top section.
        let sourceSectionHeight = showsSource
            ? (labelHeight + labelToBoxGap + sourceBoxHeight + sourceToDividerGap + dividerHeight + dividerToTargetGap)
            : 0
        let fixedHeight = panelPaddingTop
            + sourceSectionHeight
            + labelHeight + labelToBoxGap
            + panelPaddingBottom
            + (showsFollowUp ? followUpFooterHeight : 0)
        return min(max(fixedHeight + resultBoxHeight, minHeight), maxHeight)
    }

    func preferredHeightForCurrentContent() -> CGFloat {
        // Measure what's actually shown (inline while streaming, block on final),
        // not a re-rendered block version — otherwise the panel height disagrees
        // with the displayed text mid-stream and the result twitches.
        let resultBox: CGFloat
        if !isShowingLoadingState, let storage = resultTextView.textStorage, storage.length > 0 {
            resultBox = Self.resultBoxHeight(rawTextHeight: Self.attributedTextHeight(storage, width: Self.contentWidth))
        } else {
            // While loading, size for the placeholder (e.g. "Revising"), not the
            // prior answer still held in resultText — otherwise revise blows the
            // panel up to the old result's height with the shimmer floating in it.
            resultBox = Self.renderedResultHeight(markdown: loadingBaseText ?? resultText, width: Self.contentWidth)
        }
        return Self.preferredHeight(
            sourceText: sourceText,
            resultBoxHeight: resultBox,
            sourceExpanded: sourceExpanded,
            showsSource: showsSource,
            showsFollowUp: showsFollowUp
        )
    }

    var currentResultText: String { lastRealResultText }
    var currentSourceText: String { sourceText }
    var currentTargetLanguageValue: TranslationLanguage { targetLanguage }

    static func anchorY(for screenY: CGFloat, panelOriginY: CGFloat, panelHeight: CGFloat) -> CGFloat {
        min(max(screenY - panelOriginY, 0), panelHeight)
    }

    func setAnchorY(_ anchorY: CGFloat) {
        guard abs(anchorYValue - anchorY) >= 0.5 else {
            return
        }
        // No layout here: the only caller (resizeToFitContent) always runs
        // layoutForCurrentSize right after — via setFrame → setFrameSize or
        // explicitly. Laying out now would use the OLD panel height with the
        // new text: a transient overflow that blinks the scroller and lets
        // NSTextView scroll/resize itself before the real layout lands.
        anchorYValue = anchorY
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
        showsOverflowScroller: Bool = true,
        topAligned: Bool = false
    ) {
        scrollView.frame = scrollFrame

        let minimumVerticalTextPadding: CGFloat = 4
        let fitsInScrollFrame = rawTextHeight + minimumVerticalTextPadding * 2 <= scrollFrame.height
        let verticalInset: CGFloat
        let textViewHeight: CGFloat
        if fitsInScrollFrame {
            // Streaming pins to the top: centering re-derives the inset from the
            // text height, so every appended chunk shifts the whole block up and
            // the panel-growth pass shifts it back — visible trembling at ~33Hz.
            verticalInset = topAligned
                ? minimumVerticalTextPadding
                : floor(max(2, (scrollFrame.height - rawTextHeight) / 2))
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

    /// Markdown resolved to plain text (list markers survive as glyphs,
    /// emphasis/table syntax is consumed) — for surfaces that can't render
    /// rich text.
    static func flattenedMarkdown(_ text: String) -> String {
        renderedMarkdownText(
            text,
            font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            color: .white
        ).string
    }

    /// Block-level markdown: paragraphs, ATX headers, bullet/numbered lists, and
    /// GitHub-style tables. Answers (follow-ups) emit real markdown now, not just
    /// plain translations, so block constructs must render instead of leaking as
    /// raw `|` pipes and `#`. Inline styling (bold/italic/code/links) is applied
    /// per block via `inlineAttributed`.
    static func renderedMarkdownText(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let lines = text.components(separatedBy: "\n")
        let out = NSMutableAttributedString()
        var i = 0
        var lastWasTable = false

        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Table: a row with pipes immediately followed by a `|---|---|` rule.
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparatorRow(lines[i + 1]) {
                var rows = [raw]
                i += 2 // header row + separator
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, t.contains("|") else { break }
                    rows.append(lines[i])
                    i += 1
                }
                out.append(renderTable(rows: rows, font: font, color: color))
                lastWasTable = true
                continue
            }

            // ATX header (# .. ######)
            if let (level, content) = parseHeader(trimmed) {
                out.append(renderHeader(content, level: level, baseFont: font, color: color))
                lastWasTable = false
                i += 1
                continue
            }

            // List item (-, *, +, or "1.")
            if let item = parseListItem(raw) {
                out.append(renderListItem(marker: item.marker, content: item.content, font: font, color: color))
                lastWasTable = false
                i += 1
                continue
            }

            // Paragraph: consecutive non-blank, non-block lines. Joined with "\n"
            // so the model's intended soft breaks survive (matches prior behavior).
            var paragraphLines = [raw]
            i += 1
            while i < lines.count {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if parseHeader(t) != nil { break }
                if parseListItem(l) != nil { break }
                if t.contains("|"), i + 1 < lines.count, isTableSeparatorRow(lines[i + 1]) { break }
                paragraphLines.append(l)
                i += 1
            }
            out.append(renderParagraph(paragraphLines.joined(separator: "\n"), font: font, color: color))
            lastWasTable = false
        }

        // Drop the final newline so the box isn't padded with a blank line — but
        // not after a table, where it terminates the last cell's paragraph.
        if !lastWasTable, out.string.hasSuffix("\n") {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return out
    }

    /// Streaming render: plain text, no markdown at all. Even inline syntax
    /// (bold/italic/code) reflows the line as it completes mid-stream — a
    /// half-streamed `**bol` shows its asterisks, then snaps to bold and shifts.
    /// So *all* markdown is deferred to the final block render
    /// (`renderedMarkdownText`): raw syntax shows briefly while text streams in,
    /// then resolves once. One transform instead of a twitch per token.
    static func renderedStreamingText(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        guard !text.isEmpty else { return NSAttributedString() }
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.paragraphSpacing = font.pointSize * resultParagraphSpacingFactor
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: p
        ])
    }

    /// Inline-only markdown (bold/italic/code/links) for a single block of text.
    /// No paragraph style, no trailing newline — block renderers add those.
    private static func inlineAttributed(_ text: String, font: NSFont, color: NSColor) -> NSMutableAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let rendered = (try? AttributedString(markdown: text, options: options))
            .map { NSMutableAttributedString($0) }
            ?? NSMutableAttributedString(string: text)

        guard rendered.length > 0 else {
            return rendered
        }

        let fullRange = NSRange(location: 0, length: rendered.length)
        rendered.addAttributes([.font: font, .foregroundColor: color], range: fullRange)

        var fontRuns: [(NSRange, NSFont)] = []
        rendered.enumerateAttribute(.inlinePresentationIntent, in: fullRange) { value, range, _ in
            guard let intent = (value as? NSNumber)?.intValue else { return }
            if let styledFont = markdownFont(for: intent, baseFont: font) {
                fontRuns.append((range, styledFont))
            }
        }
        for (range, styledFont) in fontRuns {
            rendered.addAttribute(.font, value: styledFont, range: range)
        }

        rendered.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            rendered.addAttributes([
                .foregroundColor: TranslationPanelPalette.resultLink,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: range)
        }
        return rendered
    }

    private static func blockParagraphStyle(font: NSFont, headIndent: CGFloat = 0, spacingBefore: CGFloat = 0, spacingFactor: CGFloat = resultParagraphSpacingFactor) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.paragraphSpacing = font.pointSize * spacingFactor
        p.paragraphSpacingBefore = spacingBefore
        if headIndent > 0 {
            p.headIndent = headIndent
            p.tabStops = [NSTextTab(textAlignment: .left, location: headIndent)]
        }
        return p
    }

    private static func renderParagraph(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let s = inlineAttributed(text, font: font, color: color)
        s.addAttribute(.paragraphStyle, value: blockParagraphStyle(font: font, spacingFactor: resultParagraphGapFactor), range: NSRange(location: 0, length: s.length))
        s.append(NSAttributedString(string: "\n"))
        return s
    }

    private static func renderHeader(_ text: String, level: Int, baseFont: NSFont, color: NSColor) -> NSAttributedString {
        let scale: CGFloat = level <= 1 ? 1.3 : (level == 2 ? 1.15 : 1.05)
        let headerFont = NSFont.systemFont(ofSize: baseFont.pointSize * scale, weight: .bold)
        let s = inlineAttributed(text, font: headerFont, color: color)
        s.addAttribute(
            .paragraphStyle,
            value: blockParagraphStyle(font: headerFont, spacingBefore: baseFont.pointSize * 0.4),
            range: NSRange(location: 0, length: s.length)
        )
        s.append(NSAttributedString(string: "\n"))
        return s
    }

    private static func renderListItem(marker: String, content: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let indent = font.pointSize * 1.5
        let s = NSMutableAttributedString(string: "\(marker)\t", attributes: [.font: font, .foregroundColor: color])
        s.append(inlineAttributed(content, font: font, color: color))
        s.addAttribute(.paragraphStyle, value: blockParagraphStyle(font: font, headIndent: indent), range: NSRange(location: 0, length: s.length))
        s.append(NSAttributedString(string: "\n"))
        return s
    }

    private static func isTableSeparatorRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        let cells = t.split(separator: "|", omittingEmptySubsequences: true)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            return !c.isEmpty && c.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func parseHeader(_ trimmed: String) -> (level: Int, content: String)? {
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex, trimmed[idx] == "#", level < 6 {
            level += 1
            idx = trimmed.index(after: idx)
        }
        guard idx < trimmed.endIndex, trimmed[idx] == " " else { return nil }
        return (level, String(trimmed[idx...]).trimmingCharacters(in: .whitespaces))
    }

    private static func parseListItem(_ line: String) -> (marker: String, content: String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["- ", "* ", "+ "] where t.hasPrefix(prefix) {
            return ("•", String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
        }
        if let dot = t.range(of: ". ") {
            let num = t[t.startIndex..<dot.lowerBound]
            if !num.isEmpty, num.allSatisfy(\.isNumber) {
                return ("\(num).", String(t[dot.upperBound...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func renderTable(rows: [String], font: NSFont, color: NSColor) -> NSAttributedString {
        let parsed = rows.map { splitTableRow($0) }
        let columns = parsed.map(\.count).max() ?? 0
        guard columns > 0 else { return NSAttributedString(string: "\n") }

        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.hidesEmptyCells = false

        let borderColor = color.withAlphaComponent(0.22)
        let result = NSMutableAttributedString()
        for (rowIndex, cells) in parsed.enumerated() {
            let isHeader = rowIndex == 0
            let cellFont = isHeader ? NSFont.systemFont(ofSize: font.pointSize, weight: .bold) : font
            for column in 0..<columns {
                let cellText = column < cells.count ? cells[column] : ""
                let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setBorderColor(borderColor)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                if isHeader {
                    block.backgroundColor = color.withAlphaComponent(0.06)
                }

                let cellStyle = NSMutableParagraphStyle()
                cellStyle.textBlocks = [block]
                cellStyle.lineBreakMode = .byWordWrapping

                let cellAttr = inlineAttributed(cellText, font: cellFont, color: color)
                cellAttr.append(NSAttributedString(string: "\n"))
                cellAttr.addAttribute(.paragraphStyle, value: cellStyle, range: NSRange(location: 0, length: cellAttr.length))
                result.append(cellAttr)
            }
        }
        return result
    }

    /// Height of an already-rendered attributed string (incl. NSTextTable blocks)
    /// at a given width. The plain-string `textHeight` undercounts tables.
    private static func attributedTextHeight(_ attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        guard attributed.length > 0 else { return 0 }
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height)
    }

    /// Result box height for markdown source: render then measure so tables and
    /// headers get their true height. Clamped to the result box bounds.
    private static func resultBoxHeight(rawTextHeight: CGFloat) -> CGFloat {
        min(max(rawTextHeight + textInsetY * 2 + 4, minimumResultBoxHeight), maximumResultBoxHeight)
    }

    private static func renderedResultHeight(markdown: String, width: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: resultFontSize, weight: .semibold)
        let attr = renderedMarkdownText(markdown, font: font, color: .white)
        return resultBoxHeight(rawTextHeight: attributedTextHeight(attr, width: width))
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
        let content: NSView
        if chromeless {
            // The dock's own glass is the surface; this just lays out on it.
            let plain = NSView(frame: bounds)
            plain.autoresizingMask = [.width, .height]
            addSubview(plain)
            content = plain
        } else {
            let panelGlass = GlassHostView(
                frame: NSRect(x: 0, y: 0, width: Self.bodyWidth, height: bounds.height),
                cornerRadius: 22,
                tintColor: NSColor(calibratedRed: 0.10, green: 0.095, blue: 0.045, alpha: 0.72),
                style: .regular
            )
            panelGlass.autoresizingMask = [.height]
            addSubview(panelGlass)
            self.panelGlass = panelGlass
            content = panelGlass.contentView
        }

        closeButton = makeIconButton(
            symbolName: "xmark",
            accessibilityDescription: "Close",
            pointSize: 10,
            target: self,
            action: #selector(closeTapped),
            to: content
        )

        if showsSource {
            configureSectionLabel(
                sourceTitleLabel,
                text: "Source",
                color: NSColor(calibratedWhite: 1.0, alpha: 0.74)
            )
            content.addSubview(sourceTitleLabel)

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
        }

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
        if Self.streamDebug {
            resultScrollView.contentView = StreamDebugClipView()
        }
        configureTextView(
            resultTextView,
            text: resultText,
            font: NSFont.systemFont(ofSize: Self.resultFontSize, weight: .semibold),
            color: ResultTone.normal.color
        )
        // The result view's height is fully managed by layoutScrollableTextView.
        // Self-sizing would shrink it back (stripping the bottom padding) after
        // every layout pass — fractional heights and a pulsing scroller knob.
        resultTextView.isVerticallyResizable = false
        resultScrollView.documentView = resultTextView
        content.addSubview(resultScrollView)

        let chromeOverlay = GlassChromeOverlayView(frame: content.bounds)
        chromeOverlay.autoresizingMask = [.width, .height]
        content.addSubview(chromeOverlay)
        self.chromeOverlay = chromeOverlay

        loadingShimmer.isHidden = true
        content.addSubview(loadingShimmer)

        if showsFollowUp {
            buildFollowUpFooter(in: content)
        }

        setResult(resultText)
    }

    private func buildFollowUpFooter(in content: NSView) {
        content.addSubview(followUpDivider)

        let iconConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        followUpIcon.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)
        followUpIcon.contentTintColor = NSColor(calibratedWhite: 1.0, alpha: 0.55)
        followUpIcon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(followUpIcon)

        followUpField.placeholderAttributedString = NSAttributedString(
            string: "Revise or ask a follow-up",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.42)
            ]
        )
        followUpField.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        followUpField.textColor = NSColor(calibratedWhite: 1.0, alpha: 0.92)
        followUpField.isBezeled = false
        followUpField.isBordered = false
        followUpField.drawsBackground = false
        followUpField.focusRingType = .none
        followUpField.cell?.usesSingleLineMode = true
        followUpField.cell?.wraps = false
        followUpField.cell?.isScrollable = true
        followUpField.delegate = self
        followUpField.onEscape = { [weak self] in self?.onClose?() }
        content.addSubview(followUpField)
    }

    private func submitFollowUp() {
        let text = followUpField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        followUpField.stringValue = ""
        onFollowUp?(text)
    }

    // Submit on Return only (not on focus loss), and swallow the keystroke so
    // the field doesn't beep or insert a newline.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === followUpField, commandSelector == #selector(NSResponder.insertNewline(_:)) else {
            return false
        }
        submitFollowUp()
        return true
    }

    // Suspend the Return-key interceptor while the follow-up field is being
    // edited (Return must submit the follow-up, not paste the rewrite). Pressing
    // Return to submit keeps editing, so this only re-enables when focus truly
    // leaves the field (the user clicks/tabs away).
    func controlTextDidBeginEditing(_ obj: Notification) {
        guard (obj.object as AnyObject?) === followUpField else { return }
        onFollowUpFocusChange?(true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as AnyObject?) === followUpField else { return }
        onFollowUpFocusChange?(false)
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
        // Accessing layoutManager opts the view into TextKit 1, whose NSTextTable
        // support is mature and matches our TextKit-1 height measurement.
        _ = textView.layoutManager
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
            width: layoutWidth,
            height: bodyHeight
        )
        chromeOverlay?.frame = NSRect(x: 0, y: 0, width: layoutWidth, height: bodyHeight)

        let resolvedResultBoxHeight: CGFloat
        var y: CGFloat

        if showsSource {
            let sourceBoxHeight = Self.sourceHeight(for: sourceText, expanded: sourceExpanded)
            let fixedHeight = Self.panelPaddingTop
                + Self.labelHeight + Self.labelToBoxGap
                + Self.sourceToDividerGap + Self.dividerHeight + Self.dividerToTargetGap
                + Self.labelHeight + Self.labelToBoxGap
                + Self.panelPaddingBottom
                + (showsFollowUp ? Self.followUpFooterHeight : 0)
            let availableBoxHeight = max(
                Self.collapsedSourceBoxHeight + Self.minimumResultBoxHeight,
                bounds.height - fixedHeight
            )
            let resolvedSourceBoxHeight = min(
                sourceBoxHeight,
                max(Self.collapsedSourceBoxHeight, availableBoxHeight - Self.minimumResultBoxHeight)
            )
            resolvedResultBoxHeight = max(Self.minimumResultBoxHeight, availableBoxHeight - resolvedSourceBoxHeight)

            y = bodyHeight - Self.panelPaddingTop - Self.labelHeight
            sourceTitleLabel.frame = NSRect(
                x: Self.panelPaddingX,
                y: y,
                width: layoutContentWidth - Self.buttonSize - 8,
                height: Self.labelHeight
            )
            closeButton?.frame = NSRect(
                x: layoutWidth - Self.panelPaddingX - Self.buttonSize,
                y: y + (Self.labelHeight - Self.buttonSize) / 2,
                width: Self.buttonSize,
                height: Self.buttonSize
            )

            y -= Self.labelToBoxGap + resolvedSourceBoxHeight
            let sourceScrollFrame = NSRect(
                x: Self.panelPaddingX,
                y: y,
                width: layoutContentWidth,
                height: resolvedSourceBoxHeight
            )
            let collapsedSourceText = Self.collapsedSourceText(sourceText)
            let sourceCanExpand = Self.singleLineWidth(
                for: collapsedSourceText,
                font: NSFont.systemFont(ofSize: Self.sourceFontSize, weight: .semibold)
            ) > layoutContentWidth
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
                width: layoutContentWidth,
                height: Self.dividerHeight
            )

            y -= Self.dividerToTargetGap + Self.labelHeight
            layoutTargetRow(topY: y, includeClose: false)
        } else {
            let fixedHeight = Self.panelPaddingTop
                + Self.labelHeight + Self.labelToBoxGap
                + Self.panelPaddingBottom
                + (showsFollowUp ? Self.followUpFooterHeight : 0)
            resolvedResultBoxHeight = max(Self.minimumResultBoxHeight, bounds.height - fixedHeight)

            y = bodyHeight - Self.panelPaddingTop - Self.labelHeight
            layoutTargetRow(topY: y, includeClose: true)
        }

        y -= Self.labelToBoxGap + resolvedResultBoxHeight
        let resultScrollFrame = NSRect(
            x: Self.panelPaddingX,
            y: y,
            width: Self.contentWidth,
            height: resolvedResultBoxHeight
        )
        // Fit the shimmer to the text width so the highlight sweeps across the
        // word itself, not mostly empty result-box space to its right.
        let shimmerFont = NSFont.systemFont(ofSize: Self.resultFontSize, weight: .semibold)
        let shimmerTextWidth = ceil(((loadingBaseText ?? "") as NSString).size(withAttributes: [.font: shimmerFont]).width) + 4
        loadingShimmer.frame = NSRect(
            x: resultScrollFrame.minX,
            y: resultScrollFrame.minY,
            width: min(max(shimmerTextWidth, 1), resultScrollFrame.width),
            height: resultScrollFrame.height
        )
        // Measure the rendered attributed content (tables/headers included), not
        // the plain string, so tall blocks get the right scroll height.
        let resultRawTextHeight: CGFloat
        if let storage = resultTextView.textStorage, storage.length > 0 {
            resultRawTextHeight = Self.attributedTextHeight(storage, width: resultScrollFrame.width)
        } else {
            resultRawTextHeight = Self.textHeight(
                for: resultDisplayText,
                font: NSFont.systemFont(ofSize: Self.resultFontSize, weight: .semibold),
                width: resultScrollFrame.width,
                paragraphSpacing: Self.resultFontSize * Self.resultParagraphSpacingFactor
            )
        }
        // Re-tiling the scroll view/text view can shift the clip's origin
        // through paths that bypass every public scroll override (observed:
        // a jump to the document bottom the first time the text outgrows the
        // box). User scrolls happen between layout passes, never inside one —
        // so pin the origin across the re-tile, clamped to the new document.
        let clipOriginBeforeTile = resultScrollView.contentView.bounds.origin
        Self.layoutScrollableTextView(
            resultTextView,
            inside: resultScrollView,
            scrollFrame: resultScrollFrame,
            rawTextHeight: resultRawTextHeight,
            topAligned: !lastRenderUsedBlock
        )
        if shouldScrollResultToTop {
            scrollToTop(resultScrollView)
            shouldScrollResultToTop = false
        } else {
            let maxScrollY = max(0, resultTextView.frame.height - resultScrollFrame.height)
            let pinnedY = min(max(0, clipOriginBeforeTile.y), maxScrollY)
            if abs(resultScrollView.contentView.bounds.origin.y - pinnedY) > 0.5 {
                resultScrollView.contentView.scroll(to: NSPoint(x: 0, y: pinnedY))
                resultScrollView.reflectScrolledClipView(resultScrollView.contentView)
            }
        }

        if showsFollowUp {
            layoutFollowUpFooter()
        }

        if Self.streamDebug {
            print(String(
                format: "[stream] layout bounds=%.1f box=%.1f raw=%.1f tvH=%.1f inset=%.1f clipY=%.1f scroller=%d",
                bounds.height, resolvedResultBoxHeight, resultRawTextHeight,
                resultTextView.frame.height, resultTextView.textContainerInset.height,
                resultScrollView.contentView.bounds.origin.y,
                resultScrollView.hasVerticalScroller ? 1 : 0
            ))
        }
    }

    /// Lays out the "<language> … [replace] [copy] [close?]" row with its top at
    /// `y`. `includeClose` puts the ✕ here (used when the source section above it
    /// is hidden, so this row is the panel's header).
    private func layoutTargetRow(topY y: CGFloat, includeClose: Bool) {
        var actionButtonCount = 1 // copy
        if replaceButton != nil { actionButtonCount += 1 }
        if includeClose { actionButtonCount += 1 }
        let targetActionWidth = CGFloat(actionButtonCount) * Self.buttonSize
            + CGFloat(max(0, actionButtonCount - 1)) * 8
        let titleLeadingInset = LanguagePickerButton.titleLeadingInset
        targetTitleButton.frame = NSRect(
            x: Self.panelPaddingX - titleLeadingInset,
            y: y + (Self.labelHeight - Self.buttonSize) / 2,
            width: min(
                targetTitleButton.preferredWidth,
                Self.contentWidth - targetActionWidth - 8 + titleLeadingInset
            ),
            height: Self.buttonSize
        )

        let buttonY = y + (Self.labelHeight - Self.buttonSize) / 2
        var rightX = layoutWidth - Self.panelPaddingX - Self.buttonSize
        if includeClose {
            closeButton?.frame = NSRect(x: rightX, y: buttonY, width: Self.buttonSize, height: Self.buttonSize)
            rightX -= Self.buttonSize + 8
        }
        copyButton?.frame = NSRect(x: rightX, y: buttonY, width: Self.buttonSize, height: Self.buttonSize)
        rightX -= Self.buttonSize + 8
        replaceButton?.frame = NSRect(x: rightX, y: buttonY, width: Self.buttonSize, height: Self.buttonSize)
    }

    private func layoutFollowUpFooter() {
        let fieldY = Self.panelPaddingBottom
        followUpIcon.frame = NSRect(
            x: Self.panelPaddingX,
            y: fieldY + (Self.followUpFieldHeight - Self.followUpIconSize) / 2,
            width: Self.followUpIconSize,
            height: Self.followUpIconSize
        )
        let fieldX = Self.panelPaddingX + Self.followUpIconSize + 8
        followUpField.frame = NSRect(
            x: fieldX,
            y: fieldY,
            width: Self.panelPaddingX + Self.contentWidth - fieldX,
            height: Self.followUpFieldHeight
        )
        followUpDivider.frame = NSRect(
            x: Self.panelPaddingX,
            y: fieldY + Self.followUpFieldHeight + Self.followUpDividerToFieldGap,
            width: Self.contentWidth,
            height: Self.dividerHeight
        )
    }

    func setResult(_ text: String, isFinal: Bool = false) {
        if isFinal {
            // Final chunk: drop any throttled partial, render full block markdown.
            pendingResultText = nil
            renderResultNow(text, tone: .normal, useBlockMarkdown: true)
        } else {
            scheduleResult(text, tone: .normal)
        }
    }

    func setError(_ text: String) {
        // Errors are terminal and rare — render immediately, no throttle.
        pendingResultText = nil
        renderResultNow(text, tone: .error, useBlockMarkdown: true)
    }

    /// Coalesces streamed partials: renders on the leading edge, then at most
    /// once per `resultThrottleInterval`. Streaming uses the inline renderer; the
    /// final chunk re-renders as block markdown via `setResult(isFinal:)`.
    private func scheduleResult(_ text: String, tone: ResultTone) {
        pendingResultText = text
        pendingResultTone = tone
        let now = Date().timeIntervalSinceReferenceDate
        let elapsed = now - lastResultRenderTime
        if elapsed >= Self.resultThrottleInterval {
            flushPendingResult()
        } else if !resultThrottleScheduled {
            resultThrottleScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (Self.resultThrottleInterval - elapsed)) { [weak self] in
                self?.flushPendingResult()
            }
        }
    }

    private func flushPendingResult() {
        resultThrottleScheduled = false
        guard let text = pendingResultText else { return }
        pendingResultText = nil
        lastResultRenderTime = Date().timeIntervalSinceReferenceDate
        renderResultNow(text, tone: pendingResultTone, useBlockMarkdown: false)
    }

    private func renderResultNow(_ text: String, tone: ResultTone, useBlockMarkdown: Bool) {
        // Any real content (partial or final) ends the loading shimmer.
        stopLoadingAnimation()
        let cleanedText = TextNormalizer.cleanedTranslation(text)
        if Self.streamDebug {
            print(String(
                format: "[stream] pre   len=%d prefixOK=%d tvH=%.1f clipY=%.1f",
                cleanedText.count, cleanedText.hasPrefix(resultText) ? 1 : 0,
                resultTextView.frame.height, resultScrollView.contentView.bounds.origin.y
            ))
        }

        if cleanedText == resultText, tone == resultTone, useBlockMarkdown == lastRenderUsedBlock {
            return
        }
        lastRenderUsedBlock = useBlockMarkdown

        if !cleanedText.hasPrefix(resultText) || tone != resultTone {
            shouldScrollResultToTop = true
        }

        resultTone = tone
        resultTextView.textColor = tone.color
        let renderFont = resultTextView.font ?? NSFont.systemFont(ofSize: Self.resultFontSize, weight: .regular)
        let renderedText = useBlockMarkdown
            ? Self.renderedMarkdownText(cleanedText, font: renderFont, color: tone.color)
            : Self.renderedStreamingText(cleanedText, font: renderFont, color: tone.color)
        if let textStorage = resultTextView.textStorage {
            // Replacing the whole storage nudges the clip a few px down each
            // chunk (autoscroll toward the changed range) — the summary's first
            // line creeps off the top mid-stream. Pin the viewport (and any
            // user scroll position) across the replacement.
            let clipOrigin = resultScrollView.contentView.bounds.origin
            textStorage.setAttributedString(renderedText)
            resultScrollView.contentView.scroll(to: clipOrigin)
            resultScrollView.reflectScrolledClipView(resultScrollView.contentView)
        } else {
            resultTextView.string = renderedText.string
        }

        resultText = cleanedText
        resultDisplayText = resultTextView.string
        lastRealResultText = cleanedText
        updateActionButtonStates()
        // No direct layout here: onResultRendered resizes the panel, and both
        // resize outcomes (setFrame → setFrameSize, or frame-unchanged) run
        // layoutForCurrentSize exactly once with the NEW bounds. Laying out
        // first with the stale height flashes a transient overflow state per
        // chunk (scroller blinks in/out, clip scrolls off the top).
        onResultRendered?()
    }

    func startLoadingAnimation(baseText: String) {
        // Drop any throttled render still queued from a previous request.
        pendingResultText = nil
        loadingBaseText = baseText
        loadingShimmer.configure(
            text: baseText,
            font: NSFont.systemFont(ofSize: Self.resultFontSize, weight: .semibold),
            base: NSColor(calibratedWhite: 1.0, alpha: 0.42),
            highlight: NSColor(calibratedWhite: 1.0, alpha: 0.98)
        )
        loadingShimmer.isHidden = false
        loadingShimmer.startAnimating()
        resultScrollView.isHidden = true
        layoutForCurrentSize()
    }

    func stopLoadingAnimation() {
        guard loadingBaseText != nil else { return }
        loadingBaseText = nil
        loadingShimmer.stopAnimating()
        loadingShimmer.isHidden = true
        resultScrollView.isHidden = false
    }

    var isShowingLoadingState: Bool { loadingBaseText != nil }

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

