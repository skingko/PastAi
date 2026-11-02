import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// A clip points at files that are no longer where they were, so nothing reached the pasteboard.
public struct MissingFilesError: Error, Equatable, LocalizedError {
    public let names: [String]

    public var errorDescription: String? {
        names.count == 1 ? L("“\(names[0])”已不在原来的位置，无法粘贴") : L("\(names.count) 个文件已不在原来的位置，无法粘贴")
    }
}

@MainActor
public final class PasteWriter {
    /// Tags our own writes so the monitor does not record pastes as new copies.
    public nonisolated static let internalMarker = NSPasteboard.PasteboardType("io.github.skingko.pastai.internal")

    public enum Mode: Sendable {
        case original
        case plainText
    }

    private let service: ClipService
    private let pasteboard: NSPasteboard

    public init(service: ClipService, pasteboard: NSPasteboard = .general) {
        self.service = service
        self.pasteboard = pasteboard
    }

    /// Writes clips to the pasteboard and returns how many could be written. Multiple text clips are
    /// joined so a single paste delivers all of them; a mixed selection pastes as one item per clip.
    /// Throws `MissingFilesError` rather than quietly pasting only the files that remain.
    @discardableResult
    public func write(_ details: [ClipDetail], mode: Mode) throws -> Int {
        if mode == .original {
            let missing = details.flatMap(\.files).filter { service.resolveURL(for: $0) == nil }
            guard missing.isEmpty else { throw MissingFilesError(names: missing.map(\.fileName)) }
        }
        let items: [NSPasteboardItem]
        if details.count > 1, details.allSatisfy({ $0.clip.kind.isTextual }) {
            let joined = details.compactMap(\.clip.plainText).joined(separator: "\n")
            items = [plainItem(joined)]
        } else {
            items = try details.flatMap { try self.items(for: $0, mode: mode) }
        }
        guard !items.isEmpty else { return 0 }
        items[0].setData(Data(), forType: Self.internalMarker)
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        return details.count
    }

    private func items(for detail: ClipDetail, mode: Mode) throws -> [NSPasteboardItem] {
        if !detail.files.isEmpty {
            if mode == .plainText {
                return [plainItem(detail.files.map(\.originalPath).joined(separator: "\n"))]
            }
            return detail.files.compactMap { file in
                guard let url = service.resolveURL(for: file) else { return nil }
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                return item
            }
        }
        if mode == .plainText, let text = detail.clip.plainText {
            return [plainItem(text)]
        }
        let groups = Dictionary(grouping: detail.representations, by: \.itemIndex)
        return try groups.keys.sorted().map { index in
            let item = NSPasteboardItem()
            for representation in groups[index, default: []] {
                if let data = try service.data(for: representation) {
                    item.setData(data, forType: NSPasteboard.PasteboardType(representation.uti))
                }
            }
            return item
        }
    }

    private func plainItem(_ text: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        return item
    }
}

public enum PasteSimulator {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that deep-links to the Accessibility pane.
    public static func requestTrust() {
        let key = "AXTrustedCheckOptionPrompt"
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Posts Cmd-V to the frontmost app. Returns false without Accessibility permission,
    /// in which case the clip is on the pasteboard and the user can paste by hand.
    @discardableResult
    public static func pasteToFrontmostApp() -> Bool {
        press(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
    }

    @discardableResult
    public static func copyFromFrontmostApp() -> Bool {
        press(CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
    }

    @discardableResult
    public static func pressReturn() -> Bool {
        press(CGKeyCode(kVK_Return), flags: [])
    }

    private static func press(_ key: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard isTrusted, let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}

/// Saves whatever is on the pasteboard and puts it back later, for features that need it for a moment.
@MainActor
public struct PasteboardRestorePoint {
    private let snapshot: PasteboardSnapshot
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        snapshot = PasteboardReader.read(pasteboard)
    }

    public func restore() {
        pasteboard.clearContents()
        let items = snapshot.items.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for entry in entries { item.setData(entry.data, forType: .init(entry.uti)) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
