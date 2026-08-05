import AppKit
import SwiftUI

/// Pragmatic line-based block parser. Not a CommonMark implementation: it
/// recognizes the block shapes an agent actually emits (headings, lists,
/// quotes, rules, fenced code) and treats everything else as paragraphs. The
/// parse is a pure function of the input string, so partial streaming text
/// re-renders deterministically — an unterminated fence simply becomes a code
/// block that runs to the end of the text.
private enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(items: [ListItem])
    case quote(String)
    case code(language: String?, code: String)
    case thematicBreak

    struct ListItem: Equatable {
        enum Marker: Equatable {
            case bullet
            case ordered(String)
        }

        let marker: Marker
        /// 0 = top level, 1 = indented one level (2–4 leading spaces).
        let depth: Int
        let text: String
    }

    private struct ListStart {
        let item: ListItem
    }

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var listItems: [ListItem] = []
        var quoteLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCode = false

        func flushParagraph() {
            let paragraph = paragraphLines.joined(separator: "\n")
            paragraphLines = []
            if !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.paragraph(paragraph))
            }
        }

        func flushList() {
            if !listItems.isEmpty {
                blocks.append(.list(items: listItems))
                listItems = []
            }
        }

        func flushQuote() {
            let quote = quoteLines.joined(separator: "\n")
            quoteLines = []
            if !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.quote(quote))
            }
        }

        func flushProse() {
            flushParagraph()
            flushList()
            flushQuote()
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
                    codeLines = []
                    codeLanguage = nil
                    inCode = false
                } else {
                    flushProse()
                    let language = String(trimmed.dropFirst(3))
                    codeLanguage = language.isEmpty ? nil : language
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushProse()
                continue
            }

            if isThematicBreak(trimmed) {
                flushProse()
                blocks.append(.thematicBreak)
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushProse()
                blocks.append(heading)
                continue
            }

            if let start = parseListStart(line) {
                flushParagraph()
                flushQuote()
                listItems.append(start.item)
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                var quoteLine = String(trimmed.dropFirst())
                if quoteLine.hasPrefix(" ") { quoteLine.removeFirst() }
                quoteLines.append(quoteLine)
                continue
            }

            flushList()
            flushQuote()
            paragraphLines.append(line)
        }

        if inCode {
            blocks.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
        } else {
            flushProse()
        }
        return blocks
    }

    /// `---`, `***`, `___` (3+ of one character, spaces allowed between).
    private static func isThematicBreak(_ trimmed: String) -> Bool {
        let chars = trimmed.filter { $0 != " " }
        guard chars.count >= 3, let first = chars.first,
              first == "-" || first == "*" || first == "_"
        else { return false }
        return chars.allSatisfy { $0 == first }
    }

    private static func parseHeading(_ trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix(while: { $0 == "#" })
        guard !hashes.isEmpty, hashes.count <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.hasPrefix(" ") else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: hashes.count, text: text)
    }

    /// Unordered `-`/`*`/`+` and ordered `1.`/`1)` items. Up to four leading
    /// spaces count as one nesting level; deeper indents stay plain text.
    private static func parseListStart(_ line: String) -> ListStart? {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        guard leadingSpaces <= 4 else { return nil }
        let rest = line[line.index(line.startIndex, offsetBy: leadingSpaces)...]
        let depth = leadingSpaces >= 2 ? 1 : 0

        if let first = rest.first, first == "-" || first == "*" || first == "+" {
            let after = rest.dropFirst()
            guard after.hasPrefix(" ") else { return nil }
            let content = after.trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { return nil }
            return ListStart(item: ListItem(marker: .bullet, depth: depth, text: content))
        }

        var index = rest.startIndex
        var digits = ""
        while index < rest.endIndex, rest[index].isNumber {
            digits.append(rest[index])
            index = rest.index(after: index)
        }
        guard !digits.isEmpty, index < rest.endIndex,
              rest[index] == "." || rest[index] == ")"
        else { return nil }
        let marker = digits + String(rest[index])
        let after = rest[rest.index(after: index)...]
        guard after.hasPrefix(" ") else { return nil }
        let content = after.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        return ListStart(item: ListItem(marker: .ordered(marker), depth: depth, text: content))
    }
}

/// Builds an AttributedString with inline Markdown intent (bold, italic,
/// links, strikethrough) and restyles inline-code runs as visible chips:
/// monospaced font over a semantic fill that reads in both light and dark.
private func styledInline(_ string: String) -> AttributedString {
    var attributed = (try? AttributedString(
        markdown: string,
        options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(string)

    for run in attributed.runs {
        guard let inlineIntent = run.inlinePresentationIntent,
              inlineIntent.contains(.code)
        else { continue }
        attributed[run.range].font = Theme.inlineCodeFont
        attributed[run.range].backgroundColor = Color(nsColor: .tertiarySystemFill)
    }
    return attributed
}

/// Inline-only Markdown (bold/italic/links/strikethrough/code chips) for
/// contexts without block layout, e.g. the user bubble. No forced width, so
/// the bubble still hugs its content.
struct MarkdownInlineText: View {
    let text: String

    var body: some View {
        Text(styledInline(text))
            .lineSpacing(4)
            .textSelection(.enabled)
    }
}

/// Full-width inline text used by block layouts.
private struct BlockInlineText: View {
    let text: String

    var body: some View {
        MarkdownInlineText(text: text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Lightweight Markdown rendering for transcript text. Blocks are spaced like
/// Codex's transcript; inline code renders as chips; everything stays
/// selectable and cheap to re-render while streaming.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            BlockInlineText(text: text)
                .font(headingFont(level: level))
                .padding(.top, Theme.Spacing.small)
        case let .paragraph(text):
            BlockInlineText(text: text)
        case let .list(items):
            ListBlock(items: items)
        case let .quote(text):
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: 3)
                BlockInlineText(text: text)
                    .foregroundStyle(.secondary)
                    .padding(.leading, Theme.Spacing.medium)
            }
        case let .code(language, code):
            CodeBlockCard(language: language, code: code)
        case .thematicBreak:
            Divider()
                .padding(.vertical, 2)
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1:
            return .title3.bold()
        case 2:
            return .headline
        default:
            return .subheadline.weight(.semibold)
        }
    }
}

private struct ListBlock: View {
    let items: [MarkdownBlock.ListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                    markerView(item.marker)
                        .frame(width: 16, alignment: .trailing)
                    BlockInlineText(text: item.text)
                }
                .padding(.leading, item.depth > 0 ? 22 : 0)
            }
        }
    }

    private func markerView(_ marker: MarkdownBlock.ListItem.Marker) -> some View {
        switch marker {
        case .bullet:
            return Text("•").foregroundStyle(.secondary)
        case let .ordered(marker):
            return Text(marker)
        }
    }
}

private struct CodeBlockCard: View {
    let language: String?
    let code: String

    @StateObject private var hover = HoverState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.small) {
                Text(language ?? "code")
                    .font(Theme.codeCaptionFont)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Label("拷贝", systemImage: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                // Visually revealed on hover; stays in the hierarchy so Full
                // Keyboard Access and VoiceOver can always reach it.
                .opacity(hover.isHovering ? 1 : 0)
                .accessibilityLabel("拷贝代码块")
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(Theme.codeFont)
                    .textSelection(.enabled)
                    .padding(.horizontal, Theme.Spacing.medium)
                    .padding(.vertical, Theme.Spacing.medium)
            }
        }
        .subtleCard(cornerRadius: Theme.Radius.small)
        .onHover { hover.isHovering = $0 }
    }
}
