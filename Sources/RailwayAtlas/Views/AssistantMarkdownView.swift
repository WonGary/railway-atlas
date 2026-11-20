import RailwayCore
import SwiftUI
#if os(macOS)
import AppKit
private typealias AssistantNativeFont = NSFont
private typealias AssistantNativeColor = NSColor
#else
import UIKit
private typealias AssistantNativeFont = UIFont
private typealias AssistantNativeColor = UIColor
#endif

/// A reply is one text document so selection can cross paragraphs and code.
struct AssistantMarkdownView: View {
    @Environment(\.atlasUIScale) private var scale
    let text: String
    let plain: Bool
    init(_ text: String, plain: Bool = false) { self.text = text; self.plain = plain }
    var body: some View {
        AssistantSelectableText(value: AssistantRichText.render(text, scale: scale, plain: plain))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
enum AssistantRichText {
    static func render(_ text: String, scale: Double, plain: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        #if os(macOS)
        let foreground = NSColor.labelColor
        #else
        let foreground = UIColor.label
        #endif
        func append(_ value: String, size: Double = 14, bold: Bool = false,
                    mono: Bool = false, indent: Double = 0, literal: Bool = false,
                    style: NSParagraphStyle? = nil) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 8 * scale
            paragraph.lineSpacing = 3 * scale
            paragraph.headIndent = indent * scale
            paragraph.firstLineHeadIndent = indent * scale
            paragraph.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: mono ? AssistantNativeFont.monospacedSystemFont(ofSize: size * scale, weight: .regular)
                    : AssistantNativeFont.systemFont(ofSize: size * scale, weight: bold ? .semibold : .regular),
                .foregroundColor: foreground, .paragraphStyle: style ?? paragraph
            ]
            guard !literal else {
                result.append(NSAttributedString(string: value + "\n", attributes: attributes)); return
            }
            let parsed = AssistantMarkdown.inline(value)
            for run in parsed.runs {
                var attrs = attributes
                let intent = run.inlinePresentationIntent
                if intent?.contains(.code) == true {
                    attrs[.font] = AssistantNativeFont.monospacedSystemFont(ofSize: (size - 1) * scale, weight: .regular)
                    attrs[.backgroundColor] = foreground.withAlphaComponent(0.08)
                } else if intent?.contains(.stronglyEmphasized) == true {
                    attrs[.font] = AssistantNativeFont.systemFont(ofSize: size * scale, weight: .bold)
                }
                if intent?.contains(.emphasized) == true { attrs[.obliqueness] = 0.15 }
                if intent?.contains(.strikethrough) == true { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link, ["https", "http"].contains(link.scheme?.lowercased() ?? ""),
                   link.host != nil, link.user == nil, link.password == nil { attrs[.link] = link }
                result.append(NSAttributedString(string: String(parsed.characters[run.range]), attributes: attrs))
            }
            result.append(NSAttributedString(string: "\n", attributes: attributes))
        }
        if plain { append(text, literal: true) }
        else {
            for block in AssistantMarkdown.parse(text) {
                switch block {
                case let .heading(level, value): append(value, size: level == 1 ? 23 : level == 2 ? 19 : 16, bold: true)
                case let .paragraph(value): append(value)
                case let .item(marker, value, depth): append(marker + " " + value, indent: Double(depth) * 14)
                case let .quote(value): append("│ " + value, indent: 8)
                case let .code(language, value):
                    if !language.isEmpty { append(language, size: 11, bold: true) }
                    append(value, size: 12, mono: true, literal: true)
                case let .table(headers, rows):
                    #if os(macOS)
                    let table = NSTextTable()
                    table.numberOfColumns = headers.count
                    table.collapsesBorders = true
                    table.layoutAlgorithm = .fixedLayoutAlgorithm
                    table.setContentWidth(100, type: .percentageValueType)
                    for (rowIndex, row) in ([headers] + rows).enumerated() {
                        for (column, value) in row.enumerated() {
                            let cell = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1,
                                                        startingColumn: column, columnSpan: 1)
                            cell.setContentWidth(100 / Double(headers.count), type: .percentageValueType)
                            cell.setWidth(6 * scale, type: .absoluteValueType, for: .padding)
                            cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                            cell.setBorderColor(foreground.withAlphaComponent(0.18))
                            cell.backgroundColor = foreground.withAlphaComponent(rowIndex == 0 ? 0.07 : 0.02)
                            let paragraph = NSMutableParagraphStyle()
                            paragraph.textBlocks = [cell]; paragraph.lineSpacing = 2 * scale
                            append(value, size: 13, bold: rowIndex == 0, style: paragraph)
                        }
                    }
                    #else
                    append(headers.joined(separator: "  │  "), size: 13, bold: true)
                    for row in rows { append(row.joined(separator: "  │  "), size: 13) }
                    #endif
                case .rule: append("────────────", size: 12, literal: true)
                }
            }
        }
        if result.length > 0 { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
        return result
    }

    static func documentData(_ value: NSAttributedString, type: NSAttributedString.DocumentType) -> Data? {
        try? value.data(from: NSRange(location: 0, length: value.length), documentAttributes: [.documentType: type])
    }
}

#if os(macOS)
/// Explicit UTF-8 export also works on AppKit versions whose inherited
/// writeSelection only advertises legacy rich-text pasteboard types.
final class AssistantReplyTextView: NSTextView {
    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let range = selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (string as NSString).length else { return false }
        if type == .string {
            return pasteboard.setString((string as NSString).substring(with: range), forType: .string)
        }
        if type == .rtf || type == .html {
            let value = attributedString().attributedSubstring(from: range)
            guard let data = AssistantRichText.documentData(value, type: type == .rtf ? .rtf : .html) else { return false }
            return pasteboard.setData(data, forType: type)
        }
        return super.writeSelection(to: pasteboard, type: type)
    }
    override func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        var wrote = false
        for type in types { if writeSelection(to: pasteboard, type: type) { wrote = true } }
        return wrote
    }
    override func copy(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        let board = NSPasteboard.general
        board.declareTypes([.string, .rtf, .html], owner: nil)
        _ = writeSelection(to: board, types: [.string, .rtf, .html])
    }
}

struct AssistantSelectableText: NSViewRepresentable {
    let value: NSAttributedString
    func makeNSView(context: Context) -> NSTextView {
        // Tables use the classic layout manager. Construct it up front so the
        // first measure doesn't race NSTextView's automatic compatibility switch.
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let view = AssistantReplyTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.setAccessibilityIdentifier("assistant-selectable-text")
        view.setAccessibilityLabel("回答正文，可选择文字并复制")
        return view
    }
    func updateNSView(_ view: NSTextView, context: Context) {
        guard view.textStorage?.isEqual(to: value) != true else { return }
        let sameText = view.string == value.string
        let selection = view.selectedRanges
        view.textStorage?.setAttributedString(value)
        if sameText { view.selectedRanges = selection }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let container = view.textContainer, let manager = view.layoutManager else { return nil }
        if view.frame.width != width {
            view.setFrameSize(NSSize(width: width, height: view.frame.height))
            manager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: view.textStorage?.length ?? 0),
                                     actualCharacterRange: nil)
        }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(manager.usedRect(for: container).height) + 2)
    }
}
#else
struct AssistantSelectableText: UIViewRepresentable {
    let value: NSAttributedString
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = false
        view.backgroundColor = .clear; view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.accessibilityIdentifier = "assistant-selectable-text"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        guard view.attributedText != value else { return }
        let sameText = view.text == value.string, selection = view.selectedRange
        view.attributedText = value
        if sameText { view.selectedRange = selection }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}
#endif
