import ClipCore
import Foundation
import Observation

public struct InstalledExtension: Identifiable, Sendable, Hashable {
    public var manifest: ExtensionManifest
    public var directory: URL
    public var isEnabled: Bool

    public var id: String { manifest.id }
}

/// Which extensions are on, their order and their option values. Separate from the extensions themselves
/// so updating an extension keeps the user's choices.
struct ExtensionState: Codable {
    var order: [String] = []
    var disabled: Set<String> = []
    var options: [String: [String: String]] = [:]
}

@MainActor
@Observable
public final class ExtensionLibrary {
    /// Turned on the first time the app runs. Everything else is opt-in from the market.
    public nonisolated static let defaultEnabled = [
        "io.github.skingko.pastai.copy",
        "io.github.skingko.pastai.translate",
        "io.github.skingko.pastai.google",
        "io.github.skingko.pastai.whatsapp",
    ]

    public private(set) var installed: [InstalledExtension] = []

    private let root: URL
    private var state = ExtensionState()

    private var stateFile: URL { root.appending(path: "state.json") }

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        loadState()
        reload()
    }

    public convenience init(paths: AppPaths) {
        self.init(root: paths.root.appending(path: "extensions", directoryHint: .isDirectory))
    }

    public var enabled: [InstalledExtension] { installed.filter(\.isEnabled) }

    public func actions(for input: SelectionInput) -> [InstalledExtension] {
        enabled.filter { $0.manifest.applies(to: input) }
    }

    public func extensionItem(id: String) -> InstalledExtension? {
        installed.first { $0.id == id }
    }

    /// Copies the default extensions out of the app bundle on first launch, so the bar works offline.
    public func seedDefaults(from bundled: URL) {
        guard !FileManager.default.fileExists(atPath: stateFile.path), installed.isEmpty else { return }
        for id in Self.defaultEnabled {
            let slug = id.replacingOccurrences(of: "io.github.skingko.pastai.", with: "")
            _ = try? install(fromDirectory: bundled.appending(path: slug, directoryHint: .isDirectory))
        }
        persistState()
    }

    /// A new version of the app ships newer copies of its extensions, so fixes reach people offline too.
    public func updateBundled(from bundled: URL) {
        for item in installed where !item.manifest.isLocal {
            let slug = item.manifest.id.replacingOccurrences(of: "io.github.skingko.pastai.", with: "")
            let folder = bundled.appending(path: slug, directoryHint: .isDirectory)
            guard let data = try? Data(contentsOf: folder.appending(path: "extension.json")),
                  let shipped = try? JSONDecoder().decode(ExtensionManifest.self, from: data),
                  ExtensionCatalog.isNewer(shipped.version, than: item.manifest.version) else { continue }
            _ = try? install(fromDirectory: folder)
        }
    }

    // MARK: Install and remove

    /// Validates, then copies into place. Every source goes through here: market, bundle and agent.
    @discardableResult
    public func install(fromDirectory source: URL) throws -> ExtensionManifest {
        let data = try Data(contentsOf: source.appending(path: "extension.json"))
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
        try ExtensionValidator.validate(manifest)
        for file in manifest.referencedFiles {
            guard FileManager.default.fileExists(atPath: source.appending(path: file).path) else {
                throw ExtensionError.invalidManifest(L("缺少文件：\(file)"))
            }
        }
        let destination = directory(for: manifest.id)
        let staging = root.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: source, to: staging)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: staging, to: destination)
        if !state.order.contains(manifest.id) { state.order.append(manifest.id) }
        persistState()
        reload()
        return manifest
    }

    /// Writes an extension described in memory, as the agent does. `script` becomes `script.js`.
    @discardableResult
    public func installLocal(_ manifest: ExtensionManifest, script: String?) throws -> ExtensionManifest {
        guard manifest.isLocal else { throw ExtensionError.notLocal(manifest.id) }
        let staging = root.appending(path: ".build-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: staging.appending(path: "extension.json"))
        if case .script(let file) = manifest.action {
            guard let script, script.utf8.count <= ExtensionValidator.maxScriptBytes else {
                throw ExtensionError.invalidManifest(L("脚本为空或超过 256KB"))
            }
            guard ExtensionValidator.isSafeRelativePath(file) else {
                throw ExtensionError.invalidManifest(L("文件路径不安全：\(file)"))
            }
            try script.write(to: staging.appending(path: file), atomically: true, encoding: .utf8)
        }
        return try install(fromDirectory: staging)
    }

    public func remove(_ id: String) throws {
        try FileManager.default.removeItem(at: directory(for: id))
        state.order.removeAll { $0 == id }
        state.disabled.remove(id)
        state.options[id] = nil
        persistState()
        reload()
    }

    // MARK: Preferences

    public func setEnabled(_ id: String, _ enabled: Bool) {
        if enabled { state.disabled.remove(id) } else { state.disabled.insert(id) }
        persistState()
        reload()
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ids = installed.map(\.id)
        let moved = source.sorted().map { ids[$0] }
        ids.remove(atOffsets: source)
        let adjusted = destination - source.filter { $0 < destination }.count
        ids.insert(contentsOf: moved, at: adjusted)
        state.order = ids
        persistState()
        reload()
    }

    public func optionValues(for id: String) -> [String: String] {
        var values: [String: String] = [:]
        for option in extensionItem(id: id)?.manifest.options ?? [] {
            if let fallback = option.resolvedDefault { values[option.id] = fallback }
        }
        return values.merging(state.options[id] ?? [:]) { _, stored in stored }
    }

    public func setOption(_ extensionID: String, option: String, value: String) {
        state.options[extensionID, default: [:]][option] = value
        persistState()
    }

    public func script(for item: InstalledExtension, file: String) throws -> String {
        try String(contentsOf: item.directory.appending(path: file), encoding: .utf8)
    }

    public func iconURL(for item: InstalledExtension) -> URL? {
        guard item.manifest.icon.hasPrefix("file:") else { return nil }
        return item.directory.appending(path: String(item.manifest.icon.dropFirst(5)))
    }

    /// The first required option with no value, which has to be filled in before the action can run.
    public func missingOption(for item: InstalledExtension) -> ExtensionOption? {
        let values = optionValues(for: item.id)
        return item.manifest.options?.first { $0.required == true && (values[$0.id] ?? "").isEmpty }
    }

    // MARK: Storage

    private func directory(for id: String) -> URL {
        root.appending(path: id, directoryHint: .isDirectory)
    }

    public func reload() {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var found: [String: InstalledExtension] = [:]
        for folder in folders where !folder.lastPathComponent.hasPrefix(".") {
            // A folder that no longer validates is skipped rather than allowed to break the bar.
            guard let data = try? Data(contentsOf: folder.appending(path: "extension.json")),
                  let manifest = try? JSONDecoder().decode(ExtensionManifest.self, from: data),
                  (try? ExtensionValidator.validate(manifest)) != nil else { continue }
            found[manifest.id] = InstalledExtension(manifest: manifest, directory: folder, isEnabled: !state.disabled.contains(manifest.id))
        }
        var ordered = state.order.compactMap { found.removeValue(forKey: $0) }
        ordered += found.values.sorted { $0.id < $1.id }
        installed = ordered
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateFile) else { return }
        state = (try? JSONDecoder().decode(ExtensionState.self, from: data)) ?? ExtensionState()
    }

    private func persistState() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateFile, options: .atomic)
    }
}
