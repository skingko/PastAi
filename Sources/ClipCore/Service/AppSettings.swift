import Foundation
import Observation

public struct HotKeyCombo: Codable, Sendable, Hashable {
    /// Virtual key code from HIToolbox `Events.h`.
    public var keyCode: UInt32
    /// Carbon modifier mask: cmd 0x100, shift 0x200, option 0x800, control 0x1000.
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let `default` = HotKeyCombo(keyCode: 9, modifiers: 0x100 | 0x200)
}

public struct RetentionPolicy: Sendable, Hashable {
    public var historyDays: Int
    public var mediaCapBytes: Int64

    public init(historyDays: Int, mediaCapBytes: Int64) {
        self.historyDays = historyDays
        self.mediaCapBytes = mediaCapBytes
    }

    public static let trashDays = 30
}

@MainActor
@Observable
public final class AppSettings {
    /// Password managers and system credential tools. Their copies are never recorded.
    public static let defaultIgnoredApps = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.dashlanephonefinal",
        "com.apple.Passwords",
        "com.apple.keychainaccess",
    ]

    private let defaults: UserDefaults

    public var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: "retentionDays") } }
    public var mediaCapGB: Int { didSet { defaults.set(mediaCapGB, forKey: "mediaCapGB") } }
    public var snapshotLimitMB: Int { didSet { defaults.set(snapshotLimitMB, forKey: "snapshotLimitMB") } }
    public var ignoreConcealed: Bool { didSet { defaults.set(ignoreConcealed, forKey: "ignoreConcealed") } }
    public var ignoredBundleIDs: [String] { didSet { defaults.set(ignoredBundleIDs, forKey: "ignoredBundleIDs") } }
    public var pausedUntil: Date? { didSet { defaults.set(pausedUntil, forKey: "pausedUntil") } }
    /// Built-in categories shown as tabs in the panel, in `ClipKind` order.
    public var pinnedKinds: [ClipKind] { didSet { defaults.set(pinnedKinds.map(\.rawValue), forKey: "pinnedKinds") } }
    public var selectionBarEnabled: Bool { didSet { defaults.set(selectionBarEnabled, forKey: "selectionBarEnabled") } }
    public var selectionBarRequiresOption: Bool { didSet { defaults.set(selectionBarRequiresOption, forKey: "selectionBarRequiresOption") } }
    /// Simulates Cmd-C when an app exposes no accessibility text, restoring the clipboard straight after.
    public var selectionBarFallbackCopy: Bool { didSet { defaults.set(selectionBarFallbackCopy, forKey: "selectionBarFallbackCopy") } }
    public var selectionBarIgnoredApps: [String] { didSet { defaults.set(selectionBarIgnoredApps, forKey: "selectionBarIgnoredApps") } }
    public var hotKey: HotKeyCombo {
        didSet { defaults.set(try? JSONEncoder().encode(hotKey), forKey: "hotKey") }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "retentionDays": 90,
            "mediaCapGB": 20,
            "snapshotLimitMB": 200,
            "ignoreConcealed": true,
            "ignoredBundleIDs": Self.defaultIgnoredApps,
            "selectionBarEnabled": true,
            "selectionBarFallbackCopy": true,
        ])
        retentionDays = defaults.integer(forKey: "retentionDays")
        mediaCapGB = defaults.integer(forKey: "mediaCapGB")
        snapshotLimitMB = defaults.integer(forKey: "snapshotLimitMB")
        ignoreConcealed = defaults.bool(forKey: "ignoreConcealed")
        ignoredBundleIDs = defaults.stringArray(forKey: "ignoredBundleIDs") ?? Self.defaultIgnoredApps
        pausedUntil = defaults.object(forKey: "pausedUntil") as? Date
        pinnedKinds = (defaults.stringArray(forKey: "pinnedKinds") ?? []).compactMap(ClipKind.init(rawValue:))
        selectionBarEnabled = defaults.bool(forKey: "selectionBarEnabled")
        selectionBarRequiresOption = defaults.bool(forKey: "selectionBarRequiresOption")
        selectionBarFallbackCopy = defaults.bool(forKey: "selectionBarFallbackCopy")
        selectionBarIgnoredApps = defaults.stringArray(forKey: "selectionBarIgnoredApps") ?? []
        hotKey = defaults.data(forKey: "hotKey").flatMap { try? JSONDecoder().decode(HotKeyCombo.self, from: $0) } ?? .default
    }

    public var isPaused: Bool { pausedUntil.map { $0 > Date() } ?? false }

    public func setKind(_ kind: ClipKind, pinned: Bool) {
        var chosen = Set(pinnedKinds)
        if pinned { chosen.insert(kind) } else { chosen.remove(kind) }
        pinnedKinds = ClipKind.allCases.filter(chosen.contains)
    }

    public func togglePause() {
        pausedUntil = isPaused ? nil : .distantFuture
    }

    public var retentionPolicy: RetentionPolicy {
        RetentionPolicy(historyDays: retentionDays, mediaCapBytes: Int64(mediaCapGB) * 1_073_741_824)
    }

    public var snapshotLimitBytes: Int64 { Int64(snapshotLimitMB) * 1_048_576 }
}
