import AppKit
import Carbon.HIToolbox

public enum HotKeyFormatter {
    /// Renders a combo for the settings screen, e.g. ⇧⌘V.
    public static func describe(_ combo: HotKeyCombo) -> String {
        var text = ""
        if combo.modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if combo.modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if combo.modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if combo.modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyName(combo.keyCode)
    }

    public static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }

    private static func keyName(_ code: UInt32) -> String {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let layout = unsafeBitCast(property, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layout) else { return "?" }
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { pointer in
            UCKeyTranslate(
                pointer, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}
