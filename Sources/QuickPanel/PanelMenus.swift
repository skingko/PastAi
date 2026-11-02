import AppKit
import ClipCore
import SwiftUI

/// A native menu can never enter the Dock area, and when it does not fit below the pointer AppKit either
/// flips it entirely above the pointer or truncates it. This panel always sits at the bottom of the screen,
/// so both happen constantly; see `present(at:)` for how they are avoided.
struct RightClickCatcher: NSViewRepresentable {
    var menu: @MainActor () -> NSMenu

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.makeMenu = menu
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.makeMenu = menu
    }

    final class CatcherView: NSView {
        var makeMenu: (@MainActor () -> NSMenu)?

        /// Sits on top of the SwiftUI content, since anything behind it never sees the click, and claims
        /// only secondary clicks so that taps and drags still reach the card.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let isSecondary = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return isSecondary ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { present(at: event) }
        override func mouseDown(with event: NSEvent) { present(at: event) }

        private func present(at event: NSEvent) {
            guard let menu = makeMenu?() else { return }
            #if DEBUG
            RightClickCatcher.debugActiveMenu = menu
            #endif
            // Raises the menu by exactly what would not fit, so the pointer stays inside it.
            var location = convert(event.locationInWindow, from: nil)
            if let window {
                let pointerY = window.convertPoint(toScreen: event.locationInWindow).y
                let lowestAllowed = (window.screen?.visibleFrame.minY ?? 0) + 6
                location.y += max(0, lowestAllowed + menu.size.height - pointerY)
            }
            menu.popUp(positioning: nil, at: location, in: self)
        }
    }

    #if DEBUG
    @MainActor static var debugActiveMenu: NSMenu?
    #endif
}

private final class ActionItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used from a nib") }

    @objc @MainActor private func fire() { handler() }
}

extension PanelModel {
    func menu(for clip: Clip) -> NSMenu {
        // As in Finder, right-clicking outside the selection acts on that item alone.
        if !selection.contains(clip.id) { select(clip.id, modifiers: []) }
        let targets = orderedSelection

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ActionItem("粘贴") { [self] in actions.paste(targets, .original) })
        menu.addItem(ActionItem("粘贴为纯文本") { [self] in actions.paste(targets, .plainText) })
        menu.addItem(ActionItem("预览") { [self] in actions.quickLook(clip.id) })
        menu.addItem(ActionItem(clip.kind.isTextual ? "编辑…" : "重命名…") { [self] in actions.edit(clip.id) })
        menu.addItem(.separator())

        let boards = NSMenuItem(title: "加入 Pinboard", action: nil, keyEquivalent: "")
        boards.isEnabled = !pinboards.isEmpty
        if !pinboards.isEmpty {
            let submenu = NSMenu()
            for board in pinboards {
                submenu.addItem(ActionItem(board.name) { [self] in pin(targets, to: board.id) })
            }
            boards.submenu = submenu
        }
        menu.addItem(boards)
        if case .pinboard = tab {
            menu.addItem(ActionItem("从此 Pinboard 移除") { [self] in unpinFromCurrentBoard(targets) })
        }
        menu.addItem(ActionItem("交给 Agent") { [self] in actions.sendToAgent(targets) })
        menu.addItem(.separator())

        menu.addItem(ActionItem(clip.aiHidden ? "允许 AI 访问" : "对 AI 隐藏") { [self] in setAIHidden(targets, hidden: !clip.aiHidden) })
        menu.addItem(ActionItem("删除") { [self] in
            selection = Set(targets)
            deleteSelection()
        })
        return menu
    }

    func menu(for board: Pinboard, edit: @escaping @MainActor () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ActionItem("编辑…", handler: edit))
        menu.addItem(ActionItem(board.aiHidden ? "允许 AI 访问" : "对 AI 隐藏") { [self] in
            var updated = board
            updated.aiHidden.toggle()
            update(updated)
        })
        menu.addItem(.separator())
        menu.addItem(ActionItem("删除 Pinboard") { [self] in delete(board) })
        return menu
    }
}
