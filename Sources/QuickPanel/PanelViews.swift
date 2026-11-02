import AppKit
import ClipCore
import SwiftUI
import UniformTypeIdentifiers

struct PanelRootView: View {
    @Bindable var model: PanelModel

    var body: some View {
        VStack(spacing: 10) {
            PanelHeader(model: model)
            if model.showsFilters || model.hasActiveFilters {
                FilterBar(model: model)
            }
            ClipStrip(model: model)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }
}

private struct PanelHeader: View {
    @Bindable var model: PanelModel
    @State private var isCreatingBoard = false

    var body: some View {
        HStack(spacing: 8) {
            // Matches the two buttons on the right so the search and tabs stay truly centred.
            Color.clear.frame(width: 64, height: 1)
            Spacer(minLength: 8)
            SearchPill(model: model)
            ViewThatFits(in: .horizontal) {
                tabs
                ScrollView(.horizontal) { tabs }.scrollIndicators(.hidden)
            }
            Spacer(minLength: 8)
            filterButton
            moreMenu
        }
        .frame(height: 32)
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            TabButton(title: "剪贴板", isSelected: model.tab == .history, leading: AnyView(Image(systemName: "clock.arrow.circlepath"))) {
                model.tab = .history
            }
            ForEach(model.settings.pinnedKinds) { kind in
                TabButton(
                    title: kind.displayName,
                    isSelected: model.tab == .kind(kind),
                    leading: AnyView(Image(systemName: kind.symbolName).foregroundStyle(kind.tint))
                ) {
                    model.tab = .kind(kind)
                }
            }
            ForEach(model.pinboards) { board in
                PinboardTab(model: model, board: board)
            }
            Button {
                isCreatingBoard = true
            } label: {
                Image(systemName: "plus").font(.system(size: 14, weight: .medium)).frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("新建 Pinboard")
            .popover(isPresented: $isCreatingBoard, arrowEdge: .top) {
                PinboardForm(initialName: "", initialColor: Pinboard.palette[model.pinboards.count % Pinboard.palette.count]) { name, color in
                    model.createPinboard(name: name, colorHex: color)
                    isCreatingBoard = false
                }
            }
        }
    }

    private var filterButton: some View {
        Button {
            model.showsFilters.toggle()
            if model.showsFilters { model.loadSources() }
        } label: {
            Image(systemName: model.hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 15))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help("筛选 (⌘F)")
    }

    private var moreMenu: some View {
        Menu {
            Button("打开主窗口") { model.actions.openMainWindow() }
            Button("新建文本") { model.actions.newText() }
            Divider()
            Button(model.settings.isPaused ? "继续记录" : "暂停记录") { model.settings.togglePause() }
            Button("设置…") { model.actions.openSettings() }
            Divider()
            Button("退出 PastAi") { model.actions.quit() }
        } label: {
            Image(systemName: model.settings.isPaused ? "pause.circle.fill" : "ellipsis.circle")
                .font(.system(size: 15))
                .frame(width: 28, height: 28)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct SearchPill: View {
    @Bindable var model: PanelModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            PanelSearchField(text: $model.query, placeholder: "搜索")
                .frame(height: 18)
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: model.query.isEmpty ? 96 : 220, height: 30)
        .background(.quaternary.opacity(0.55), in: Capsule())
        .animation(.easeOut(duration: 0.14), value: model.query.isEmpty)
    }
}

/// An AppKit field so it can stay first responder for the panel's whole lifetime. That is what lets
/// a Chinese input method compose in place, with arrows and Return handled by the key monitor.
struct PanelSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.identifier = .init("panel-search")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.currentEditor() == nil || !context.coordinator.isEditing, field.stringValue != text {
            field.stringValue = text
        } else if text.isEmpty, !field.stringValue.isEmpty, !(field.currentEditor() as? NSTextView).hasMarkedTextValue {
            field.stringValue = ""
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var isEditing = false

        init(text: Binding<String>) { self.text = text }

        func controlTextDidBeginEditing(_ notification: Notification) { isEditing = true }
        func controlTextDidEndEditing(_ notification: Notification) { isEditing = false }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // Searching on half-composed pinyin would flash irrelevant results.
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
            text.wrappedValue = field.stringValue
        }
    }
}

@MainActor
private extension Optional where Wrapped == NSTextView {
    var hasMarkedTextValue: Bool { self?.hasMarkedText() ?? false }
}

private struct TabButton: View {
    var title: String
    var isSelected: Bool
    var leading: AnyView
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                leading
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(background, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var background: Color {
        if isSelected { return Color.primary.opacity(0.14) }
        return isHovered ? Color.primary.opacity(0.07) : .clear
    }
}

private struct PinboardTab: View {
    @Bindable var model: PanelModel
    var board: Pinboard
    @State private var isEditing = false
    @State private var isDropTargeted = false

    var body: some View {
        TabButton(
            title: board.name,
            isSelected: model.tab == .pinboard(board.id),
            leading: AnyView(
                Circle().fill(Color(hex: board.colorHex)).frame(width: 11, height: 11)
                    .overlay {
                        if board.aiHidden {
                            Image(systemName: "eye.slash.fill").font(.system(size: 6, weight: .bold)).foregroundStyle(.white)
                        }
                    }
            )
        ) {
            model.tab = .pinboard(board.id)
        }
        .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: isDropTargeted ? 2 : 0))
        .onDrop(of: [.pastAiClip], isTargeted: $isDropTargeted) { providers in
            for provider in providers {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.pastAiClip.identifier) { data, _ in
                    guard let data, let text = String(data: data, encoding: .utf8), let id = Int64(text) else { return }
                    let boardID = board.id
                    Task { @MainActor in model.pin([id], to: boardID) }
                }
            }
            return true
        }
        .overlay(RightClickCatcher { model.menu(for: board) { isEditing = true } })
        .popover(isPresented: $isEditing, arrowEdge: .top) {
            PinboardForm(initialName: board.name, initialColor: board.colorHex) { name, color in
                var updated = board
                updated.name = name
                updated.colorHex = color
                model.update(updated)
                isEditing = false
            }
        }
    }
}

private struct PinboardForm: View {
    @State var name: String
    @State var color: String
    var onSubmit: (String, String) -> Void

    init(initialName: String, initialColor: String, onSubmit: @escaping (String, String) -> Void) {
        _name = State(initialValue: initialName)
        _color = State(initialValue: initialColor)
        self.onSubmit = onSubmit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            HStack(spacing: 8) {
                ForEach(Pinboard.palette, id: \.self) { hex in
                    Button {
                        color = hex
                    } label: {
                        Circle().fill(Color(hex: hex)).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(.primary.opacity(color == hex ? 0.8 : 0), lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button("完成") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private func submit() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onSubmit(name, color)
    }
}

private struct FilterBar: View {
    @Bindable var model: PanelModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ClipKind.allCases) { kind in
                Chip(title: kind.displayName, symbol: kind.symbolName, isOn: model.kindFilter == kind) {
                    model.kindFilter = model.kindFilter == kind ? nil : kind
                }
            }
            Divider().frame(height: 16)
            Menu {
                Button("全部来源") { model.sourceFilter = nil }
                ForEach(model.sources) { source in
                    Button("\(source.name) (\(source.count))") { model.sourceFilter = source }
                }
            } label: {
                Text(model.sourceFilter?.name ?? "来源").font(.system(size: 12))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            Menu {
                Button("全部时间") { model.dateFilter = nil }
                ForEach(DateFilter.allCases) { filter in
                    Button(filter.label) { model.dateFilter = filter }
                }
            } label: {
                Text(model.dateFilter?.label ?? "时间").font(.system(size: 12))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            Spacer()
            if model.hasActiveFilters {
                Button("清除筛选") {
                    model.kindFilter = nil
                    model.sourceFilter = nil
                    model.dateFilter = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
        .frame(height: 24)
    }
}

private struct Chip: View {
    var title: String
    var symbol: String
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(isOn ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.07), in: Capsule())
                .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

private struct ClipStrip: View {
    @Bindable var model: PanelModel

    var body: some View {
        Group {
            if model.clips.isEmpty {
                ContentUnavailableView(
                    model.isSearching ? "没有匹配的内容" : "这里还是空的",
                    systemImage: model.isSearching ? "magnifyingglass" : "doc.on.clipboard",
                    description: Text(model.isSearching ? "换个关键词或清除筛选" : "复制任何内容，它都会出现在这里")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 12) {
                            ForEach(Array(model.clips.enumerated()), id: \.element.id) { index, clip in
                                ClipCard(model: model, clip: clip, number: index < 9 ? index + 1 : nil)
                                    .id(clip.id)
                                    .onAppear { model.loadMoreIfNeeded(index: index) }
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: model.cursorID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: model.scrollRequest) { _, _ in
                        if let id = model.cursorID { proxy.scrollTo(id, anchor: .leading) }
                    }
                }
            }
        }
    }
}
