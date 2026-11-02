import Foundation

/// Fills `{text}`, `{text.raw}` and `{option.<id>}` placeholders.
public enum TemplateRenderer {
    /// Schemes that reach local files, run code, or trigger the user's automations.
    static let blockedSchemes: Set<String> = [
        "file", "javascript", "data", "blob", "about", "vbscript", "ftp", "smb", "afp", "nfs", "vnc", "ssh", "telnet",
        "shortcuts", "workflow", "applescript", "x-apple.systempreferences",
    ]

    private static let queryValue: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    public static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: queryValue) ?? ""
    }

    /// Selected text is always percent-encoded, so it cannot add query parameters or change the host.
    /// `{text.raw}` is only for extensions whose whole template is the selection, which then must be a web link.
    public static func url(_ template: String, text: String, options: [String: String]) throws -> URL {
        var rendered = template
            .replacingOccurrences(of: "{text.raw}", with: text.trimmingCharacters(in: .whitespacesAndNewlines))
            .replacingOccurrences(of: "{text}", with: encode(text))
        for (key, value) in options {
            rendered = rendered.replacingOccurrences(of: "{option.\(key)}", with: encode(value))
        }
        guard let url = URL(string: rendered), let scheme = url.scheme?.lowercased() else {
            throw ExtensionError.invalidURL(String(rendered.prefix(120)))
        }
        guard !blockedSchemes.contains(scheme) else { throw ExtensionError.blockedScheme(scheme) }
        if template.hasPrefix("{text.raw}"), !["http", "https", "mailto"].contains(scheme) {
            throw ExtensionError.blockedScheme(scheme)
        }
        return url
    }

    public static func prompt(_ template: String, text: String, options: [String: String]) -> String {
        var rendered = template
        for (key, value) in options {
            rendered = rendered.replacingOccurrences(of: "{option.\(key)}", with: value)
        }
        // The selection goes in last so text inside it can never be read as a placeholder.
        return rendered.replacingOccurrences(of: "{text}", with: text)
    }

    static func referencedOptions(in template: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\{option\.([A-Za-z0-9_]+)\}"#) else { return [] }
        let range = NSRange(template.startIndex..., in: template)
        return regex.matches(in: template, range: range).compactMap { match in
            Range(match.range(at: 1), in: template).map { String(template[$0]) }
        }
    }
}

public enum ExtensionValidator {
    public static let maxScriptBytes = 256 * 1024
    public static let maxIconBytes = 256 * 1024
    static let symbolOrTextLimit = 64

    /// Checks everything that can be decided from the manifest alone. Used on every install path,
    /// including the agent's, so nothing reaches disk or the bar without passing here.
    public static func validate(_ manifest: ExtensionManifest) throws {
        func reject(_ reason: String) throws -> Never { throw ExtensionError.invalidManifest(reason) }

        if let schema = manifest.schema, schema > ExtensionManifest.currentSchema {
            try reject("需要更新版本的 PastAi（schema \(schema)）")
        }
        guard manifest.id.range(of: #"^[a-z0-9]+(\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil else {
            try reject("id 只能使用小写字母、数字、点和连字符，例如 local.my-tool")
        }
        guard !manifest.name.en.trimmingCharacters(in: .whitespaces).isEmpty else { try reject("name 不能为空") }
        guard manifest.version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else {
            try reject("version 必须是 1.0.0 这样的格式")
        }
        try validateIcon(manifest.icon)

        for file in manifest.referencedFiles where !isSafeRelativePath(file) {
            try reject("文件路径不安全：\(file)")
        }
        if let pattern = manifest.match?.regex, (try? NSRegularExpression(pattern: pattern)) == nil {
            try reject("match.regex 不是合法的正则表达式")
        }

        var optionIDs = Set<String>()
        for option in manifest.options ?? [] {
            guard option.id.range(of: #"^[A-Za-z0-9_]+$"#, options: .regularExpression) != nil else {
                try reject("选项 id 无效：\(option.id)")
            }
            guard optionIDs.insert(option.id).inserted else { try reject("选项 id 重复：\(option.id)") }
            if option.type == .choice, option.choices?.isEmpty ?? true { try reject("选项 \(option.id) 缺少 choices") }
        }

        switch manifest.action {
        case .url(let template, let fallback, let returnKeyOption):
            for candidate in [template, fallback].compactMap(\.self) {
                try validateTemplate(candidate, optionIDs: optionIDs)
            }
            if let returnKeyOption, !optionIDs.contains(returnKeyOption) {
                try reject("returnKeyOption 引用了不存在的选项：\(returnKeyOption)")
            }
        case .app(let bundleID, _):
            guard bundleID.contains(".") else { try reject("bundleID 无效") }
        case .ai(_, let prompt):
            guard prompt.contains("{text}") else { try reject("AI 提示词必须包含 {text}") }
            for id in TemplateRenderer.referencedOptions(in: prompt) where !optionIDs.contains(id) {
                try reject("提示词引用了不存在的选项：\(id)")
            }
        case .copy, .paste, .script:
            break
        }
    }

    private static func validateTemplate(_ template: String, optionIDs: Set<String>) throws {
        for id in TemplateRenderer.referencedOptions(in: template) where !optionIDs.contains(id) {
            throw ExtensionError.invalidManifest("地址引用了不存在的选项：\(id)")
        }
        let sample = Dictionary(uniqueKeysWithValues: optionIDs.map { ($0, "sample") })
        let text = template.hasPrefix("{text.raw}") ? "https://example.com" : "sample"
        _ = try TemplateRenderer.url(template, text: text, options: sample)
    }

    private static func validateIcon(_ icon: String) throws {
        let parts = icon.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, ["symbol", "text", "file"].contains(parts[0]), !parts[1].isEmpty else {
            throw ExtensionError.invalidManifest("icon 必须是 symbol:、text: 或 file: 开头")
        }
        if parts[0] == "text", parts[1].count > 2 {
            throw ExtensionError.invalidManifest("text 图标最多 2 个字符")
        }
        if parts[0] == "symbol", parts[1].count > symbolOrTextLimit {
            throw ExtensionError.invalidManifest("symbol 名称过长")
        }
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return !path.split(separator: "/").contains("..")
    }

    /// A short description of what an extension will do, shown before it is installed.
    public static func describe(_ action: ExtensionAction) -> String {
        switch action {
        case .url(let template, _, _): "打开地址：\(template)"
        case .app(let bundleID, let copyFirst): copyFirst ? "拷贝文本并打开 \(bundleID)" : "打开 \(bundleID)"
        case .copy: "拷贝选中内容"
        case .paste: "用剪贴板内容替换选中内容"
        case .script: "在沙箱里运行脚本（不能联网，不能读写文件）"
        case .ai(_, let prompt): "把选中内容发给你配置的 AI 模型：\(prompt.prefix(120))"
        }
    }
}
