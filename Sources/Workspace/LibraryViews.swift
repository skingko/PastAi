import ClipCore
import QuickLookUI
import SwiftUI

struct WorkspaceView: View {
    @Bindable var library: LibraryModel
    @Bindable var agent: AgentModel
    @State private var showsAgent = true

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(model: library)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            ClipListView(model: library, agent: agent)
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            HSplitView {
                ClipDetailView(model: library)
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                if showsAgent {
                    AgentPane(model: agent)
                }
            }
        }
        .searchable(text: $library.search, placement: .toolbar, prompt: "搜索全部内容")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsAgent.toggle()
                } label: {
                    Label("Agent", systemImage: "sparkles")
                }
                .help("显示或隐藏 Agent")
            }
        }
    }
}

private struct LibrarySidebar: View {
    @Bindable var model: LibraryModel

    var body: some View {
        List(selection: $model.section) {
            Label("全部", systemImage: "tray.full").tag(LibrarySection.all)
            if !model.pinboards.isEmpty {
                Section("Pinboard") {
                    ForEach(model.pinboards) { board in
                        HStack {
                            Circle().fill(Color(hex: board.colorHex)).frame(width: 10, height: 10)
                            Text(board.name).lineLimit(1)
                            if board.aiHidden {
                                Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.secondary).help("对 AI 隐藏")
                            }
                            Spacer()
                            Text("\(model.pinboardCounts[board.id] ?? 0)").font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(LibrarySection.pinboard(board.id))
                    }
                }
            }
            Section("类型") {
                ForEach(ClipKind.allCases) { kind in
                    Label(kind.displayName, systemImage: kind.symbolName).tag(LibrarySection.kind(kind))
                }
            }
            if !model.tags.isEmpty {
                Section("标签") {
                    ForEach(model.tags.prefix(30)) { tag in
                        HStack {
                            Label(tag.name, systemImage: "tag")
                            Spacer()
                            Text("\(tag.count)").font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(LibrarySection.tag(tag.name))
                    }
                }
            }
            Section {
                Label("回收站", systemImage: "trash").tag(LibrarySection.trash)
            }
        }
        .listStyle(.sidebar)
    }
}

private struct ClipListView: View {
    @Bindable var model: LibraryModel
    var agent: AgentModel
    @State private var confirmsEmptyTrash = false

    var body: some View {
        List(selection: $model.selection) {
            ForEach(Array(model.clips.enumerated()), id: \.element.id) { index, clip in
                ClipRow(clip: clip, thumbnail: model.thumbnailURL(clip))
                    .tag(clip.id)
                    .onAppear { model.loadMoreIfNeeded(index: index) }
            }
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            menu(for: ids)
        }
        .overlay {
            if model.clips.isEmpty {
                ContentUnavailableView(model.search.isEmpty ? "没有内容" : "没有匹配的内容", systemImage: "doc.on.clipboard")
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(model.total) 项").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.section == .trash, !model.clips.isEmpty {
                    Button("清空回收站", role: .destructive) { confirmsEmptyTrash = true }.controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .alert("永久删除回收站里的全部内容？", isPresented: $confirmsEmptyTrash) {
            Button("永久删除", role: .destructive) { model.emptyTrash() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这个操作无法撤销。")
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<Int64>) -> some View {
        if model.section == .trash {
            Button("恢复") { model.restore(ids) }
        } else {
            Button("拷贝") { model.copy(ids) }
            Button("交给 Agent") { agent.attach(Array(ids)) }
            if !model.pinboards.isEmpty {
                Menu("加入 Pinboard") {
                    ForEach(model.pinboards) { board in
                        Button(board.name) { model.pin(ids, to: board.id) }
                    }
                }
            }
            if case .pinboard(let board) = model.section {
                Button("从此 Pinboard 移除") { model.unpin(ids, from: board) }
            }
            Divider()
            Button("删除", role: .destructive) { model.delete(ids) }
        }
    }
}

private struct ClipRow: View {
    var clip: Clip
    var thumbnail: URL?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail, let image = NSImage(contentsOf: thumbnail) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: clip.kind.symbolName).foregroundStyle(.secondary)
                }
            }
            .frame(width: 34, height: 34)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(clip.displayTitle).lineLimit(1)
                    if clip.isSensitive || clip.aiHidden {
                        Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text("\(clip.sourceAppName ?? clip.kind.displayName) · \(clip.lastCopiedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ClipDetailView: View {
    @Bindable var model: LibraryModel

    var body: some View {
        if let detail = model.detail {
            ClipEditor(model: model, detail: detail).id(detail.clip.id)
        } else {
            ContentUnavailableView(
                model.selection.count > 1 ? "已选择 \(model.selection.count) 项" : "选择一个条目",
                systemImage: "doc.text.magnifyingglass"
            )
        }
    }
}

private struct ClipEditor: View {
    var model: LibraryModel
    var detail: ClipDetail
    @State private var title: String
    @State private var text: String
    @State private var tagText: String

    init(model: LibraryModel, detail: ClipDetail) {
        self.model = model
        self.detail = detail
        _title = State(initialValue: detail.clip.title ?? "")
        _text = State(initialValue: detail.clip.plainText ?? "")
        _tagText = State(initialValue: detail.tags.joined(separator: ", "))
    }

    private var clip: Clip { detail.clip }
    private var isDirty: Bool {
        title != (clip.title ?? "") || (clip.kind.isTextual && text != (clip.plainText ?? ""))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("标题", text: $title)
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
            metadata
            Divider()
            if clip.kind.isTextual {
                TextEditor(text: $text)
                    .font(clip.kind == .code ? .system(size: 12, design: .monospaced) : .body)
                    .scrollContentBackground(.hidden)
            } else {
                MediaPreview(detail: detail, service: model.service)
                if let ocr = clip.ocrText, !ocr.isEmpty {
                    DisclosureGroup("图中文字") {
                        Text(ocr).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Divider()
            HStack {
                Image(systemName: "tag").foregroundStyle(.secondary)
                TextField("标签，用逗号分隔", text: $tagText)
                    .textFieldStyle(.plain)
                    .onSubmit { saveTags() }
            }
            HStack {
                Toggle("对 AI 隐藏", isOn: Binding(
                    get: { clip.aiHidden || clip.isSensitive },
                    set: { model.setAIHidden(id: clip.id, hidden: $0) }
                ))
                .disabled(clip.isSensitive)
                .help(clip.isSensitive ? "检测到敏感内容，始终对 AI 隐藏" : "")
                Spacer()
                Button("拷贝") { model.copy([clip.id]) }
                Button("保存") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!isDirty)
            }
        }
        .padding(14)
    }

    private var metadata: some View {
        HStack(spacing: 10) {
            Label(clip.kind.displayName, systemImage: clip.kind.symbolName)
            if let app = clip.sourceAppName { Text(app) }
            Text(clip.lastCopiedAt.formatted(date: .abbreviated, time: .shortened))
            Text(ByteCountFormatter.string(fromByteCount: clip.byteSize, countStyle: .file))
            if clip.copyCount > 1 { Text("复制 \(clip.copyCount) 次") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func save() {
        model.saveContent(id: clip.id, title: title, text: clip.kind.isTextual ? text : nil)
    }

    private func saveTags() {
        let separators = CharacterSet(charactersIn: ",，、")
        let tags = tagText.components(separatedBy: separators).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        model.setTags(id: clip.id, tags: tags)
    }
}

/// Embedded Quick Look, which handles every format macOS can preview, including audio and video playback.
private struct MediaPreview: NSViewRepresentable {
    var detail: ClipDetail
    var service: ClipService

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)!
        view.shouldCloseWithWindow = true
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        view.previewItem = PreviewExporter.urls(for: detail, service: service).first as NSURL?
    }

    /// Clearing the item is enough. Calling `close()` here aborts inside Quick Look's own deactivation
    /// assertion, because SwiftUI dismantles the view while it is still being torn down.
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.previewItem = nil
    }
}

extension Color {
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(digits.prefix(6), radix: 16) ?? 0x888888
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
