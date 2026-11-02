import AppKit
import Carbon.HIToolbox
import ClipCore
import QuickLookUI
import SwiftUI

/// A key panel that never activates PastAi, so the app being pasted into stays frontmost throughout.
private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
public final class QuickPanelController: NSObject, NSWindowDelegate {
    static let height: CGFloat = 330

    public let model: PanelModel
    private let service: ClipService
    private let writer: PasteWriter
    private let panel: FloatingPanel
    private let quickLook: QuickLookController
    private lazy var editor = ClipEditorController(service: service)
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var isHiding = false
    private let simulatesPaste: Bool

    public var onSendToAgent: (([Int64]) -> Void)?
    public var onOpenMainWindow: (() -> Void)?
    public var onOpenSettings: (() -> Void)?

    public var isVisible: Bool { panel.isVisible }

    /// `pasteboard` and `simulatesPaste` exist so scripted UI runs cannot clobber the real clipboard.
    public init(service: ClipService, settings: AppSettings, pasteboard: NSPasteboard = .general, simulatesPaste: Bool = true) {
        self.service = service
        self.simulatesPaste = simulatesPaste
        writer = PasteWriter(service: service, pasteboard: pasteboard)
        model = PanelModel(service: service, settings: settings)
        quickLook = QuickLookController(service: service)
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        configureActions()
        installMonitors()
    }

    /// Lays the panel out once at launch so the first hotkey press is as fast as every later one.
    public func prewarm() {
        panel.setFrame(Self.targetFrame(), display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        panel.animationBehavior = .none

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.cornerCurve = .continuous
        effect.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        effect.layer?.masksToBounds = true

        let host = NSHostingView(rootView: PanelRootView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
    }

    private func configureActions() {
        model.actions = PanelActions(
            paste: { [weak self] ids, mode in self?.paste(ids, mode: mode) },
            hide: { [weak self] in self?.hide() },
            edit: { [weak self] id in self?.edit(id) },
            quickLook: { [weak self] id in self?.toggleQuickLook(id) },
            sendToAgent: { [weak self] ids in
                self?.hide()
                self?.onSendToAgent?(ids)
            },
            openMainWindow: { [weak self] in
                self?.hide()
                self?.onOpenMainWindow?()
            },
            openSettings: { [weak self] in
                self?.hide()
                self?.onOpenSettings?()
            },
            newText: { [weak self] in self?.newText() },
            quit: { NSApp.terminate(nil) }
        )
    }

    // MARK: Show and hide

    public func toggle() {
        panel.isVisible ? hide() : show()
    }

    public func show() {
        guard !panel.isVisible else { return }
        let target = Self.targetFrame()
        model.prepareForShow()
        // Starts fully below the screen edge so it slides up from the bottom.
        panel.setFrame(target.offsetBy(dx: 0, dy: -target.height), display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        focusSearchField()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    public func hide() {
        guard panel.isVisible, !isHiding else { return }
        isHiding = true
        quickLook.close()
        panel.orderOut(nil)
        isHiding = false
    }

    private static func targetFrame() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        // The full frame rather than visibleFrame: the panel sits on the screen edge and covers the Dock,
        // which its window level already sits above.
        let frame = screen.frame
        return NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: height)
    }

    private func focusSearchField() {
        guard let field = Self.findField(in: panel.contentView) else { return }
        panel.makeFirstResponder(field)
    }

    private static func findField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.identifier?.rawValue == "panel-search" { return field }
        for subview in view.subviews {
            if let found = findField(in: subview) { return found }
        }
        return nil
    }

    public func windowDidResignKey(_ notification: Notification) {
        // Key status moves in two steps, so the new key window is only known on the next turn of the run loop.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow else { return }
            // Quick Look and popovers take key status from inside our own process; only leaving dismisses.
            if self.quickLook.isVisible { return }
            if let key = NSApp.keyWindow, key is NSPanel || key.className.contains("Popover") { return }
            self.hide()
        }
    }

    // MARK: Paste

    private func paste(_ ids: [Int64], mode: PasteWriter.Mode) {
        guard !ids.isEmpty else { return }
        Task {
            var details: [ClipDetail] = []
            for id in ids {
                if let detail = try? await service.detail(id: id) { details.append(detail) }
            }
            do {
                guard try writer.write(details, mode: mode) > 0 else { return }
            } catch {
                if error is MissingFilesError { model.showNotice(error.localizedDescription) }
                return
            }
            hide()
            // Last to first, so a multi-selection keeps its order at the front of the history.
            for id in ids.reversed() { try? await service.recordUse(clipID: id) }
            guard simulatesPaste else { return }
            // The target app needs a moment to take key focus back from the panel before it sees Cmd-V.
            try? await Task.sleep(for: .milliseconds(60))
            if !PasteSimulator.pasteToFrontmostApp() {
                PasteSimulator.requestTrust()
            }
        }
    }

    private func edit(_ id: Int64) {
        hide()
        editor.open(clipID: id)
    }

    private func newText() {
        hide()
        editor.openNew()
    }

    private func toggleQuickLook(_ id: Int64) {
        quickLook.toggle(clipID: id, above: panel.level)
    }

    // MARK: Keyboard and scrolling

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Monitors always run on the main thread; a nil result means the event was consumed.
            nonisolated(unsafe) let incoming = event
            nonisolated(unsafe) var outgoing: NSEvent? = event
            MainActor.assumeIsolated {
                if let self { outgoing = self.handleKey(incoming) }
            }
            return outgoing
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            nonisolated(unsafe) let incoming = event
            nonisolated(unsafe) var outgoing: NSEvent? = event
            MainActor.assumeIsolated {
                if let self { outgoing = self.handleScroll(incoming) }
            }
            return outgoing
        }
    }

    /// A mouse wheel only moves vertically, but cards scroll sideways. Trackpads already send horizontal deltas.
    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel, !event.hasPreciseScrollingDeltas, event.scrollingDeltaX == 0,
              let copy = event.cgEvent?.copy() else { return event }
        copy.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: copy.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        copy.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        return NSEvent(cgEvent: copy) ?? event
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        var ownsKeyboard = panel.isKeyWindow || quickLook.isVisible
        #if DEBUG
        ownsKeyboard = ownsKeyboard || debugAssumesKey
        #endif
        guard ownsKeyboard else { return event }
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)

        switch Int(event.keyCode) {
        case kVK_Escape:
            if quickLook.isVisible {
                quickLook.close()
            } else if !model.query.isEmpty {
                clearSearch()
            } else {
                hide()
            }
            return nil
        // ⌘← and ⌘→ switch tabs too, because ⌘[ and ⌘] are awkward or missing on many keyboard layouts.
        case kVK_LeftArrow where command:
            model.cycleTab(by: -1)
            return nil
        case kVK_RightArrow where command:
            model.cycleTab(by: 1)
            return nil
        case kVK_LeftArrow:
            model.move(by: -1, extendSelection: shift)
            refreshQuickLook()
            return nil
        case kVK_RightArrow:
            model.move(by: 1, extendSelection: shift)
            refreshQuickLook()
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            quickLook.close()
            model.pasteSelection(plain: shift)
            return nil
        case kVK_Space where !command && model.query.isEmpty:
            model.quickLookCursor()
            return nil
        case kVK_Delete where command:
            model.deleteSelection()
            return nil
        default:
            break
        }

        guard command, let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
        if let number = Int(key), (1...9).contains(number) {
            model.quickPaste(number: number, plain: shift)
            return nil
        }
        switch key {
        case "f":
            model.showsFilters.toggle()
            if model.showsFilters { model.loadSources() }
        case "e", "r":
            model.editCursor()
        case "n":
            newText()
        case "t":
            model.settings.togglePause()
        case "j":
            model.actions.sendToAgent(model.orderedSelection)
        case "[":
            model.cycleTab(by: -1)
        case "]":
            model.cycleTab(by: 1)
        case "a" where model.query.isEmpty:
            model.selectAll()
        default:
            return event
        }
        return nil
    }

    private func clearSearch() {
        model.query = ""
        if let field = Self.findField(in: panel.contentView) {
            field.stringValue = ""
        }
    }

    private func refreshQuickLook() {
        guard quickLook.isVisible, let id = model.cursorID else { return }
        quickLook.show(clipID: id)
    }

    #if DEBUG
    /// Per-stage timings of one open, for finding where the time goes.
    public func debugProfileShow() async -> String {
        hide()
        await Task.yield()
        func milliseconds(_ body: () -> Void) -> Double {
            let start = ContinuousClock.now
            body()
            let elapsed = ContinuousClock.now - start
            return Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1_000
        }
        let target = Self.targetFrame()
        let prepare = milliseconds { model.prepareForShow() }
        let order = milliseconds {
            panel.setFrame(target, display: false)
            panel.orderFrontRegardless()
        }
        let key = milliseconds {
            panel.makeKey()
            focusSearchField()
        }
        let layout = milliseconds { panel.contentView?.layoutSubtreeIfNeeded() }
        let display = milliseconds { panel.displayIfNeeded() }
        return String(format: "prepare %.1f order %.1f key %.1f layout %.1f display %.1f", prepare, order, key, layout, display)
    }

    /// Lets scripted key events through when no window can be key, such as on a locked screen.
    public var debugAssumesKey = false

    public var debugWindow: NSWindow { panel }

    public var debugResponder: NSResponder? { panel.firstResponder }

    public func debugCancelMenu() -> NSSize? {
        let size = RightClickCatcher.debugActiveMenu?.size
        RightClickCatcher.debugActiveMenu?.cancelTracking()
        RightClickCatcher.debugActiveMenu = nil
        return size
    }

    /// Time from the request to the panel being laid out and drawn.
    public func debugMeasureShow() async -> Double {
        hide()
        await Task.yield()
        let start = ContinuousClock.now
        show()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        await Task.yield()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1_000
    }

    public func debugState() -> [String: Any] {
        let editor = panel.firstResponder as? NSTextView
        return [
            "visible": panel.isVisible,
            "isKey": panel.isKeyWindow,
            "frontmost": NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
            "responder": panel.firstResponder.map { String(describing: type(of: $0)) } ?? "",
            "fieldText": editor?.string ?? "",
            "marked": editor?.hasMarkedText() ?? false,
            "query": model.query,
            "tab": String(describing: model.tab),
            "cursor": model.cursorID ?? -1,
            "selection": Array(model.selection).sorted(),
            "count": model.clips.count,
            "first": model.clips.first?.displayTitle ?? "",
            "notice": model.notice ?? "",
            "headerColor": model.pinboardColorHex ?? "",
            "showsFilters": model.showsFilters,
            "pinboards": model.pinboards.map(\.name),
            "paused": model.settings.isPaused,
            "quickLook": quickLook.isVisible,
        ]
    }
    #endif
}

/// `QLPreviewPanel` is a shared window, so this adopts it directly rather than going through the responder chain.
@MainActor
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let service: ClipService
    private var urls: [URL] = []
    private var shownClip: Int64?

    init(service: ClipService) {
        self.service = service
    }

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func toggle(clipID: Int64, above level: NSWindow.Level) {
        if isVisible {
            close()
        } else {
            QLPreviewPanel.shared().level = NSWindow.Level(rawValue: level.rawValue + 1)
            show(clipID: clipID)
        }
    }

    func show(clipID: Int64) {
        guard clipID != shownClip || !isVisible else { return }
        Task {
            guard let detail = try? await service.detail(id: clipID) else { return }
            urls = PreviewExporter.urls(for: detail, service: service)
            shownClip = clipID
            let panel = QLPreviewPanel.shared()!
            panel.dataSource = self
            panel.delegate = self
            panel.reloadData()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        guard isVisible else { return }
        QLPreviewPanel.shared().orderOut(nil)
        shownClip = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }
}
