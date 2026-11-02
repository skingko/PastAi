import ClipExtensions
import Foundation

public struct ExtensionSummary: Sendable, Hashable {
    public var id: String
    public var name: String
    public var version: String
    public var isEnabled: Bool
    public var isLocal: Bool
    public var summary: String

    public init(id: String, name: String, version: String, isEnabled: Bool, isLocal: Bool, summary: String) {
        self.id = id
        self.name = name
        self.version = version
        self.isEnabled = isEnabled
        self.isLocal = isLocal
        self.summary = summary
    }
}

/// The agent's route to the extension library, provided by the app so this module stays free of UI state.
public struct ExtensionAccess: Sendable {
    public var list: @Sendable () async -> [ExtensionSummary]
    public var install: @Sendable (ExtensionManifest, String?) async throws -> Void
    public var remove: @Sendable (String) async throws -> Void
    public var runScript: @Sendable (String, ScriptInput) async throws -> ScriptOutput

    public init(
        list: @escaping @Sendable () async -> [ExtensionSummary],
        install: @escaping @Sendable (ExtensionManifest, String?) async throws -> Void,
        remove: @escaping @Sendable (String) async throws -> Void,
        runScript: @escaping @Sendable (String, ScriptInput) async throws -> ScriptOutput
    ) {
        self.list = list
        self.install = install
        self.remove = remove
        self.runScript = runScript
    }
}

enum ExtensionTools {
    private static let definition: [String: JSONValue] = [
        "id": Schema.string("短名称，只用小写字母、数字和连字符，例如 markdown-link。实际 id 为 local.<短名称>，已存在时覆盖更新"),
        "name": Schema.string("显示名称"),
        "name_zh": Schema.string("中文显示名称"),
        "description": Schema.string("一句话说明"),
        "icon": Schema.string("图标：symbol:<SF Symbol 名称>，或 text:<1 到 2 个字符>"),
        "match": [
            "type": "object",
            "description": "可选的显示条件：regex（正则，匹配时才显示）、minLength、maxLength、requiresEditable（只在可编辑文本中显示）",
        ],
        "options": [
            "type": "array",
            "description": "可选的用户设置项，每项含 id、type（string、boolean、choice）、label、defaultValue、required、choices",
            "items": ["type": "object"],
        ],
        "action": [
            "type": "object",
            "description": """
            动作，type 取值：
            url：{"type":"url","url":"https://x.com/s?q={text}","fallbackURL":"可选"}。{text} 自动编码，{option.<id>} 引用设置项，也可用 app 的 URL Scheme。
            app：{"type":"app","bundleID":"com.foo.bar","copyFirst":true}。拷贝文本后打开 app。
            copy：拷贝。paste：用剪贴板替换选区。
            script：{"type":"script"}，配合 script 参数。
            ai：{"type":"ai","system":"可选","prompt":"...{text}..."}。调用用户的模型并在小弹窗显示，提示词必须包含 {text}。
            不支持 Shell 和 AppleScript。
            """,
        ],
        "script": Schema.string("action.type 为 script 时的 JavaScript。定义 function run(input)，input 含 text 和 options；返回字符串表示替换选区，或返回对象 {replace, copy, show, open}。脚本没有网络和文件访问能力"),
    ]

    private static let required = ["id", "name", "description", "icon", "action"]

    static let list = AgentTool(
        spec: LLMToolSpec(name: "list_extensions", description: "列出已安装的浮条组件，包括是否启用、是否本地自定义。", parameters: Schema.object([:])),
        risk: .read
    ) { _, environment in
        let items = try await access(environment).list()
        return Render.ok(["extensions": .array(items.map { item in
            [
                "id": .string(item.id), "name": .string(item.name), "version": .string(item.version),
                "enabled": .bool(item.isEnabled), "local": .bool(item.isLocal), "action": .string(item.summary),
            ]
        })])
    }

    static let test = AgentTool(
        spec: LLMToolSpec(
            name: "test_extension",
            description: "验证组件定义并用样例文本试运行，不会安装，也不会打开任何东西。安装前先用它确认结果符合预期。",
            parameters: Schema.object(
                definition.merging(["sample_text": Schema.string("用来试运行的样例文本")]) { _, new in new },
                required: required + ["sample_text"]
            )
        ),
        risk: .read
    ) { arguments, environment in
        let manifest = try manifest(from: arguments)
        let sample = try text(arguments, "sample_text")
        let options = (manifest.options ?? []).reduce(into: [String: String]()) { $0[$1.id] = $1.defaultValue ?? "" }
        switch manifest.action {
        case .url(let template, _, _):
            return Render.ok(["valid": true, "would_open": .string(try TemplateRenderer.url(template, text: sample, options: options).absoluteString)])
        case .script:
            let source = try text(arguments, "script")
            let output = try await access(environment).runScript(source, ScriptInput(text: sample, options: options))
            return Render.ok([
                "valid": true,
                "replace": output.replace.map { .string($0) } ?? nil,
                "copy": output.copy.map { .string($0) } ?? nil,
                "show": output.show.map { .string($0) } ?? nil,
                "open": output.open.map { .string($0) } ?? nil,
            ])
        case .ai(_, let prompt):
            return Render.ok(["valid": true, "would_send": .string(TemplateRenderer.prompt(prompt, text: sample, options: options))])
        default:
            return Render.ok(["valid": true, "would_do": .string(ExtensionValidator.describe(manifest.action))])
        }
    }

    /// Always reviewed, even after a session-wide yes. An extension keeps acting long after this
    /// conversation ends, and the request to write one could have come from text inside a clip.
    static let create = AgentTool(
        spec: LLMToolSpec(
            name: "create_extension",
            description: "安装或更新一个本地浮条组件，用户确认后会立即出现在选中文本浮条上。",
            parameters: Schema.object(definition, required: required)
        ),
        risk: .destructive
    ) { arguments, environment in
        let manifest = try manifest(from: arguments)
        var script: String?
        if case .script = manifest.action { script = try text(arguments, "script") }

        var items = [ChangeItem(label: manifest.name.localized, after: ExtensionValidator.describe(manifest.action))]
        if let script { items.append(ChangeItem(label: "脚本内容", after: String(script.prefix(1_500)))) }
        let proposal = ChangeProposal(toolName: "create_extension", summary: "安装组件「\(manifest.name.localized)」", risk: .destructive, items: items)
        if case .rejected(let reason) = await environment.context.approvals.review(proposal) {
            return Render.rejected(reason)
        }
        try await access(environment).install(manifest, script)
        return Render.ok(["installed": .string(manifest.id)])
    }

    static let delete = AgentTool(
        spec: LLMToolSpec(
            name: "delete_extension",
            description: "删除一个本地自定义组件。市场组件不能用这个工具删除。",
            parameters: Schema.object(["id": Schema.string("组件 id，以 local. 开头")], required: ["id"])
        ),
        risk: .destructive
    ) { arguments, environment in
        let id = try text(arguments, "id")
        guard id.hasPrefix(ExtensionManifest.localPrefix) else { throw ExtensionError.notLocal(id) }
        let items = try await access(environment).list()
        guard let item = items.first(where: { $0.id == id }) else { throw AgentToolError.badArguments("没有这个组件：\(id)") }
        let proposal = ChangeProposal(toolName: "delete_extension", summary: "删除组件「\(item.name)」", risk: .destructive, items: [ChangeItem(label: item.name, before: item.summary)])
        if case .rejected(let reason) = await environment.context.approvals.review(proposal) {
            return Render.rejected(reason)
        }
        try await access(environment).remove(id)
        return Render.ok(["deleted": .string(id)])
    }

    private static func access(_ environment: ToolEnvironment) throws -> ExtensionAccess {
        guard let extensions = environment.context.extensions else { throw AgentToolError.badArguments("组件功能不可用") }
        return extensions
    }

    private static func text(_ arguments: JSONValue, _ key: String) throws -> String {
        guard let value = arguments[key]?.string, !value.isEmpty else { throw AgentToolError.badArguments("缺少 \(key)") }
        return value
    }

    /// Builds the manifest the agent described. The id is always forced into the `local.` namespace,
    /// so a generated extension can never replace one that came from the market.
    private static func manifest(from arguments: JSONValue) throws -> ExtensionManifest {
        let slug = try text(arguments, "id").replacingOccurrences(of: ExtensionManifest.localPrefix, with: "")
        var name: [String: JSONValue] = ["en": .string(try text(arguments, "name"))]
        if let chinese = arguments["name_zh"]?.string { name["zh"] = .string(chinese) }
        var fields: [String: JSONValue] = [
            "schema": .number(Double(ExtensionManifest.currentSchema)),
            "id": .string(ExtensionManifest.localPrefix + slug),
            "name": .object(name),
            "description": .string(try text(arguments, "description")),
            "version": .string("1.0.0"),
            "author": "PastAi Agent",
            "category": "custom",
            "icon": .string(try text(arguments, "icon")),
        ]
        guard var action = arguments["action"]?.object else { throw AgentToolError.badArguments("缺少 action") }
        if action["type"]?.string == "script" { action["file"] = "script.js" }
        fields["action"] = .object(action)
        if let match = arguments["match"] { fields["match"] = match }
        if let options = arguments["options"] { fields["options"] = options }

        let manifest: ExtensionManifest
        do {
            manifest = try JSONDecoder().decode(ExtensionManifest.self, from: JSONValue.object(fields).encoded())
        } catch let error as ExtensionError {
            throw error
        } catch {
            throw ExtensionError.invalidManifest("结构不正确：\(error.localizedDescription)")
        }
        try ExtensionValidator.validate(manifest)
        return manifest
    }
}
