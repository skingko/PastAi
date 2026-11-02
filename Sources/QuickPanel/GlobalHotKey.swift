import AppKit
import Carbon.HIToolbox
import ClipCore

/// Carbon is still the only global hotkey API that needs no Accessibility permission.
@MainActor
public final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    public var onPress: (() -> Void)?

    public init() {}

    @discardableResult
    public func register(_ combo: HotKeyCombo) -> Bool {
        unregister()
        installHandlerIfNeeded()
        let identifier = EventHotKeyID(signature: OSType(0x5041_5354), id: 1)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, identifier, GetApplicationEventTarget(), 0, &hotKey)
        return status == noErr
    }

    public func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let target = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { target.onPress?() }
            return noErr
        }, 1, &type, context, &handler)
    }
}
