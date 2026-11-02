import AppKit
import ClipCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Internal drag payload, a clip id, used for dropping cards onto Pinboard tabs.
    static let pastAiClip = UTType(exportedAs: "io.github.skingko.pastai.clip")
}

extension Color {
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let expanded = digits.count == 3 ? digits.map { "\($0)\($0)" }.joined() : digits
        let value = UInt64(expanded.prefix(6), radix: 16) ?? 0x888888
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

extension ClipKind {
    var tint: Color {
        switch self {
        case .text: Color(hex: "#3B82F6")
        case .link: Color(hex: "#14B8A6")
        case .code: Color(hex: "#6366F1")
        case .color: Color(hex: "#EC4899")
        case .image: Color(hex: "#F97316")
        case .video: Color(hex: "#EF4444")
        case .audio: Color(hex: "#A855F7")
        case .file: Color(hex: "#64748B")
        case .other: Color(hex: "#78716C")
        }
    }
}

enum RelativeTime {
    static func describe(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return L("刚刚") }
        if seconds < 3_600 { return L("\(Int(seconds / 60)) 分钟前") }
        if seconds < 86_400 { return L("\(Int(seconds / 3_600)) 小时前") }
        if seconds < 7 * 86_400 { return L("\(Int(seconds / 86_400)) 天前") }
        return date.formatted(.dateTime.month().day())
    }
}

/// Decoded images and app icons shared by every card, so scrolling back does not touch disk again.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let images = NSCache<NSString, NSImage>()

    private init() { images.countLimit = 300 }

    func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        let key = "icon:\(bundleID)" as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        images.setObject(icon, forKey: key)
        return icon
    }

    func cachedImage(at url: URL) -> NSImage? {
        images.object(forKey: url.path as NSString)
    }

    func loadImage(at url: URL) async -> NSImage? {
        if let cached = cachedImage(at: url) { return cached }
        let image = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
        if let image { images.setObject(image, forKey: url.path as NSString) }
        return image
    }
}

struct ThumbnailImage: View {
    var url: URL?
    var contentMode: ContentMode = .fill
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let shown = image ?? url.flatMap(ImageCache.shared.cachedImage) {
                Image(nsImage: shown).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Color.primary.opacity(0.05)
            }
        }
        .task(id: url) {
            image = nil
            if let url { image = await ImageCache.shared.loadImage(at: url) }
        }
    }
}

struct ClipCard: View {
    @Bindable var model: PanelModel
    var clip: Clip
    var number: Int?

    static let width: CGFloat = 232

    private var isSelected: Bool { model.selection.contains(clip.id) }
    private var isCursor: Bool { model.cursorID == clip.id }

    var body: some View {
        VStack(spacing: 0) {
            header
            ClipBody(clip: clip, thumbnail: model.iconURL(for: clip))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            footer
        }
        .frame(width: Self.width)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.92), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            model.select(clip.id, modifiers: NSEvent.modifierFlags)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.select(clip.id, modifiers: [])
            model.pasteSelection(plain: false)
        })
        .onDrag { dragProvider() }
        .overlay(RightClickCatcher { model.menu(for: clip) })
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: clip.kind.symbolName).font(.system(size: 11, weight: .semibold))
            VStack(alignment: .leading, spacing: 0) {
                Text(clip.title?.isEmpty == false ? clip.title! : clip.kind.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(RelativeTime.describe(clip.lastCopiedAt))
                    .font(.system(size: 10))
                    .opacity(0.85)
            }
            Spacer(minLength: 4)
            if clip.isSensitive || clip.aiHidden {
                Image(systemName: "eye.slash").font(.system(size: 10)).help(L("对 AI 隐藏"))
            }
            if let icon = ImageCache.shared.icon(forBundleID: clip.sourceBundleID) {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                    .help(clip.sourceAppName ?? "")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(clip.kind.tint)
    }

    private var footer: some View {
        HStack {
            Text(footerText).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if let number {
                Text("⌘\(number)").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
    }

    private var footerText: String {
        let size = ByteCountFormatter.string(fromByteCount: clip.byteSize, countStyle: .file)
        switch clip.kind {
        case .text, .code, .link, .color:
            return L("\(clip.textLength) 字符")
        case .image:
            if let width = clip.metadata.pixelWidth, let height = clip.metadata.pixelHeight {
                return "\(width)×\(height) · \(size)"
            }
            return size
        case .video, .audio:
            let duration = clip.metadata.durationSeconds.map(Self.formatDuration)
            return [duration, size].compactMap(\.self).joined(separator: " · ")
        case .file:
            let count = clip.metadata.fileCount ?? 1
            return count > 1 ? L("\(count) 个文件 · \(size)") : size
        case .other:
            return size
        }
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    private func dragProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let id = String(clip.id)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.pastAiClip.identifier, visibility: .ownProcess) { completion in
            completion(Data(id.utf8), nil)
            return nil
        }
        if let text = clip.plainText, clip.kind.isTextual {
            provider.registerObject(text as NSString, visibility: .all)
        }
        return provider
    }

}

private struct ClipBody: View {
    var clip: Clip
    var thumbnail: URL?

    var body: some View {
        switch clip.kind {
        case .image:
            // Screenshots are the common case and their edges matter, so show the whole image.
            ThumbnailImage(url: thumbnail, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.04))
        case .video:
            ZStack {
                ThumbnailImage(url: thumbnail)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 4)
            }
        case .audio:
            AudioBody(clip: clip, thumbnail: thumbnail)
        case .file:
            FileBody(clip: clip, thumbnail: thumbnail)
        case .color:
            ColorBody(text: clip.plainText ?? "")
        case .other:
            VStack(spacing: 6) {
                Image(systemName: "shippingbox").font(.system(size: 30)).foregroundStyle(.secondary)
                Text(L("应用私有格式")).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(clip.sourceAppName ?? "").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text, .link, .code:
            Text(previewText)
                .font(clip.kind == .code ? .system(size: 11, design: .monospaced) : .system(size: 12.5))
                .foregroundStyle(clip.kind == .link ? Color.accentColor : .primary)
                .lineSpacing(2)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var previewText: String {
        String((clip.plainText ?? "").prefix(600))
    }
}

private struct AudioBody: View {
    var clip: Clip
    var thumbnail: URL?

    var body: some View {
        VStack(spacing: 8) {
            if thumbnail != nil {
                ThumbnailImage(url: thumbnail)
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "waveform").font(.system(size: 40)).foregroundStyle(ClipKind.audio.tint)
            }
            Text(clip.metadata.mediaTitle ?? clip.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
            if let artist = clip.metadata.artist {
                Text(artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FileBody: View {
    var clip: Clip
    var thumbnail: URL?

    private var names: [String] {
        (clip.plainText ?? "").split(whereSeparator: \.isNewline).map(String.init)
    }

    var body: some View {
        VStack(spacing: 6) {
            if let thumbnail {
                ThumbnailImage(url: thumbnail)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "doc.fill").font(.system(size: 42)).foregroundStyle(.secondary)
            }
            Text(names.first ?? L("文件")).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.center)
            if names.count > 1 {
                Text(L("等 \(names.count) 项")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ColorBody: View {
    var text: String

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        ZStack {
            if trimmed.hasPrefix("#") {
                Color(hex: trimmed)
            } else {
                Color.primary.opacity(0.05)
            }
            Text(trimmed)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
        }
    }
}
