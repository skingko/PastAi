import AppKit
import ClipCore
import SwiftUI

@MainActor
final class ClipEditorController: NSObject, NSWindowDelegate {
    private let service: ClipService
    private var window: NSPanel?

    init(service: ClipService) {
        self.service = service
    }

    func open(clipID: Int64) {
        Task { [weak self] in
            guard let self, let detail = try? await self.service.detail(id: clipID) else { return }
            self.present(
                ClipEditorView(
                    title: detail.clip.title ?? "",
                    text: detail.clip.plainText ?? "",
                    editsText: detail.clip.kind.isTextual,
                    heading: detail.clip.kind.isTextual ? "编辑内容" : "重命名",
                    onCancel: { [weak self] in self?.close() },
                    onSave: { [weak self] title, text in self?.save(detail: detail, title: title, text: text) }
                )
            )
        }
    }

    func openNew() {
        present(
            ClipEditorView(
                title: "",
                text: "",
                editsText: true,
                heading: "新建文本",
                onCancel: { [weak self] in self?.close() },
                onSave: { [weak self] title, text in self?.create(title: title, text: text) }
            )
        )
    }

    private func save(detail: ClipDetail, title: String, text: String) {
        var mutations: [ClipMutation] = []
        let newTitle = title.isEmpty ? nil : title
        if newTitle != detail.clip.title {
            mutations.append(.setTitle(clipID: detail.clip.id, title: newTitle))
        }
        if detail.clip.kind.isTextual, text != detail.clip.plainText {
            mutations.append(.setText(clipID: detail.clip.id, text: text))
        }
        close()
        guard !mutations.isEmpty else { return }
        Task { try? await service.apply(mutations, source: .user, summary: "编辑条目") }
    }

    private func create(title: String, text: String) {
        close()
        guard !text.isEmpty else { return }
        Task {
            try? await service.apply(
                [.createText(text: text, title: title.isEmpty ? nil : title, pinboardID: nil)],
                source: .user, summary: "新建文本"
            )
        }
    }

    private func present(_ view: ClipEditorView) {
        close()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = view.heading
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: view)
        panel.delegate = self
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        window = panel
    }

    private func close() {
        window?.orderOut(nil)
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct ClipEditorView: View {
    @State var title: String
    @State var text: String
    var editsText: Bool
    var heading: String
    var onCancel: () -> Void
    var onSave: (String, String) -> Void

    var body: some View {
        VStack(spacing: 10) {
            TextField("标题（可选）", text: $title).textFieldStyle(.roundedBorder)
            if editsText {
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            } else {
                Spacer()
            }
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("保存") { onSave(title, text) }.keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(14)
        .frame(minWidth: 420, minHeight: editsText ? 300 : 110)
    }
}
