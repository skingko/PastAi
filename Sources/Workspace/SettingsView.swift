import AppKit
import ClipAgent
import ClipCore
import ClipExtensions
import ServiceManagement
import SwiftUI

enum SettingsTab: Hashable {
    case general, extensions, privacy, models, storage
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var agent: AgentSettings
    var service: ClipService
    var library: ExtensionLibrary
    var market: MarketModel
    var onHotKeyChanged: (HotKeyCombo) -> Void
    var onAskAgent: () -> Void
    @Binding var tab: SettingsTab

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(settings: settings, onHotKeyChanged: onHotKeyChanged)
                .tabItem { Label("通用", systemImage: "gearshape") }.tag(SettingsTab.general)
            ExtensionSettings(settings: settings, library: library, market: market, onAskAgent: onAskAgent)
                .tabItem { Label("组件", systemImage: "puzzlepiece.extension") }.tag(SettingsTab.extensions)
            PrivacySettings(settings: settings)
                .tabItem { Label("隐私", systemImage: "hand.raised") }.tag(SettingsTab.privacy)
            ModelSettings(agent: agent)
                .tabItem { Label("AI 模型", systemImage: "sparkles") }.tag(SettingsTab.models)
            StorageSettings(service: service)
                .tabItem { Label("存储", systemImage: "internaldrive") }.tag(SettingsTab.storage)
        }
        .frame(width: 680, height: 580)
    }
}

private struct GeneralSettings: View {
    @Bindable var settings: AppSettings
    var onHotKeyChanged: (HotKeyCombo) -> Void
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            LabeledContent("唤出剪贴板") {
                HotKeyRecorder(combo: settings.hotKey) { combo in
                    settings.hotKey = combo
                    onHotKeyChanged(combo)
                }
            }
            Toggle("登录时启动", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Picker("保留历史", selection: $settings.retentionDays) {
                Text("7 天").tag(7)
                Text("30 天").tag(30)
                Text("90 天").tag(90)
                Text("1 年").tag(365)
                Text("永久").tag(0)
            }
            Text("Pinboard 里的内容不受影响，永远保留。删除的内容在回收站保留 30 天。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 8) {
                    ForEach(ClipKind.allCases) { kind in
                        Toggle(isOn: Binding(
                            get: { settings.pinnedKinds.contains(kind) },
                            set: { settings.setKind(kind, pinned: $0) }
                        )) {
                            Label(kind.displayName, systemImage: kind.symbolName)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            } header: {
                Text("固定为 Pinboard 的分类")
            } footer: {
                Text("勾选的分类会显示在面板标签栏里，排在你自建的 Pinboard 前面。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Click, then press the new shortcut. Requires at least one of Command, Option or Control.
private struct HotKeyRecorder: View {
    var combo: HotKeyCombo
    var onChange: (HotKeyCombo) -> Void
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(isRecording ? "按下新的快捷键…" : HotKeyFormatter.describe(combo)) {
            isRecording ? stop() : start()
        }
        .onDisappear { stop() }
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.isDisjoint(with: [.command, .option, .control]) {
                if event.keyCode == 53 { MainActor.assumeIsolated { stop() } }
                return nil
            }
            let captured = HotKeyCombo(keyCode: UInt32(event.keyCode), modifiers: HotKeyFormatter.carbonModifiers(flags))
            MainActor.assumeIsolated {
                onChange(captured)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}

private struct PrivacySettings: View {
    @Bindable var settings: AppSettings
    @State private var isTrusted = PasteSimulator.isTrusted

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        Form {
            Section("记录") {
                Toggle("暂停记录", isOn: Binding(get: { settings.isPaused }, set: { _ in settings.togglePause() }))
                Toggle("忽略密码管理器标记的机密内容", isOn: $settings.ignoreConcealed)
            }
            Section("不记录这些应用") {
                ForEach(settings.ignoredBundleIDs, id: \.self) { bundleID in
                    HStack {
                        Text(bundleID).lineLimit(1)
                        Spacer()
                        Button {
                            settings.ignoredBundleIDs.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Menu("添加正在运行的应用") {
                    ForEach(runningApps, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "") {
                            if let id = app.bundleIdentifier, !settings.ignoredBundleIDs.contains(id) {
                                settings.ignoredBundleIDs.append(id)
                            }
                        }
                    }
                }
            }
            Section("权限") {
                LabeledContent("辅助功能") {
                    if isTrusted {
                        Label("已开启", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("开启…") {
                            PasteSimulator.requestTrust()
                        }
                    }
                }
                Text("开启后回车可直接粘贴到当前应用。未开启时内容只写入剪贴板，需要手动按 ⌘V。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isTrusted = PasteSimulator.isTrusted
        }
    }
}

private struct ModelSettings: View {
    @Bindable var agent: AgentSettings
    @State private var selection: UUID?

    private var allModels: [ModelRef] {
        agent.providers.flatMap { provider in provider.models.map { ModelRef(providerID: provider.id, model: $0) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    List(agent.providers, selection: $selection) { provider in
                        Label(provider.name, systemImage: provider.isLocal ? "desktopcomputer" : "cloud")
                    }
                    Divider()
                    HStack {
                        Menu {
                            ForEach(ModelProvider.presets, id: \.name) { preset in
                                Button(preset.name) { add(preset) }
                            }
                            Divider()
                            Button("自定义") {
                                add(ModelProvider(name: "自定义", format: .openAICompatible, baseURL: "https://"))
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        Button {
                            if let provider = agent.providers.first(where: { $0.id == selection }) {
                                agent.remove(provider)
                                selection = nil
                            }
                        } label: {
                            Image(systemName: "minus")
                        }
                        .buttonStyle(.borderless)
                        .disabled(selection == nil)
                        Spacer()
                    }
                    .padding(6)
                }
                .frame(minWidth: 170, maxWidth: 200)

                if let index = agent.providers.firstIndex(where: { $0.id == selection }) {
                    ProviderEditor(provider: $agent.providers[index], agent: agent).id(selection)
                } else {
                    ContentUnavailableView("选择或添加一个服务", systemImage: "sparkles")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            Form {
                Picker("主模型", selection: $agent.mainModel) {
                    Text("未选择").tag(ModelRef?.none)
                    ForEach(allModels, id: \.self) { reference in
                        Text(label(reference)).tag(ModelRef?.some(reference))
                    }
                }
                Picker("批量任务模型", selection: $agent.lightModel) {
                    Text("与主模型相同").tag(ModelRef?.none)
                    ForEach(allModels, id: \.self) { reference in
                        Text(label(reference)).tag(ModelRef?.some(reference))
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 118)
            .scrollDisabled(true)
        }
        .onAppear {
            if selection == nil { selection = agent.providers.first?.id }
        }
    }

    private func label(_ reference: ModelRef) -> String {
        "\(reference.model)（\(agent.provider(for: reference)?.name ?? "")）"
    }

    private func add(_ preset: ModelProvider) {
        var provider = preset
        provider.id = UUID()
        agent.providers.append(provider)
        selection = provider.id
    }
}

private struct ProviderEditor: View {
    @Binding var provider: ModelProvider
    var agent: AgentSettings
    @State private var apiKey = ""
    @State private var newModel = ""
    @State private var fetchMessage = ""
    @State private var isFetching = false
    @State private var isTesting = false
    @State private var testResult: (text: String, isSuccess: Bool)?

    private var testModel: String? {
        provider.models.first { agent.mainModel?.model == $0 } ?? provider.models.first
    }

    var body: some View {
        Form {
            TextField("名称", text: $provider.name)
            Picker("接口格式", selection: $provider.format) {
                ForEach(ModelProvider.Format.allCases) { format in
                    Text(format.label).tag(format)
                }
            }
            TextField("Base URL", text: $provider.baseURL)
            SecureField("API Key", text: $apiKey)
                .onChange(of: apiKey) { _, value in
                    agent.keychain.save(value, account: provider.id.uuidString)
                }
            Toggle("模型支持看图", isOn: $provider.supportsVision)
            Section("模型") {
                ForEach(provider.models, id: \.self) { model in
                    HStack {
                        Text(model).lineLimit(1)
                        Spacer()
                        Button {
                            provider.models.removeAll { $0 == model }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("模型名称", text: $newModel).onSubmit(addModel)
                    Button("添加", action: addModel).disabled(newModel.isEmpty)
                    Button(isFetching ? "获取中…" : "获取列表", action: fetchModels).disabled(isFetching)
                }
                if !fetchMessage.isEmpty {
                    Text(fetchMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Button(isTesting ? "测试中…" : "测试连接", action: testConnection)
                        .disabled(isTesting || testModel == nil)
                    if let testModel {
                        Text(testModel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if let result = testResult {
                    Text(result.text)
                        .font(.caption)
                        .foregroundStyle(result.isSuccess ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                }
                if provider.baseURL.contains("/coding/") {
                    Text("这是 Coding Plan 专用地址。Coding Plan 通常只允许在官方支持的工具里使用，在 PastAi 中调用可能被拒绝，甚至影响套餐权益。建议改用按量计费的 API Key。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { apiKey = agent.keychain.read(provider.id.uuidString) ?? "" }
    }

    private func addModel() {
        let name = newModel.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !provider.models.contains(name) else { return }
        provider.models.append(name)
        newModel = ""
    }

    /// Sends one small request, and only when the button is pressed.
    private func testConnection() {
        guard let model = testModel else { return }
        isTesting = true
        testResult = nil
        let client = provider.makeClient(apiKey: apiKey)
        Task {
            defer { isTesting = false }
            do {
                let reply = try await ConnectionProbe.run(client: client, model: model)
                testResult = ("连接正常，模型回复：\(reply.isEmpty ? "（空）" : String(reply.prefix(60)))", true)
            } catch {
                testResult = (error.localizedDescription, false)
            }
        }
    }

    private func fetchModels() {
        isFetching = true
        fetchMessage = ""
        let client = provider.makeClient(apiKey: apiKey)
        Task {
            defer { isFetching = false }
            do {
                let models = try await client.listModels()
                provider.models = models
                fetchMessage = "找到 \(models.count) 个模型"
            } catch {
                fetchMessage = error.localizedDescription
            }
        }
    }
}

private struct StorageSettings: View {
    var service: ClipService
    @State private var stats: LibraryStats?
    @State private var diskBytes: Int64 = 0

    var body: some View {
        Form {
            LabeledContent("条目") { Text("\(stats?.total ?? 0)") }
            LabeledContent("占用空间") { Text(ByteCountFormatter.string(fromByteCount: diskBytes, countStyle: .file)) }
            LabeledContent("存储位置") {
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([service.paths.root])
                }
            }
        }
        .formStyle(.grouped)
        .task {
            stats = try? await service.stats()
            let root = service.paths.root
            diskBytes = await Task.detached { Self.directorySize(root) }.value
        }
    }

    private nonisolated static func directorySize(_ root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
