import AppKit
import ClipCore
import ClipExtensions
import Observation
import SwiftUI

/// Clicks must land on the first press: these panels never become key, because taking focus from the
/// app underneath would drop its selection and leave nothing for Insert to replace.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// A borderless panel with the shared rounded material behind `content`.
    static func make<Content: View>(content: Content, level: NSWindow.Level = .popUpMenu) -> (panel: NonActivatingPanel, host: NSView) {
        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true

        let host = FirstMouseHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        return (panel, host)
    }
}

@MainActor
@Observable
final class ActionBarModel {
    static let maxVisible = 8

    var items: [InstalledExtension] = []
    /// Briefly replaces an icon with a checkmark so a silent action still feels acknowledged.
    var confirmedID: String?
    @ObservationIgnored var iconURL: (InstalledExtension) -> URL? = { _ in nil }
    @ObservationIgnored var onTap: (InstalledExtension) -> Void = { _ in }
    @ObservationIgnored var onOverflow: (NSView) -> Void = { _ in }

    var visible: [InstalledExtension] { Array(items.prefix(Self.maxVisible)) }
    var overflow: [InstalledExtension] { Array(items.dropFirst(Self.maxVisible)) }
}

struct ActionBarView: View {
    var model: ActionBarModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(model.visible) { item in
                BarButton(item: item, iconURL: model.iconURL(item), isConfirmed: model.confirmedID == item.id) {
                    model.onTap(item)
                }
            }
            if !model.overflow.isEmpty {
                OverflowButton(onPress: model.onOverflow)
            }
        }
        .padding(4)
        .fixedSize()
    }
}

private struct BarButton: View {
    var item: InstalledExtension
    var iconURL: URL?
    var isConfirmed: Bool
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if isConfirmed {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                } else {
                    ExtensionIconView(icon: item.manifest.icon, fileURL: iconURL, size: 16)
                }
            }
            .frame(width: 32, height: 30)
            .background(isHovered ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.manifest.name.localized)
        .onHover { isHovered = $0 }
    }
}

private struct OverflowButton: View {
    var onPress: (NSView) -> Void

    var body: some View {
        OverflowAnchor(onPress: onPress).frame(width: 26, height: 30)
    }
}

/// An AppKit button, because the overflow menu needs a real view to attach to.
private struct OverflowAnchor: NSViewRepresentable {
    var onPress: (NSView) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: L("更多")) ?? NSImage(),
            target: context.coordinator, action: #selector(Coordinator.press(_:))
        )
        button.isBordered = false
        button.contentTintColor = .labelColor
        return button
    }

    func updateNSView(_ view: NSButton, context: Context) {
        context.coordinator.onPress = onPress
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPress: onPress) }

    @MainActor
    final class Coordinator: NSObject {
        var onPress: (NSView) -> Void

        init(onPress: @escaping (NSView) -> Void) { self.onPress = onPress }

        @objc func press(_ sender: NSButton) { onPress(sender) }
    }
}

@MainActor
@Observable
final class ResultModel {
    enum Phase: Equatable {
        case working
        case done
        case message(String)
        case failed(String)
        case needsConsent(String)
    }

    var title = ""
    var icon = ""
    var iconURL: URL?
    var text = ""
    var phase = Phase.working
    var canInsert = false
    var isOnClipboard = false

    @ObservationIgnored var onInsert: () -> Void = {}
    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored var onConsent: () -> Void = {}
    @ObservationIgnored var onOpenSettings: (() -> Void)?

    static let width: CGFloat = 380
    static let maxBodyHeight: CGFloat = 260

    /// Measured by hand because a `ScrollView` reports no natural height of its own.
    var bodyHeight: CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: Self.width - 32, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes
        )
        let lineCount = max(1, (bounds.height / 16).rounded(.up))
        return min(bounds.height + lineCount * 3.5 + 4, Self.maxBodyHeight)
    }
}

struct ResultView: View {
    var model: ResultModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                ExtensionIconView(icon: model.icon, fileURL: model.iconURL, size: 13).foregroundStyle(.secondary)
                Text(model.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                if model.phase == .working {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                Button(action: model.onClose) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            }
            content
        }
        .padding(14)
        .frame(width: ResultModel.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .working, .done:
            if !model.text.isEmpty {
                ScrollView {
                    Text(model.text)
                        .font(.system(size: 13))
                        .lineSpacing(3.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
                .frame(height: model.bodyHeight)
            }
            if model.phase == .done { footer }
        case .message(let text):
            Text(text).font(.system(size: 13)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            if let open = model.onOpenSettings {
                Button(L("打开设置"), action: open).controlSize(.small)
            }
        case .failed(let text):
            Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            if let open = model.onOpenSettings {
                Button(L("模型设置"), action: open).controlSize(.small)
            }
        case .needsConsent(let provider):
            Text(L("这段文字会发送给 \(provider)。使用本地模型时内容不会离开这台 Mac。"))
                .font(.system(size: 13)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("取消"), action: model.onClose)
                Button(L("允许"), action: model.onConsent).buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.isOnClipboard {
                Label(L("已加入剪贴板"), systemImage: "checkmark").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.canInsert {
                Button(L("插入"), action: model.onInsert)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help(L("替换选中的原文"))
            }
        }
    }
}
