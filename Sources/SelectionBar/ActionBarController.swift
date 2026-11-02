import AppKit
import ClipCore
import ClipExtensions
import SwiftUI

public typealias AIActionHandler = @MainActor (AIActionRequest) -> AsyncThrowingStream<String, any Error>

/// The floating bar for selected text and the small result popover it opens.
@MainActor
public final class ActionBarController {
    private let library: ExtensionLibrary
    private let capture: CaptureService?
    private let monitor: SelectionMonitor
    private let scripts: SandboxedScriptRunner
    private let pasteboard: NSPasteboard
    private let simulatesKeys: Bool

    private let barModel = ActionBarModel()
    private let resultModel = ResultModel()
    private let bar: NonActivatingPanel
    private let barHost: NSView
    private let result: NonActivatingPanel
    private let resultHost: NSView

    private var context: SelectionContext?
    private var aiTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var pendingAI: (item: InstalledExtension, request: AIActionRequest)?

    /// Replaced in scripted runs so testing an action does not open pages in the real browser.
    public var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    public var runAI: AIActionHandler?
    public var grantAIConsent: (() -> Void)?
    public var openModelSettings: (() -> Void)?
    public var openExtensionSettings: (() -> Void)?

    /// `pasteboard` and `simulatesKeys` exist so scripted UI runs cannot touch the real clipboard or apps.
    public init(
        library: ExtensionLibrary,
        settings: AppSettings,
        capture: CaptureService?,
        scripts: SandboxedScriptRunner,
        pasteboard: NSPasteboard = .general,
        simulatesKeys: Bool = true
    ) {
        self.library = library
        self.capture = capture
        self.scripts = scripts
        self.pasteboard = pasteboard
        self.simulatesKeys = simulatesKeys
        monitor = SelectionMonitor(settings: settings, capture: capture)
        (bar, barHost) = NonActivatingPanel.make(content: ActionBarView(model: barModel))
        (result, resultHost) = NonActivatingPanel.make(content: ResultView(model: resultModel))

        barModel.iconURL = { [library] in library.iconURL(for: $0) }
        barModel.onTap = { [weak self] in self?.perform($0) }
        barModel.onOverflow = { [weak self] in self?.showOverflow(from: $0) }
        resultModel.onClose = { [weak self] in self?.dismissAll() }
        resultModel.onInsert = { [weak self] in self?.insertResult() }
        resultModel.onConsent = { [weak self] in self?.consentAndRetry() }

        monitor.onSelection = { [weak self] in self?.present($0) }
        monitor.onDismiss = { [weak self] in self?.dismissAll() }
    }

    public func start() { monitor.start() }
    public func stop() { monitor.stop() }

    // MARK: Presenting

    public func present(_ selection: SelectionContext) {
        let input = SelectionInput(text: selection.text, appBundleID: selection.appBundleID, isEditable: selection.isEditable)
        let items = library.actions(for: input)
        guard !items.isEmpty else { return }
        dismissAll()
        context = selection
        barModel.items = items
        barModel.confirmedID = nil
        barHost.layoutSubtreeIfNeeded()
        let size = barHost.fittingSize
        bar.setFrame(NSRect(origin: Self.origin(for: size, above: selection.anchor, gap: 12), size: size), display: true)
        bar.orderFrontRegardless()
    }

    /// Centres on the pointer above the selection, moving below it near the top of the screen.
    private static func origin(for size: NSSize, above anchor: CGPoint, gap: CGFloat) -> NSPoint {
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let bounds = screen.visibleFrame
        var origin = NSPoint(x: anchor.x - size.width / 2, y: anchor.y + gap)
        if origin.y + size.height > bounds.maxY { origin.y = anchor.y - gap - size.height - 8 }
        origin.x = min(max(origin.x, bounds.minX + 6), bounds.maxX - size.width - 6)
        origin.y = max(origin.y, bounds.minY + 6)
        return origin
    }

    public func dismissAll() {
        aiTask?.cancel()
        aiTask = nil
        hideTask?.cancel()
        pendingAI = nil
        bar.orderOut(nil)
        result.orderOut(nil)
        context = nil
    }

    private func showOverflow(from view: NSView) {
        let menu = NSMenu()
        for item in barModel.overflow {
            let entry = OverflowItem(title: item.manifest.name.localized) { [weak self] in self?.perform(item) }
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    private func showResult() {
        bar.orderOut(nil)
        layoutResult()
        result.orderFrontRegardless()
    }

    /// Grows upward from a fixed bottom edge, so text streaming in does not make the popover jump.
    private func layoutResult() {
        guard let anchor = context?.anchor else { return }
        resultHost.layoutSubtreeIfNeeded()
        let size = resultHost.fittingSize
        let bottom = Self.origin(for: NSSize(width: size.width, height: 1), above: anchor, gap: 12)
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.screens[0]
        let y = min(bottom.y, screen.visibleFrame.maxY - size.height - 6)
        result.setFrame(NSRect(x: bottom.x, y: max(y, screen.visibleFrame.minY + 6), width: size.width, height: size.height), display: true)
    }

    private func configureResult(for item: InstalledExtension) {
        resultModel.title = item.manifest.name.localized
        resultModel.icon = item.manifest.icon
        resultModel.iconURL = library.iconURL(for: item)
        resultModel.text = ""
        resultModel.phase = .working
        resultModel.isOnClipboard = false
        resultModel.canInsert = false
        resultModel.onOpenSettings = nil
    }

    private func showMessage(_ text: String, for item: InstalledExtension, settings: (() -> Void)? = nil) {
        configureResult(for: item)
        resultModel.phase = .message(text)
        resultModel.onOpenSettings = settings
        showResult()
    }

    // MARK: Actions

    private func perform(_ item: InstalledExtension) {
        guard let context else { return }
        if let missing = library.missingOption(for: item) {
            let reason = ExtensionError.missingOption(missing.label).errorDescription ?? ""
            showMessage(reason, for: item) { [weak self] in
                self?.dismissAll()
                self?.openExtensionSettings?()
            }
            return
        }
        let options = library.optionValues(for: item.id)
        do {
            switch item.manifest.action {
            case .copy:
                writeToClipboard(context.text)
                confirm(item)
            case .paste:
                dismissAll()
                paste()
            case .url(let template, let fallback, let returnKeyOption):
                try open(template: template, fallback: fallback, text: context.text, options: options)
                let wantsReturn = returnKeyOption.map { options[$0] == "true" } ?? false
                dismissAll()
                if wantsReturn { pressReturnInNewFrontApp() }
            case .app(let bundleID, let copyFirst):
                try openApp(bundleID: bundleID, copyFirst: copyFirst, text: context.text, item: item)
            case .script(let file):
                runScript(item, file: file, text: context.text, options: options)
            case .ai(let system, let prompt):
                let request = AIActionRequest(system: system, prompt: TemplateRenderer.prompt(prompt, text: context.text, options: options))
                runAIAction(item, request: request, canInsert: context.isEditable)
            }
        } catch {
            showMessage(error.localizedDescription, for: item)
        }
    }

    private func confirm(_ item: InstalledExtension) {
        barModel.confirmedID = item.id
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.dismissAll()
        }
    }

    private func writeToClipboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func paste() {
        guard simulatesKeys else { return }
        PasteSimulator.pasteToFrontmostApp()
    }

    private func open(template: String, fallback: String?, text: String, options: [String: String]) throws {
        let url = try TemplateRenderer.url(template, text: text, options: options)
        // A custom scheme with no app behind it would otherwise fail silently.
        if NSWorkspace.shared.urlForApplication(toOpen: url) == nil, let fallback {
            openURL(try TemplateRenderer.url(fallback, text: text, options: options))
        } else {
            openURL(url)
        }
    }

    private func openApp(bundleID: String, copyFirst: Bool, text: String, item: InstalledExtension) throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            showMessage("没有找到 \(item.manifest.name.localized)，请先安装。", for: item)
            return
        }
        if copyFirst { writeToClipboard(text) }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        dismissAll()
    }

    /// Sends a drafted message: waits for the target app to come forward, then presses Return.
    /// Gives up rather than guess if it never does, because Return in the wrong app is worse than a click.
    private func pressReturnInNewFrontApp() {
        guard simulatesKeys else { return }
        let previous = NSWorkspace.shared.frontmostApplication?.processIdentifier
        Task {
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(100))
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier != previous else { continue }
                try? await Task.sleep(for: .milliseconds(900))
                PasteSimulator.pressReturn()
                return
            }
        }
    }

    private func runScript(_ item: InstalledExtension, file: String, text: String, options: [String: String]) {
        let source: String
        do {
            source = try library.script(for: item, file: file)
        } catch {
            showMessage(error.localizedDescription, for: item)
            return
        }
        let scripts = scripts
        Task { [weak self] in
            do {
                let output = try await scripts.run(source: source, input: ScriptInput(text: text, options: options))
                self?.apply(output, item: item, options: options)
            } catch {
                self?.showMessage(error.localizedDescription, for: item)
            }
        }
    }

    private func apply(_ output: ScriptOutput, item: InstalledExtension, options: [String: String]) {
        if let copy = output.copy { writeToClipboard(copy) }
        if let open = output.open, let url = try? TemplateRenderer.url(open, text: "", options: options) {
            openURL(url)
        }
        if let replacement = output.replace {
            replaceSelection(with: replacement)
            dismissAll()
        } else if let show = output.show {
            configureResult(for: item)
            resultModel.text = show
            resultModel.phase = .done
            resultModel.isOnClipboard = output.copy != nil
            showResult()
        } else if output.copy != nil {
            confirm(item)
        } else {
            dismissAll()
        }
    }

    /// Borrows the clipboard for one paste and puts it back, leaving no trace in the history.
    private func replaceSelection(with text: String) {
        guard simulatesKeys else {
            writeToClipboard(text)
            return
        }
        let restorePoint = PasteboardRestorePoint(pasteboard: pasteboard)
        capture?.isSuspended = true
        writeToClipboard(text)
        paste()
        Task { [capture] in
            try? await Task.sleep(for: .milliseconds(350))
            restorePoint.restore()
            capture?.acknowledgeCurrentContents()
            capture?.isSuspended = false
        }
    }

    // MARK: AI

    private func runAIAction(_ item: InstalledExtension, request: AIActionRequest, canInsert: Bool) {
        guard let runAI else { return }
        configureResult(for: item)
        pendingAI = (item, request)
        showResult()
        aiTask = Task { [weak self] in
            do {
                for try await delta in runAI(request) {
                    guard let self else { return }
                    self.resultModel.text += delta
                    self.layoutResult()
                }
                guard let self, !Task.isCancelled else { return }
                self.finishAI(canInsert: canInsert)
            } catch is CancellationError {
                return
            } catch {
                self?.failAI(error)
            }
        }
    }

    private func finishAI(canInsert: Bool) {
        let text = resultModel.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            resultModel.phase = .failed("模型没有返回内容。")
            layoutResult()
            return
        }
        resultModel.text = text
        writeToClipboard(text)
        resultModel.isOnClipboard = true
        resultModel.canInsert = canInsert
        resultModel.phase = .done
        layoutResult()
    }

    private func failAI(_ error: any Error) {
        switch error as? AIActionError {
        case .notConfigured:
            resultModel.phase = .message("先在设置里添加一个模型，才能使用 AI 组件。")
            resultModel.onOpenSettings = { [weak self] in self?.openSettingsFromResult() }
        case .needsConsent(let provider):
            resultModel.phase = .needsConsent(provider)
        case nil:
            resultModel.phase = .failed(error.localizedDescription)
            resultModel.onOpenSettings = { [weak self] in self?.openSettingsFromResult() }
        }
        layoutResult()
    }

    private func openSettingsFromResult() {
        dismissAll()
        openModelSettings?()
    }

    private func consentAndRetry() {
        guard let pendingAI, let context else { return }
        grantAIConsent?()
        runAIAction(pendingAI.item, request: pendingAI.request, canInsert: context.isEditable)
    }

    private func insertResult() {
        let text = resultModel.text
        dismissAll()
        // Written again in case something else took the clipboard while the popover was open.
        writeToClipboard(text)
        paste()
    }

    #if DEBUG
    public func debugPresent(text: String, editable: Bool) {
        present(SelectionContext(text: text, appBundleID: "com.apple.TextEdit", isEditable: editable, anchor: NSEvent.mouseLocation))
    }

    public func debugPerform(_ id: String) {
        if let item = barModel.items.first(where: { $0.id == id }) { perform(item) }
    }

    public var debugBarWindow: NSWindow { bar }

    public var debugResultWindow: NSWindow { result }

    public func debugState() -> [String: Any] {
        [
            "barVisible": bar.isVisible,
            "barItems": barModel.items.map(\.id),
            "resultVisible": result.isVisible,
            "resultText": resultModel.text,
            "resultPhase": String(describing: resultModel.phase),
            "resultCanInsert": resultModel.canInsert,
            "resultOnClipboard": resultModel.isOnClipboard,
        ]
    }
    #endif
}

private final class OverflowItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used from a nib") }

    @objc @MainActor private func fire() { handler() }
}
