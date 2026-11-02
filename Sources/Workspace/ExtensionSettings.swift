import AppKit
import ClipCore
import ClipExtensions
import Observation
import SwiftUI

@MainActor
@Observable
final class MarketModel {
    enum Status {
        case available
        case installed
        case updateAvailable
    }

    private let library: ExtensionLibrary
    private let catalog: ExtensionCatalog
    private let bundled: URL?

    private(set) var entries: [CatalogEntry] = []
    private(set) var isLoading = false
    private(set) var notice: String?
    private(set) var installing: Set<String> = []
    var search = ""
    var region = "all"

    init(library: ExtensionLibrary, catalog: ExtensionCatalog, bundled: URL?) {
        self.library = library
        self.catalog = catalog
        self.bundled = bundled
    }

    var visibleEntries: [CatalogEntry] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { entry in
            guard region == "all" || entry.regions.contains(region) else { return false }
            guard !needle.isEmpty else { return true }
            let haystack = [entry.name.en, entry.name.zh ?? "", entry.description.en, entry.description.zh ?? ""]
            return haystack.contains { $0.lowercased().contains(needle) }
        }
    }

    func status(of entry: CatalogEntry) -> Status {
        guard let installed = library.extensionItem(id: entry.id) else { return .available }
        return ExtensionCatalog.isNewer(entry.version, than: installed.manifest.version) ? .updateAvailable : .installed
    }

    /// Falls back to the copy inside the app, so the market still works with GitHub blocked or offline.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await catalog.fetchIndex().extensions
            notice = nil
        } catch {
            if let bundled, let index = try? ExtensionCatalog.bundledIndex(at: bundled) {
                entries = index.extensions
                notice = "无法连接 GitHub，显示的是内置组件。"
            } else {
                notice = "无法加载组件市场：\(error.localizedDescription)"
            }
        }
    }

    func install(_ entry: CatalogEntry) async {
        installing.insert(entry.id)
        defer { installing.remove(entry.id) }
        do {
            let folder: URL
            do {
                folder = try await catalog.fetchExtension(entry)
            } catch {
                guard let local = bundled?.appending(path: entry.folder, directoryHint: .isDirectory),
                      FileManager.default.fileExists(atPath: local.path) else { throw error }
                folder = local
            }
            try library.install(fromDirectory: folder)
            notice = nil
        } catch {
            notice = "安装失败：\(error.localizedDescription)"
        }
    }

    func iconURL(for entry: CatalogEntry) -> URL? {
        guard entry.icon.hasPrefix("file:") else { return nil }
        return bundled?.appending(path: entry.folder).appending(path: String(entry.icon.dropFirst(5)))
    }
}

struct ExtensionSettings: View {
    private enum Section: String, CaseIterable, Identifiable {
        case installed = "已安装"
        case market = "组件市场"
        var id: String { rawValue }
    }

    @Bindable var settings: AppSettings
    var library: ExtensionLibrary
    @Bindable var market: MarketModel
    var onAskAgent: () -> Void
    @State private var section = Section.installed

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .padding(.vertical, 10)
            switch section {
            case .installed:
                InstalledExtensions(settings: settings, library: library, onAskAgent: onAskAgent)
            case .market:
                ExtensionMarket(market: market)
            }
        }
        .task { await market.refresh() }
    }
}

private struct InstalledExtensions: View {
    @Bindable var settings: AppSettings
    var library: ExtensionLibrary
    var onAskAgent: () -> Void
    @State private var isTrusted = PasteSimulator.isTrusted

    var body: some View {
        Form {
            Section {
                Toggle("选中文本时显示浮条", isOn: $settings.selectionBarEnabled)
                Toggle("只在按住 ⌥ 选中时显示", isOn: $settings.selectionBarRequiresOption)
                Toggle("读不到文本时模拟拷贝", isOn: $settings.selectionBarFallbackCopy)
                    .help("部分应用不提供文字内容，开启后用 ⌘C 读取，随后恢复剪贴板，不会写入历史")
                if !isTrusted {
                    LabeledContent("需要辅助功能权限才能读取选中的文字") {
                        Button("开启…") { PasteSimulator.requestTrust() }
                    }
                }
            }
            Section {
                ForEach(library.installed) { item in
                    ExtensionRow(item: item, library: library)
                }
                .onMove { library.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("浮条上的组件")
            } footer: {
                HStack {
                    Text("拖动调整顺序。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("让 Agent 写一个", action: onAskAgent).controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isTrusted = PasteSimulator.isTrusted
        }
    }
}

private struct ExtensionRow: View {
    var item: InstalledExtension
    var library: ExtensionLibrary
    @State private var isExpanded = false

    private var hasOptions: Bool { !(item.manifest.options ?? []).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ExtensionIconView(icon: item.manifest.icon, fileURL: library.iconURL(for: item), size: 16)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.manifest.name.localized).font(.system(size: 13))
                    Text(item.manifest.description.localized).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if hasOptions {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderless)
                    .help("设置")
                }
                Toggle("", isOn: Binding(get: { item.isEnabled }, set: { library.setEnabled(item.id, $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if isExpanded {
                ForEach(item.manifest.options ?? []) { option in
                    OptionField(option: option, item: item, library: library)
                }
            }
        }
        .contextMenu {
            Button("移除", role: .destructive) { try? library.remove(item.id) }
        }
    }
}

private struct OptionField: View {
    var option: ExtensionOption
    var item: InstalledExtension
    var library: ExtensionLibrary
    @State private var value: String

    init(option: ExtensionOption, item: InstalledExtension, library: ExtensionLibrary) {
        self.option = option
        self.item = item
        self.library = library
        _value = State(initialValue: library.optionValues(for: item.id)[option.id] ?? "")
    }

    var body: some View {
        Group {
            switch option.type {
            case .string:
                TextField(option.label.localized, text: $value, prompt: option.placeholder.map { Text($0.localized) })
            case .boolean:
                Toggle(option.label.localized, isOn: Binding(get: { value == "true" }, set: { value = $0 ? "true" : "false" }))
            case .choice:
                Picker(option.label.localized, selection: $value) {
                    ForEach(option.choices ?? []) { Text($0.label.localized).tag($0.value) }
                }
            }
        }
        .font(.system(size: 12))
        .padding(.leading, 32)
        .onChange(of: value) { _, updated in
            library.setOption(item.id, option: option.id, value: updated)
        }
    }
}

private struct ExtensionMarket: View {
    @Bindable var market: MarketModel

    private let regions = [("all", "全部"), ("global", "通用"), ("us", "美国"), ("cn", "中国")]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                TextField("搜索组件", text: $market.search).textFieldStyle(.roundedBorder)
                Picker("", selection: $market.region) {
                    ForEach(regions, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden()
                .fixedSize()
                Button {
                    Task { await market.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(market.isLoading)
                .help("刷新")
            }
            .padding(.horizontal, 16)
            if let notice = market.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            List(market.visibleEntries) { entry in
                MarketRow(entry: entry, market: market)
            }
            .listStyle(.inset)
            .overlay {
                if market.visibleEntries.isEmpty, !market.isLoading {
                    ContentUnavailableView("没有找到组件", systemImage: "puzzlepiece.extension")
                }
            }
        }
    }
}

private struct MarketRow: View {
    var entry: CatalogEntry
    var market: MarketModel

    var body: some View {
        HStack(spacing: 10) {
            ExtensionIconView(icon: entry.icon, fileURL: market.iconURL(for: entry), size: 18)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name.localized).font(.system(size: 13))
                Text(entry.description.localized).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            action
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var action: some View {
        if market.installing.contains(entry.id) {
            ProgressView().controlSize(.small)
        } else {
            switch market.status(of: entry) {
            case .available:
                Button("安装") { Task { await market.install(entry) } }.controlSize(.small)
            case .updateAvailable:
                Button("更新") { Task { await market.install(entry) } }.controlSize(.small).buttonStyle(.borderedProminent)
            case .installed:
                Text("已安装").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
