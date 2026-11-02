import AppKit
import ClipAgent
import ClipCore
import SwiftUI

/// Renders an assistant reply. Parsed on each streamed chunk, so it must stay cheap.
struct MarkdownText: View {
    var source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(source).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(.system(size: level == 1 ? 15 : level == 2 ? 14 : 13, weight: .semibold))
                .padding(.top, 4)
        case .paragraph(let text):
            Text(Self.inline(text)).font(.system(size: 13)).lineSpacing(3.5)
        case .bullets(let items):
            ListBlock(items: items) { _ in "•" }
        case .numbered(let items):
            ListBlock(items: items) { "\($0 + 1)." }
        case .quote(let text):
            HStack(spacing: 10) {
                Capsule().fill(Color.primary.opacity(0.14)).frame(width: 2.5)
                Text(Self.inline(text)).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let text):
            CodeBlock(language: language, text: text)
        }
    }

    static func inline(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var parsed = try? AttributedString(markdown: source, options: options) else {
            return AttributedString(source)
        }
        for run in parsed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            parsed[run.range].font = .system(size: 12, design: .monospaced)
            parsed[run.range].backgroundColor = Color.primary.opacity(0.07)
        }
        return parsed
    }
}

private struct ListBlock: View {
    var items: [String]
    var marker: (Int) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker(index))
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 14, alignment: .trailing)
                    Text(MarkdownText.inline(item)).font(.system(size: 13)).lineSpacing(3)
                }
            }
        }
    }
}

private struct CodeBlock: View {
    var language: String?
    var text: String
    @State private var isHovered = false
    @State private var didCopy = false

    var body: some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .lineSpacing(2.5)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if isHovered {
                Button(didCopy ? L("已拷贝") : L("拷贝")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    didCopy = true
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.bar, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(6)
            }
        }
        .onHover { hovering in
            isHovered = hovering
            if !hovering { didCopy = false }
        }
    }
}
