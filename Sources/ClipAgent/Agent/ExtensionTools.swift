import ClipCore
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
        "id": Schema.string("Short name using lowercase letters, digits and hyphens, such as markdown-link. The real id is local.<short name>, and an existing one is updated"),
        "name": Schema.string("Display name"),
        "name_zh": Schema.string("Display name in Chinese"),
        "description": Schema.string("One-sentence description"),
        "icon": Schema.string("Icon: symbol:<SF Symbol name> or text:<1 or 2 characters>"),
        "match": [
            "type": "object",
            "description": "Optional conditions for showing it: regex (shown only on a match), minLength, maxLength, requiresEditable (shown only in editable text)",
        ],
        "options": [
            "type": "array",
            "description": "Optional user settings, each with id, type (string, boolean, choice), label, defaultValue, required, choices",
            "items": ["type": "object"],
        ],
        "action": [
            "type": "object",
            "description": """
            The action. type is one of:
            url: {"type":"url","url":"https://x.com/s?q={text}","fallbackURL":"optional"}. {text} is encoded automatically, {option.<id>} reads a setting, and app URL schemes work too.
            app: {"type":"app","bundleID":"com.foo.bar","copyFirst":true}. Copies the text, then opens the app.
            copy: copies. paste: replaces the selection with the clipboard.
            script: {"type":"script"}, together with the script argument.
            ai: {"type":"ai","system":"optional","prompt":"...{text}..."}. Calls the user's model and shows the result in a small popover. The prompt must contain {text}.
            Shell and AppleScript are not supported.
            """,
        ],
        "script": Schema.string("JavaScript for action.type script. Define function run(input), where input has text, options and language (en or zh). Return a string to replace the selection, or an object {replace, copy, show, open}. Scripts have no network or file access"),
    ]

    private static let required = ["id", "name", "description", "icon", "action"]

    static let list = AgentTool(
        spec: LLMToolSpec(name: "list_extensions", description: "List installed toolbar extensions, including whether each is enabled and whether it is a local one.", parameters: Schema.object([:])),
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
            description: "Validate an extension and try it on sample text, without installing it or opening anything. Use this before installing to confirm the result.",
            parameters: Schema.object(
                definition.merging(["sample_text": Schema.string("Sample text to try it on")]) { _, new in new },
                required: required + ["sample_text"]
            )
        ),
        risk: .read
    ) { arguments, environment in
        let manifest = try manifest(from: arguments)
        let sample = try text(arguments, "sample_text")
        let options = (manifest.options ?? []).reduce(into: [String: String]()) { $0[$1.id] = $1.resolvedDefault ?? "" }
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
            description: "Install or update a local toolbar extension. Once the user approves, it appears on the selected-text toolbar right away.",
            parameters: Schema.object(definition, required: required)
        ),
        risk: .destructive
    ) { arguments, environment in
        let manifest = try manifest(from: arguments)
        var script: String?
        if case .script = manifest.action { script = try text(arguments, "script") }

        var items = [ChangeItem(label: manifest.name.localized, after: ExtensionValidator.describe(manifest.action))]
        if let script { items.append(ChangeItem(label: L("脚本内容"), after: String(script.prefix(1_500)))) }
        let proposal = ChangeProposal(toolName: "create_extension", summary: L("安装组件「\(manifest.name.localized)」"), risk: .destructive, items: items)
        if case .rejected(let reason) = await environment.context.approvals.review(proposal) {
            return Render.rejected(reason)
        }
        try await access(environment).install(manifest, script)
        return Render.ok(["installed": .string(manifest.id)])
    }

    static let delete = AgentTool(
        spec: LLMToolSpec(
            name: "delete_extension",
            description: "Delete a local extension. Market extensions cannot be deleted with this tool.",
            parameters: Schema.object(["id": Schema.string("Extension id, starting with local.")], required: ["id"])
        ),
        risk: .destructive
    ) { arguments, environment in
        let id = try text(arguments, "id")
        guard id.hasPrefix(ExtensionManifest.localPrefix) else { throw ExtensionError.notLocal(id) }
        let items = try await access(environment).list()
        guard let item = items.first(where: { $0.id == id }) else { throw AgentToolError.badArguments("No such extension: \(id)") }
        let proposal = ChangeProposal(toolName: "delete_extension", summary: L("删除组件「\(item.name)」"), risk: .destructive, items: [ChangeItem(label: item.name, before: item.summary)])
        if case .rejected(let reason) = await environment.context.approvals.review(proposal) {
            return Render.rejected(reason)
        }
        try await access(environment).remove(id)
        return Render.ok(["deleted": .string(id)])
    }

    private static func access(_ environment: ToolEnvironment) throws -> ExtensionAccess {
        guard let extensions = environment.context.extensions else { throw AgentToolError.badArguments("Extensions are not available") }
        return extensions
    }

    private static func text(_ arguments: JSONValue, _ key: String) throws -> String {
        guard let value = arguments[key]?.string, !value.isEmpty else { throw AgentToolError.badArguments("Missing \(key)") }
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
        guard var action = arguments["action"]?.object else { throw AgentToolError.badArguments("Missing action") }
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
            throw ExtensionError.invalidManifest(L("结构不正确：\(error.localizedDescription)"))
        }
        try ExtensionValidator.validate(manifest)
        return manifest
    }
}
