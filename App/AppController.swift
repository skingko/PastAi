import AppKit
import ClipCore
import ClipEnrich
import ClipExtensions
import QuickPanel
import SelectionBar
import Workspace

/// Composition root: creates every service and wires them together. Holds no feature logic.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var settings: AppSettings!
    private var service: ClipService!
    private var capture: CaptureService!
    private var enrichment: EnrichmentPipeline!
    private var panel: QuickPanelController!
    private var workspace: WorkspaceController!
    private var extensions: ExtensionLibrary!
    private var selectionBar: ActionBarController!
    private let hotKey = GlobalHotKey()
    private var statusItem: NSStatusItem?
    private var retentionTimer: Timer?
    #if DEBUG
    private var driver: DevDriver?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let paths = try developerLibrary().map(AppPaths.init(root:)) ?? AppPaths.applicationSupport()
            service = try ClipService(paths: paths)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "无法打开 PastAi 资料库"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let scripted = CommandLine.arguments.contains("--no-capture")
        // Real selection testing: a scripted run that still watches the mouse and uses the real clipboard.
        let watchesSelection = CommandLine.arguments.contains("--watch-selection")
        // Scripted runs keep their preferences apart so they cannot change a real installation's settings.
        let defaults = scripted ? UserDefaults(suiteName: "io.github.skingko.pastai.scripted")! : UserDefaults.standard
        settings = AppSettings(defaults: defaults)
        enrichment = EnrichmentPipeline(service: service)
        capture = CaptureService(service: service, settings: settings)
        capture.onCaptured = { [enrichment] id in
            Task { await enrichment?.enqueue(id) }
        }

        let pasteboard = scripted && !watchesSelection ? NSPasteboard(name: .init("io.github.skingko.pastai.scripted")) : NSPasteboard.general
        panel = QuickPanelController(service: service, settings: settings, pasteboard: pasteboard, simulatesPaste: !scripted)
        let bundledExtensions = Bundle.main.resourceURL?.appending(path: "extensions", directoryHint: .isDirectory)
        extensions = ExtensionLibrary(paths: service.paths)
        if let bundledExtensions { extensions.seedDefaults(from: bundledExtensions) }
        let scripts = SandboxedScriptRunner(executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        workspace = WorkspaceController(
            service: service, settings: settings, extensions: extensions, scripts: scripts,
            catalog: developerMarket().map { ExtensionCatalog(baseURL: $0) } ?? ExtensionCatalog(),
            bundledExtensions: bundledExtensions, agentDefaults: defaults
        )
        selectionBar = ActionBarController(
            library: extensions, settings: settings, capture: capture, scripts: scripts,
            pasteboard: pasteboard, simulatesKeys: !scripted || watchesSelection
        )
        selectionBar.runAI = { [weak self] request in
            self?.workspace.runAIAction(request) ?? AsyncThrowingStream { $0.finish() }
        }
        selectionBar.grantAIConsent = { [weak self] in self?.workspace.grantAIConsent() }
        selectionBar.openModelSettings = { [weak self] in self?.workspace.showModelSettings() }
        selectionBar.openExtensionSettings = { [weak self] in self?.workspace.showExtensionSettings() }
        workspace.onHotKeyChanged = { [weak self] combo in self?.registerHotKey(combo) }

        panel.onOpenMainWindow = { [weak self] in self?.workspace.showLibrary() }
        panel.onOpenSettings = { [weak self] in self?.workspace.showSettings() }
        panel.onSendToAgent = { [weak self] ids in self?.workspace.sendToAgent(ids) }

        panel.prewarm()
        installMainMenu()
        // A scripted run sits alongside the installed app, so it must not claim the hotkey or the menu bar.
        if !scripted {
            hotKey.onPress = { [weak self] in self?.panel.toggle() }
            registerHotKey(settings.hotKey)
            installStatusItem()
            warnIfPasteboardBlocked()
        }

        if !scripted { capture.start() }
        if !scripted || watchesSelection { selectionBar.start() }
        Task { await enrichment.backfill() }
        scheduleRetention()
        handleLaunchArguments()
        #if DEBUG
        driver = DevDriver(panel: panel, workspace: workspace, bar: selectionBar, settings: settings, pasteboard: pasteboard)
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        workspace.showLibrary()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func registerHotKey(_ combo: HotKeyCombo) {
        if !hotKey.register(combo) {
            let alert = NSAlert()
            alert.messageText = "快捷键 \(HotKeyFormatter.describe(combo)) 已被占用"
            alert.informativeText = "请在设置里换一个，或者从菜单栏图标打开剪贴板。"
            alert.runModal()
        }
    }

    /// macOS asks per app whether it may read the pasteboard. If access was denied nothing would be
    /// captured and the app would just look broken, so say so up front.
    private func warnIfPasteboardBlocked() {
        guard NSPasteboard.general.accessBehavior == .alwaysDeny else { return }
        let alert = NSAlert()
        alert.messageText = "PastAi 无法读取剪贴板"
        alert.informativeText = "请在 系统设置 › 隐私与安全性 › 粘贴 中允许 PastAi 访问，否则不会记录任何内容。"
        alert.runModal()
    }

    private func scheduleRetention() {
        runRetention()
        let timer = Timer(timeInterval: 3_600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runRetention() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retentionTimer = timer
    }

    private func runRetention() {
        let policy = settings.retentionPolicy
        let service = service!
        Task.detached(priority: .background) { try? await service.runRetention(policy) }
    }

    /// `--library <dir>` points at a throwaway library so UI testing never touches real history.
    private func developerLibrary() -> URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--library"), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    /// `--market <url>` reads the extension catalog from a test server instead of GitHub.
    private func developerMarket() -> URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--market"), arguments.indices.contains(index + 1) else { return nil }
        return URL(string: arguments[index + 1])
    }

    /// Developer switches for driving the UI from scripts; normal launches pass none of these.
    private func handleLaunchArguments() {
        let arguments = CommandLine.arguments
        if arguments.contains("--show-panel") { panel.show() }
        if arguments.contains("--show-library") { workspace.showLibrary() }
        if arguments.contains("--show-settings") { workspace.showSettings() }
    }

    // MARK: Menus

    /// An accessory app shows no menu bar, but text fields still resolve Cut, Copy and Paste through it.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 PastAi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "PastAi")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Rebuilt on open so the pause title and the hotkey hint are always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = menu.addItem(withTitle: "打开剪贴板 (\(HotKeyFormatter.describe(settings.hotKey)))", action: #selector(togglePanel), keyEquivalent: "")
        open.target = self
        menu.addItem(withTitle: "打开主窗口", action: #selector(openLibrary), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: settings.isPaused ? "继续记录" : "暂停记录", action: #selector(togglePause), keyEquivalent: "").target = self
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 PastAi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }

    @objc private func togglePanel() { panel.toggle() }
    @objc private func openLibrary() { workspace.showLibrary() }
    @objc private func openSettings() { workspace.showSettings() }

    @objc private func togglePause() {
        settings.togglePause()
        statusItem?.button?.image = NSImage(
            systemSymbolName: settings.isPaused ? "pause.circle" : "doc.on.clipboard",
            accessibilityDescription: "PastAi"
        )
    }
}
