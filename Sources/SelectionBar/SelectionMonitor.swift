import AppKit
import ApplicationServices
import ClipCore

public struct SelectionContext: Sendable, Hashable {
    public var text: String
    public var appBundleID: String?
    public var isEditable: Bool
    /// Screen position of the pointer when the selection finished.
    public var anchor: CGPoint

    public init(text: String, appBundleID: String?, isEditable: Bool, anchor: CGPoint) {
        self.text = text
        self.appBundleID = appBundleID
        self.isEditable = isEditable
        self.anchor = anchor
    }
}

@MainActor
enum SelectionReader {
    private static var preparedProcesses = Set<pid_t>()

    /// Reads the selection through Accessibility, which leaves the clipboard alone.
    static func read(from app: NSRunningApplication) -> (text: String, isEditable: Bool)? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // A hung app must not be able to stall the main thread.
        AXUIElementSetMessagingTimeout(element, 0.2)
        if let result = selection(in: element) { return result }

        // Chromium and Electron build their accessibility tree only when asked, and only once per process.
        guard preparedProcesses.insert(app.processIdentifier).inserted else { return nil }
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return selection(in: element)
    }

    private static func selection(in application: AXUIElement) -> (text: String, isEditable: Bool)? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String, !text.isEmpty else { return nil }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        return (text, settable.boolValue)
    }

    /// Last resort for apps with no usable accessibility text. The pasteboard is put back straight after,
    /// and capture stays suspended throughout, so nothing of this reaches the clipboard history.
    static func readByCopying(capture: CaptureService?) async -> String? {
        let pasteboard = NSPasteboard.general
        let restorePoint = PasteboardRestorePoint(pasteboard: pasteboard)
        let before = pasteboard.changeCount
        capture?.isSuspended = true
        defer {
            capture?.acknowledgeCurrentContents()
            capture?.isSuspended = false
        }
        guard PasteSimulator.copyFromFrontmostApp() else { return nil }
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(25))
            if pasteboard.changeCount != before { break }
        }
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)
        restorePoint.restore()
        return text
    }
}

/// Watches the mouse from outside the app and reports finished selections.
@MainActor
final class SelectionMonitor {
    private let settings: AppSettings
    private let capture: CaptureService?
    private var monitors: [Any] = []
    private var pressLocation = NSPoint.zero
    private var didDrag = false
    private var pressedOnText = false
    private var pending: Task<Void, Never>?

    var onSelection: ((SelectionContext) -> Void)?
    /// Anything that would make the bar stale: a click elsewhere, typing, scrolling.
    var onDismiss: (() -> Void)?

    static let dragThreshold: CGFloat = 8

    init(settings: AppSettings, capture: CaptureService?) {
        self.settings = settings
        self.capture = capture
    }

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .keyDown, .scrollWheel]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            nonisolated(unsafe) let incoming = event
            MainActor.assumeIsolated { self?.handle(incoming) }
        }) {
            monitors.append(monitor)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        pending?.cancel()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            pressLocation = NSEvent.mouseLocation
            didDrag = false
            // Taken at the press: an I-beam is what separates selecting text from dragging a window,
            // and a window drag would otherwise re-report whatever was selected before.
            pressedOnText = Self.isTextCursor
            onDismiss?()
        case .leftMouseDragged:
            let location = NSEvent.mouseLocation
            if hypot(location.x - pressLocation.x, location.y - pressLocation.y) >= Self.dragThreshold { didDrag = true }
        case .leftMouseUp:
            finishSelection(clickCount: event.clickCount, flags: event.modifierFlags)
        default:
            onDismiss?()
        }
    }

    private func finishSelection(clickCount: Int, flags: NSEvent.ModifierFlags) {
        let isMultiClick = clickCount >= 2
        guard settings.selectionBarEnabled, pressedOnText, didDrag || isMultiClick || flags.contains(.shift) else { return }
        if settings.selectionBarRequiresOption, !flags.contains(.option) { return }
        guard PasteSimulator.isTrusted, let app = NSWorkspace.shared.frontmostApplication else { return }
        let bundleID = app.bundleIdentifier
        if bundleID == Bundle.main.bundleIdentifier { return }
        if let bundleID, settings.ignoredBundleIDs.contains(bundleID) || settings.selectionBarIgnoredApps.contains(bundleID) { return }

        let anchor = NSEvent.mouseLocation
        pending?.cancel()
        pending = Task { [weak self] in
            // Double-click selection lands a moment after the click that caused it.
            try? await Task.sleep(for: .milliseconds(isMultiClick ? 140 : 50))
            guard !Task.isCancelled, let self else { return }
            await self.resolve(app: app, anchor: anchor)
        }
    }

    private func resolve(app: NSRunningApplication, anchor: CGPoint) async {
        if let selection = SelectionReader.read(from: app) {
            report(selection.text, app: app, isEditable: selection.isEditable, anchor: anchor)
        } else if settings.selectionBarFallbackCopy, let text = await SelectionReader.readByCopying(capture: capture), !text.isEmpty {
            // Editability cannot be known here, and offering Insert in a read-only view just does nothing.
            report(text, app: app, isEditable: true, anchor: anchor)
        }
    }

    private func report(_ text: String, app: NSRunningApplication, isEditable: Bool, anchor: CGPoint) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSelection?(SelectionContext(text: text, appBundleID: app.bundleIdentifier, isEditable: isEditable, anchor: anchor))
    }

    private static var isTextCursor: Bool {
        guard let current = NSCursor.currentSystem else { return true }
        return current.image.tiffRepresentation == NSCursor.iBeam.image.tiffRepresentation
    }
}
