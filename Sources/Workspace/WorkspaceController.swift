import AppKit
import ClipAgent
import ClipCore
import ClipExtensions
import Observation
import SwiftUI

/// The main window and settings. Everything AI lives behind this type, so the quick panel never links it.
@MainActor
public final class WorkspaceController: NSObject, NSWindowDelegate {
    private let service: ClipService
    private let settings: AppSettings
    private let agentSettings: AgentSettings
    private let library: LibraryModel
    private let agent: AgentModel
    private let extensions: ExtensionLibrary
    private let market: MarketModel
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private let navigation = SettingsNavigation()

    public var onHotKeyChanged: ((HotKeyCombo) -> Void)?

    public init(
        service: ClipService,
        settings: AppSettings,
        extensions: ExtensionLibrary,
        scripts: SandboxedScriptRunner,
        catalog: ExtensionCatalog = ExtensionCatalog(),
        bundledExtensions: URL? = nil,
        agentDefaults: UserDefaults = .standard
    ) {
        self.service = service
        self.settings = settings
        self.extensions = extensions
        agentSettings = AgentSettings(defaults: agentDefaults)
        library = LibraryModel(service: service)
        market = MarketModel(library: extensions, catalog: catalog, bundled: bundledExtensions)
        agent = AgentModel(service: service, settings: agentSettings, extensions: Self.access(to: extensions, scripts: scripts))
        super.init()
        agent.onOpenModelSettings = { [weak self] in self?.showSettings(tab: .models) }
    }

    public func showLibrary() {
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1240, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "PastAi"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: WorkspaceView(library: library, agent: agent))
            window.setFrameAutosaveName("PastAiMain")
            window.delegate = self
            window.center()
            mainWindow = window
        }
        present(mainWindow)
    }

    public func showSettings() {
        showSettings(tab: navigation.tab)
    }

    public func showExtensionSettings() { showSettings(tab: .extensions) }

    public func showModelSettings() { showSettings(tab: .models) }

    private static func access(to library: ExtensionLibrary, scripts: SandboxedScriptRunner) -> ExtensionAccess {
        ExtensionAccess(
            list: {
                await MainActor.run {
                    library.installed.map { item in
                        ExtensionSummary(
                            id: item.id, name: item.manifest.name.localized, version: item.manifest.version, isEnabled: item.isEnabled,
                            isLocal: item.manifest.isLocal, summary: ExtensionValidator.describe(item.manifest.action)
                        )
                    }
                }
            },
            install: { manifest, script in
                try await MainActor.run { _ = try library.installLocal(manifest, script: script) }
            },
            remove: { id in
                try await MainActor.run { try library.remove(id) }
            },
            runScript: { source, input in
                try await scripts.run(source: source, input: input)
            }
        )
    }

    /// Runs an AI extension with the batch model, which suits short one-shot prompts, or else the main model.
    public func runAIAction(_ request: AIActionRequest) -> AsyncThrowingStream<String, any Error> {
        let reference = agentSettings.lightModel ?? agentSettings.mainModel
        guard let reference, let provider = agentSettings.provider(for: reference), let client = agentSettings.client(for: reference) else {
            return AsyncThrowingStream { $0.finish(throwing: AIActionError.notConfigured) }
        }
        if !provider.isLocal, !agentSettings.cloudConsent.contains(provider.id) {
            return AsyncThrowingStream { $0.finish(throwing: AIActionError.needsConsent(providerName: provider.name)) }
        }
        let llmRequest = LLMRequest(
            model: reference.model, system: request.system ?? "",
            messages: [LLMMessage(role: .user, text: request.prompt)], effort: .low, maxTokens: 8_000
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in client.stream(llmRequest) {
                        switch event {
                        case .textDelta(let delta): continuation.yield(delta)
                        case .stopped(.refusal): throw LLMError.invalidResponse("模型拒绝处理这段内容")
                        default: break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func grantAIConsent() {
        let reference = agentSettings.lightModel ?? agentSettings.mainModel
        if let provider = agentSettings.provider(for: reference) { agentSettings.cloudConsent.insert(provider.id) }
    }

    private func askAgentForExtension() {
        agent.composer = "帮我写一个浮条组件："
        showLibrary()
    }

    func showSettings(tab: SettingsTab) {
        navigation.tab = tab
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 580),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "PastAi 设置"
            window.isReleasedWhenClosed = false
            let view = SettingsHost(
                settings: settings, agent: agentSettings, service: service, library: extensions, market: market, navigation: navigation,
                onHotKeyChanged: { [weak self] combo in self?.onHotKeyChanged?(combo) },
                onAskAgent: { [weak self] in self?.askAgentForExtension() }
            )
            window.contentView = NSHostingView(rootView: view)
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        present(settingsWindow)
    }

    /// Hands selected clips over from the quick panel as attachments on the next message.
    public func sendToAgent(_ ids: [Int64]) {
        showLibrary()
        agent.attach(ids)
    }

    /// An accessory app has no Dock icon and cannot own regular windows properly, so it is
    /// promoted while one is open and goes back when the last closes.
    private func present(_ window: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        let stillOpen = [mainWindow, settingsWindow].contains { $0 != nil && $0 !== closing && $0?.isVisible == true }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }

    #if DEBUG
    public func debugSend(_ text: String) {
        agent.composer = text
        agent.send()
    }

    public func debugResolve(approve: Bool, session: Bool = false) {
        for item in agent.items {
            if case .proposal(_, let proposal, .pending) = item {
                agent.resolve(proposal, decision: approve ? (session ? .approvedForSession : .approved) : .rejected(reason: nil))
            }
        }
    }

    public func debugUndoLast() {
        for item in agent.items.reversed() {
            if case .undo(_, let batch, false) = item {
                agent.undo(batchID: batch)
                return
            }
        }
    }

    public func debugSelect(_ ids: [Int64]) { library.selection = Set(ids) }

    public func debugRetry() { agent.retry() }

    public func debugMarketRefresh() { Task { await market.refresh() } }

    public func debugMarketInstall(_ folder: String) {
        Task {
            await market.refresh()
            if let entry = market.entries.first(where: { $0.folder == folder }) { await market.install(entry) }
        }
    }

    public func debugAttach(_ ids: [Int64]) { agent.attach(ids) }

    public func debugNewSession() { agent.newSession() }

    public func debugSection(_ name: String) {
        switch name {
        case "trash": library.section = .trash
        case "image": library.section = .kind(.image)
        default: library.section = .all
        }
    }

    public func debugSettingsTab(_ name: String) {
        showSettings(tab: ["general": .general, "extensions": .extensions, "privacy": .privacy, "models": .models, "storage": .storage][name] ?? .general)
    }

    /// Text inputs in the window with their positions, for layout problems a snapshot cannot explain.
    public func debugFields() -> [String] {
        var found: [String] = []
        func walk(_ view: NSView) {
            if view is NSTextField || view is NSTextView {
                let frame = view.convert(view.bounds, to: nil)
                found.append("\(type(of: view)) x=\(Int(frame.minX)) y=\(Int(frame.minY)) w=\(Int(frame.width)) h=\(Int(frame.height))")
            }
            view.subviews.forEach(walk)
        }
        mainWindow?.contentView.map(walk)
        let window = mainWindow?.frame.size ?? .zero
        return ["window \(Int(window.width))x\(Int(window.height))"] + found
    }

    /// Every table in the window, for checking what is really laid out when a snapshot cannot show it.
    public func debugTables() -> [String] {
        var found: [String] = []
        func walk(_ view: NSView) {
            if let table = view as? NSTableView {
                let frame = table.convert(table.bounds, to: nil)
                var rows: [String] = []
                for index in 0..<min(table.numberOfRows, 4) {
                    let text = table.rowView(atRow: index, makeIfNecessary: true).map { describe($0) } ?? ""
                    rows.append(text)
                }
                found.append("\(type(of: table)) rows=\(table.numberOfRows) x=\(Int(frame.minX)) w=\(Int(frame.width)) hidden=\(table.isHiddenOrHasHiddenAncestor) alpha=\(table.alphaValue) \(rows)")
            }
            view.subviews.forEach(walk)
        }
        func describe(_ view: NSView) -> String {
            "\(view.accessibilityRole()?.rawValue ?? "")#\(view.subviews.count)@\(Int(view.frame.height))"
        }
        mainWindow?.contentView.map(walk)
        return found
    }

    /// Draws the window from inside the app, which works even when the screen is locked.
    public func debugSnapshot(window name: String, to path: String) {
        guard let view = (name == "settings" ? settingsWindow : mainWindow)?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    public func debugConfigure(baseURL: String, model: String) {
        let provider = ModelProvider(name: "本地测试", format: .openAICompatible, baseURL: baseURL, models: [model], supportsVision: false)
        agentSettings.providers = [provider]
        agentSettings.mainModel = ModelRef(providerID: provider.id, model: model)
    }

    public func debugState() -> [String: Any] {
        var transcript: [String] = []
        for item in agent.items {
            switch item {
            case .user(_, let text): transcript.append("user: \(text)")
            case .assistant(_, let text): transcript.append("assistant: \(text)")
            case .tool(_, _, let name, _, _, let state): transcript.append("tool: \(name) \(state)")
            case .proposal(_, let proposal, let state): transcript.append("proposal: \(proposal.summary) \(state)")
            case .note(_, let text): transcript.append("note: \(text)")
            case .failure(_, let failure): transcript.append("failure: \(failure.title) | \(failure.detail ?? "")")
            case .undo(_, _, let undone): transcript.append("undo: \(undone)")
            }
        }
        return [
            "agentRunning": agent.isRunning,
            "agentStatus": agent.status,
            "transcript": transcript,
            "sessions": agent.sessions.map(\.title),
            "tokens": [agent.tokens.input, agent.tokens.output],
            "libraryCount": library.clips.count,
            "pinboardNames": library.pinboards.map(\.name),
            "tables": debugTables(),
            "marketCount": market.entries.count,
            "marketNotice": market.notice ?? "",
            "installedExtensions": extensions.installed.map { "\($0.id)@\($0.manifest.version)" },
            "fields": debugFields(),
        ]
    }
    #endif
}

/// Lives outside the view so opening settings on a specific tab also works when the window is already up.
@MainActor
@Observable
final class SettingsNavigation {
    var tab = SettingsTab.general
}

private struct SettingsHost: View {
    var settings: AppSettings
    var agent: AgentSettings
    var service: ClipService
    var library: ExtensionLibrary
    var market: MarketModel
    @Bindable var navigation: SettingsNavigation
    var onHotKeyChanged: (HotKeyCombo) -> Void
    var onAskAgent: () -> Void

    var body: some View {
        SettingsView(
            settings: settings, agent: agent, service: service, library: library, market: market,
            onHotKeyChanged: onHotKeyChanged, onAskAgent: onAskAgent, tab: $navigation.tab
        )
    }
}
