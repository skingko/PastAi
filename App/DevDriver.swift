#if DEBUG
import AppKit
import ClipCore
import QuickPanel
import SelectionBar
import Workspace

/// Debug builds only: lets a script drive the real panel with real key events, so keyboard, focus and
/// input-method paths can be checked without taking over the screen. Absent from release builds.
@MainActor
final class DevDriver: NSObject {
    private let panel: QuickPanelController
    private let workspace: WorkspaceController
    private let bar: ActionBarController
    private let settings: AppSettings
    private let pasteboard: NSPasteboard
    private var menuSize: NSSize?
    private var openedURLs: [String] = []
    private var savedClipboard: PasteboardRestorePoint?
    private var eventNumber = 0

    init(panel: QuickPanelController, workspace: WorkspaceController, bar: ActionBarController, settings: AppSettings, pasteboard: NSPasteboard) {
        self.panel = panel
        self.workspace = workspace
        self.bar = bar
        self.settings = settings
        self.pasteboard = pasteboard
        super.init()
        panel.debugAssumesKey = true
        bar.openURL = { [weak self] url in self?.openedURLs.append(url.absoluteString) }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(receive(_:)),
            name: .init("io.github.skingko.pastai.dev"), object: nil, suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func receive(_ notification: Notification) {
        guard let line = notification.object as? String else { return }
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "show": panel.show()
        case "hide": panel.hide()
        case "key": sendKey(argument)
        case "text": argument.forEach { sendCharacter($0) }
        case "mark": (panel.debugResponder as? NSTextView)?.setMarkedText(argument, selectedRange: NSRange(location: argument.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        case "commit": (panel.debugResponder as? NSTextView)?.insertText(argument, replacementRange: NSRange(location: NSNotFound, length: 0))
        case "state": writeState(to: argument)
        case "profile-show":
            Task {
                var lines: [String] = []
                for _ in 0..<6 {
                    lines.append(await panel.debugProfileShow())
                    try? await Task.sleep(for: .milliseconds(300))
                }
                try? lines.joined(separator: "\n").write(toFile: argument, atomically: true, encoding: .utf8)
            }
        case "measure-show":
            Task {
                var samples: [Double] = []
                for _ in 0..<8 {
                    samples.append(await panel.debugMeasureShow())
                    try? await Task.sleep(for: .milliseconds(250))
                }
                let text = samples.map { String(format: "%.1f", $0) }.joined(separator: " ")
                try? text.write(toFile: argument, atomically: true, encoding: .utf8)
            }
        case "library": workspace.showLibrary()
        case "settings": workspace.showSettings()
        case "configure":
            let fields = argument.split(separator: " ").map(String.init)
            if fields.count == 2 { workspace.debugConfigure(baseURL: fields[0], model: fields[1]) }
        case "send": workspace.debugSend(argument)
        case "approve": workspace.debugResolve(approve: true)
        case "approve-session": workspace.debugResolve(approve: true, session: true)
        case "reject": workspace.debugResolve(approve: false)
        case "undo": workspace.debugUndoLast()
        case "select": workspace.debugSelect(argument.split(separator: " ").compactMap { Int64($0) })
        case "section": workspace.debugSection(argument)
        case "bar":
            let fields = argument.split(separator: " ", maxSplits: 1).map(String.init)
            if fields.count == 2 { bar.debugPresent(text: fields[1], editable: fields[0] == "editable") }
        case "bar-tap": bar.debugPerform("io.github.skingko.pastai.\(argument)")
        case "bar-tap-local": bar.debugPerform("local.\(argument)")
        case "bar-hide": bar.dismissAll()
        case "real-click": postRealClick(argument)
        case "clipboard-save": savedClipboard = PasteboardRestorePoint()
        case "clipboard-restore":
            savedClipboard?.restore()
            savedClipboard = nil
        case "market-refresh": workspace.debugMarketRefresh()
        case "market-install": workspace.debugMarketInstall(argument)
        case "snapshot-bar": snapshot(bar.debugBarWindow, to: argument)
        case "snapshot-result": snapshot(bar.debugResultWindow, to: argument)
        case "retry": workspace.debugRetry()
        case "new-session": workspace.debugNewSession()
        case "attach": workspace.debugAttach(argument.split(separator: " ").compactMap { Int64($0) })
        case "appearance": NSApp.appearance = NSAppearance(named: argument == "dark" ? .darkAqua : .aqua)
        case "pin-kinds":
            for kind in ClipKind.allCases {
                settings.setKind(kind, pinned: argument.split(separator: ",").contains(Substring(kind.rawValue)))
            }
        case "leftclick": sendClick(argument, down: .leftMouseDown, up: .leftMouseUp)
        case "rightclick":
            // The menu blocks in its own tracking loop, so its size is read from a timer that runs inside it.
            let timer = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuSize = self?.panel.debugCancelMenu() }
            }
            RunLoop.main.add(timer, forMode: .common)
            sendClick(argument, down: .rightMouseDown, up: nil)
        case "settings-tab": workspace.debugSettingsTab(argument)
        case "snapshot":
            let fields = argument.split(separator: " ", maxSplits: 1).map(String.init)
            if fields.count == 2 { workspace.debugSnapshot(window: fields[0], to: fields[1]) }
        default: break
        }
    }

    /// Format: `<x> <y>` in global display coordinates. A real hardware-level click through the window
    /// server, which is what proves a panel that never becomes key still takes the first press.
    private func postRealClick(_ spec: String) {
        let fields = spec.split(separator: " ").compactMap { Double($0) }
        guard fields.count == 2 else { return }
        let point = CGPoint(x: fields[0], y: fields[1])
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    /// Format: `<x> <y>` in panel coordinates, origin at the bottom left. Goes through the event queue
    /// because right-click routing reads `NSApp.currentEvent`, which `sendEvent` alone does not set.
    private func sendClick(_ spec: String, down: NSEvent.EventType, up: NSEvent.EventType?) {
        let fields = spec.split(separator: " ").compactMap { Double($0) }
        guard fields.count == 2 else { return }
        for (offset, type) in [down, up].compactMap(\.self).enumerated() {
            eventNumber += 1
            guard let event = NSEvent.mouseEvent(
                with: type, location: NSPoint(x: fields[0], y: fields[1]), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime + Double(offset) * 0.05, windowNumber: panel.debugWindow.windowNumber,
                context: nil, eventNumber: eventNumber, clickCount: 1, pressure: type == up ? 0 : 1
            ) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// Format: `<keyCode> [cmd] [shift] [char=x]`.
    private func sendKey(_ spec: String) {
        let fields = spec.split(separator: " ").map(String.init)
        guard let code = fields.first.flatMap(UInt16.init) else { return }
        var flags: NSEvent.ModifierFlags = []
        if fields.contains("cmd") { flags.insert(.command) }
        if fields.contains("shift") { flags.insert(.shift) }
        let character = fields.first { $0.hasPrefix("char=") }.map { String($0.dropFirst(5)) } ?? ""
        post(code: code, flags: flags, characters: character)
    }

    private func sendCharacter(_ character: Character) {
        post(code: 0, flags: [], characters: String(character))
    }

    private func post(code: UInt16, flags: NSEvent.ModifierFlags, characters: String) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.debugWindow.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ) else { return }
        NSApp.sendEvent(event)
    }

    private func snapshot(_ window: NSWindow, to path: String) {
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private func writeState(to path: String) {
        var state = panel.debugState()
        state["pasteboardText"] = pasteboard.string(forType: .string) ?? ""
        state.merge(workspace.debugState()) { _, new in new }
        state.merge(bar.debugState()) { _, new in new }
        state["openedURLs"] = openedURLs
        state["axTrusted"] = PasteSimulator.isTrusted
        state["menuSize"] = menuSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? ""
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
#endif
