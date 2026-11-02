import Foundation

/// Text with an optional Chinese variant. Decodes from a plain string or `{"en": ..., "zh": ...}`.
public struct LocalizedText: Codable, Sendable, Hashable {
    public var en: String
    public var zh: String?

    public init(en: String, zh: String? = nil) {
        self.en = en
        self.zh = zh
    }

    public init(from decoder: any Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            en = text
            zh = nil
            return
        }
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        en = try fields.decode(String.self, forKey: .en)
        zh = try fields.decodeIfPresent(String.self, forKey: .zh)
    }

    public func encode(to encoder: any Encoder) throws {
        if let zh {
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(en, forKey: .en)
            try fields.encode(zh, forKey: .zh)
        } else {
            var single = encoder.singleValueContainer()
            try single.encode(en)
        }
    }

    private enum CodingKeys: String, CodingKey { case en, zh }

    public var localized: String {
        let prefersChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        return prefersChinese ? (zh ?? en) : en
    }
}

/// When an extension is offered. Everything is optional; an empty match applies to any text.
public struct SelectionMatch: Codable, Sendable, Hashable {
    public var regex: String?
    public var minLength: Int?
    public var maxLength: Int?
    public var requiresEditable: Bool?
    public var apps: [String]?
    public var excludeApps: [String]?

    public init(
        regex: String? = nil, minLength: Int? = nil, maxLength: Int? = nil,
        requiresEditable: Bool? = nil, apps: [String]? = nil, excludeApps: [String]? = nil
    ) {
        self.regex = regex
        self.minLength = minLength
        self.maxLength = maxLength
        self.requiresEditable = requiresEditable
        self.apps = apps
        self.excludeApps = excludeApps
    }
}

public struct SelectionInput: Sendable, Hashable {
    public var text: String
    public var appBundleID: String?
    public var isEditable: Bool

    public init(text: String, appBundleID: String? = nil, isEditable: Bool = false) {
        self.text = text
        self.appBundleID = appBundleID
        self.isEditable = isEditable
    }
}

public struct ExtensionOption: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case string, boolean, choice
    }

    public struct Choice: Codable, Sendable, Hashable, Identifiable {
        public var value: String
        public var label: LocalizedText
        public var id: String { value }

        public init(value: String, label: LocalizedText) {
            self.value = value
            self.label = label
        }
    }

    public var id: String
    public var type: Kind
    public var label: LocalizedText
    public var placeholder: LocalizedText?
    public var defaultValue: String?
    public var required: Bool?
    public var choices: [Choice]?

    public init(
        id: String, type: Kind, label: LocalizedText, placeholder: LocalizedText? = nil,
        defaultValue: String? = nil, required: Bool? = nil, choices: [Choice]? = nil
    ) {
        self.id = id
        self.type = type
        self.label = label
        self.placeholder = placeholder
        self.defaultValue = defaultValue
        self.required = required
        self.choices = choices
    }
}

/// The closed set of things an extension can do. There is deliberately no shell or AppleScript action:
/// market extensions are downloaded code, and this list is what makes installing one low-risk.
public enum ExtensionAction: Sendable, Hashable, Codable {
    /// Opens a URL template. `returnKeyOption` names a boolean option that presses Return once the target
    /// app is in front, which is how a drafted message gets sent without a second click.
    case url(template: String, fallback: String?, returnKeyOption: String?)
    /// Brings an app forward, for apps with no deep link that accepts text.
    case app(bundleID: String, copyFirst: Bool)
    case copy
    case paste
    /// Runs `file` in the JavaScript sandbox.
    case script(file: String)
    /// Sends `prompt` to the user's configured model and shows the streamed result in a small popover.
    case ai(system: String?, prompt: String)

    private enum CodingKeys: String, CodingKey {
        case type, url, fallbackURL, returnKeyOption, bundleID, copyFirst, file, system, prompt
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let type = try fields.decode(String.self, forKey: .type)
        switch type {
        case "url":
            self = .url(
                template: try fields.decode(String.self, forKey: .url),
                fallback: try fields.decodeIfPresent(String.self, forKey: .fallbackURL),
                returnKeyOption: try fields.decodeIfPresent(String.self, forKey: .returnKeyOption)
            )
        case "app":
            self = .app(
                bundleID: try fields.decode(String.self, forKey: .bundleID),
                copyFirst: try fields.decodeIfPresent(Bool.self, forKey: .copyFirst) ?? true
            )
        case "copy": self = .copy
        case "paste": self = .paste
        case "script": self = .script(file: try fields.decodeIfPresent(String.self, forKey: .file) ?? "script.js")
        case "ai":
            self = .ai(system: try fields.decodeIfPresent(String.self, forKey: .system), prompt: try fields.decode(String.self, forKey: .prompt))
        default:
            throw ExtensionError.unsupportedAction(type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .url(let template, let fallback, let returnKeyOption):
            try fields.encode("url", forKey: .type)
            try fields.encode(template, forKey: .url)
            try fields.encodeIfPresent(fallback, forKey: .fallbackURL)
            try fields.encodeIfPresent(returnKeyOption, forKey: .returnKeyOption)
        case .app(let bundleID, let copyFirst):
            try fields.encode("app", forKey: .type)
            try fields.encode(bundleID, forKey: .bundleID)
            try fields.encode(copyFirst, forKey: .copyFirst)
        case .copy:
            try fields.encode("copy", forKey: .type)
        case .paste:
            try fields.encode("paste", forKey: .type)
        case .script(let file):
            try fields.encode("script", forKey: .type)
            try fields.encode(file, forKey: .file)
        case .ai(let system, let prompt):
            try fields.encode("ai", forKey: .type)
            try fields.encodeIfPresent(system, forKey: .system)
            try fields.encode(prompt, forKey: .prompt)
        }
    }
}

public struct ExtensionManifest: Codable, Sendable, Hashable, Identifiable {
    /// Bump when a manifest change would break older app versions.
    public static let currentSchema = 1
    public static let localPrefix = "local."

    public var schema: Int?
    public var id: String
    public var name: LocalizedText
    public var description: LocalizedText
    public var version: String
    public var author: String?
    public var homepage: String?
    public var category: String
    public var regions: [String]?
    /// `symbol:<SF Symbol>`, `text:<1-2 characters>` or `file:<relative path to .svg or .png>`.
    public var icon: String
    public var match: SelectionMatch?
    public var options: [ExtensionOption]?
    public var action: ExtensionAction

    public init(
        schema: Int? = currentSchema, id: String, name: LocalizedText, description: LocalizedText, version: String,
        author: String? = nil, homepage: String? = nil, category: String, regions: [String]? = nil, icon: String,
        match: SelectionMatch? = nil, options: [ExtensionOption]? = nil, action: ExtensionAction
    ) {
        self.schema = schema
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.author = author
        self.homepage = homepage
        self.category = category
        self.regions = regions
        self.icon = icon
        self.match = match
        self.options = options
        self.action = action
    }

    public var isLocal: Bool { id.hasPrefix(Self.localPrefix) }

    /// Files the manifest depends on, relative to its folder.
    public var referencedFiles: [String] {
        var files: [String] = []
        if icon.hasPrefix("file:") { files.append(String(icon.dropFirst(5))) }
        if case .script(let file) = action { files.append(file) }
        return files
    }

    public func applies(to input: SelectionInput) -> Bool {
        let length = input.text.count
        guard length >= (match?.minLength ?? 1) else { return false }
        if let maximum = match?.maxLength, length > maximum { return false }
        if match?.requiresEditable == true, !input.isEditable { return false }
        if let apps = match?.apps, !apps.isEmpty {
            guard let app = input.appBundleID, apps.contains(app) else { return false }
        }
        if let excluded = match?.excludeApps, let app = input.appBundleID, excluded.contains(app) { return false }
        if let pattern = match?.regex, let regex = try? NSRegularExpression(pattern: pattern) {
            let trimmed = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            return regex.firstMatch(in: trimmed, range: range) != nil
        }
        return true
    }
}

/// One AI action, as handed from the selection bar to whatever owns the model configuration.
public struct AIActionRequest: Sendable, Hashable {
    public var system: String?
    public var prompt: String

    public init(system: String?, prompt: String) {
        self.system = system
        self.prompt = prompt
    }
}

public enum AIActionError: Error, Equatable {
    case notConfigured
    /// The configured provider is a cloud service the user has not agreed to send clipboard content to.
    case needsConsent(providerName: String)
}

public enum ExtensionError: Error, LocalizedError, Equatable {
    case unsupportedAction(String)
    case invalidManifest(String)
    case invalidURL(String)
    case blockedScheme(String)
    case missingOption(LocalizedText)
    case scriptFailed(String)
    case scriptTimedOut
    case integrityMismatch(String)
    case notLocal(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedAction(let type): "不支持的动作类型：\(type)。可用类型：url、app、copy、paste、script、ai"
        case .invalidManifest(let detail): "组件定义无效：\(detail)"
        case .invalidURL(let url): "生成的地址无效：\(url)"
        case .blockedScheme(let scheme): "组件不允许使用 \(scheme): 地址"
        case .missingOption(let label): "请先在设置里填写“\(label.localized)”"
        case .scriptFailed(let detail): "脚本运行失败：\(detail)"
        case .scriptTimedOut: "脚本运行超时，已被终止"
        case .integrityMismatch(let file): "下载的文件校验失败：\(file)"
        case .notLocal(let id): "只能修改本地自定义组件，\(id) 不是"
        }
    }
}
