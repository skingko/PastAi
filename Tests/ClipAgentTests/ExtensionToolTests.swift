import ClipCore
import ClipExtensions
import Foundation
import os
import Testing
@testable import ClipAgent

/// An in-memory stand-in for the app's extension library.
private final class FakeExtensions: @unchecked Sendable {
    let state = OSAllocatedUnfairLock(initialState: [String: (ExtensionManifest, String?)]())

    var installed: [String: (ExtensionManifest, String?)] { state.withLock { $0 } }

    var access: ExtensionAccess {
        ExtensionAccess(
            list: { [self] in
                state.withLock { items in
                    items.values.map { manifest, _ in
                        ExtensionSummary(
                            id: manifest.id, name: manifest.name.en, version: manifest.version, isEnabled: true,
                            isLocal: manifest.isLocal, summary: ExtensionValidator.describe(manifest.action)
                        )
                    }
                }
            },
            install: { [self] manifest, script in state.withLock { $0[manifest.id] = (manifest, script) } },
            remove: { [self] id in state.withLock { _ = $0.removeValue(forKey: id) } },
            runScript: { source, input in try ScriptEngine.evaluate(source: source, input: input) }
        )
    }
}

private let linkTool: JSONValue = [
    "id": "markdown-link",
    "name": "Markdown Link",
    "name_zh": "转 Markdown 链接",
    "description": "把网址包成 Markdown 链接",
    "icon": "symbol:link",
    "action": ["type": "script"],
    "script": "function run(input) { return '[' + input.text + '](' + input.text + ')'; }",
    "match": ["regex": "^https?://"],
]

private func merged(_ base: JSONValue, _ extra: [String: JSONValue]) -> JSONValue {
    .object((base.object ?? [:]).merging(extra) { _, new in new })
}

@Suite struct ExtensionToolTests {
    @Test func createInstallsALocalExtensionAfterApproval() async throws {
        let service = try makeAgentService()
        let extensions = FakeExtensions()
        let client = ScriptedClient([[call("create_extension", linkTool), .stopped(.toolUse)]])
        let reviewer = Reviewer()
        let result = await run(client: client, service: service, reviewer: reviewer, extensions: extensions.access)

        #expect(result.failure == nil)
        let (manifest, script) = try #require(extensions.installed["local.markdown-link"])
        #expect(manifest.isLocal)
        #expect(manifest.name.zh == "转 Markdown 链接")
        #expect(script?.contains("function run") == true)
        #expect(reviewer.proposals.first?.risk == .destructive)
    }

    @Test func proposalShowsTheScriptBeforeAnythingIsInstalled() async throws {
        let service = try makeAgentService()
        let extensions = FakeExtensions()
        let client = ScriptedClient([[call("create_extension", linkTool), .stopped(.toolUse)]])
        let reviewer = Reviewer { _ in .rejected(reason: nil) }
        _ = await run(client: client, service: service, reviewer: reviewer, extensions: extensions.access)

        let items = try #require(reviewer.proposals.first).items
        #expect(items.contains { $0.after?.contains("function run") == true })
        #expect(extensions.installed.isEmpty)
    }

    @Test func aSessionWideYesDoesNotCoverInstalling() async throws {
        let service = try makeAgentService()
        let extensions = FakeExtensions()
        let client = ScriptedClient([
            [call("create_pinboard", ["name": "x"]), .stopped(.toolUse)],
            [call("create_extension", linkTool), .stopped(.toolUse)],
        ])
        let reviewer = Reviewer { proposal in proposal.risk == .reversible ? .approvedForSession : .rejected(reason: nil) }
        _ = await run(client: client, service: service, reviewer: reviewer, extensions: extensions.access)
        #expect(reviewer.proposals.map(\.toolName) == ["create_pinboard", "create_extension"])
        #expect(extensions.installed.isEmpty)
    }

    @Test func aMarketIDCannotBeOverwritten() async throws {
        let service = try makeAgentService()
        let extensions = FakeExtensions()
        let tool = merged(linkTool, ["id": "io.github.skingko.pastai.google"])
        let client = ScriptedClient([[call("create_extension", tool), .stopped(.toolUse)]])
        _ = await run(client: client, service: service, extensions: extensions.access)
        #expect(extensions.installed["io.github.skingko.pastai.google"] == nil)
    }

    @Test(arguments: [
        ["type": "shell", "command": "rm -rf ~"] as JSONValue,
        ["type": "url", "url": "file:///etc/passwd?{text}"] as JSONValue,
        ["type": "url", "url": "shortcuts://run-shortcut?name={text}"] as JSONValue,
        ["type": "ai", "prompt": "没有引用选中内容"] as JSONValue,
    ])
    func dangerousOrInvalidActionsNeverReachApproval(action: JSONValue) async throws {
        let service = try makeAgentService()
        let extensions = FakeExtensions()
        let tool = merged(linkTool, ["action": action])
        let client = ScriptedClient([[call("create_extension", tool), .stopped(.toolUse)]])
        let reviewer = Reviewer()
        let result = await run(client: client, service: service, reviewer: reviewer, extensions: extensions.access)

        #expect(reviewer.proposals.isEmpty)
        #expect(extensions.installed.isEmpty)
        #expect(result.toolResult("create_extension")?.isError == true)
    }

    @Test func testToolRunsTheScriptWithoutInstalling() async throws {
        let service = try makeAgentService()
        let extensions = FakeExtensions()
        let tool = merged(linkTool, ["sample_text": "https://a.test"])
        let client = ScriptedClient([[call("test_extension", tool), .stopped(.toolUse)]])
        let reviewer = Reviewer()
        let result = await run(client: client, service: service, reviewer: reviewer, extensions: extensions.access)

        #expect(result.toolResult("test_extension")?.text.contains("[https://a.test](https://a.test)") == true)
        #expect(reviewer.proposals.isEmpty)
        #expect(extensions.installed.isEmpty)
    }

    @Test func testToolShowsTheRenderedURL() async throws {
        let service = try makeAgentService()
        let extensions = FakeExtensions()
        let tool = merged(linkTool, ["action": ["type": "url", "url": "https://s.test/?q={text}"], "sample_text": "你好"])
        let client = ScriptedClient([[call("test_extension", tool), .stopped(.toolUse)]])
        let result = await run(client: client, service: service, extensions: extensions.access)
        #expect(result.toolResult("test_extension")?.text.contains("%E4%BD%A0%E5%A5%BD") == true)
    }

    @Test func deleteIsLimitedToLocalExtensions() async throws {
        let service = try makeAgentService()
        let extensions = FakeExtensions()
        let client = ScriptedClient([
            [call("create_extension", linkTool), .stopped(.toolUse)],
            [call("delete_extension", ["id": "io.github.skingko.pastai.google"]), .stopped(.toolUse)],
            [call("delete_extension", ["id": "local.markdown-link"]), .stopped(.toolUse)],
        ])
        let result = await run(client: client, service: service, extensions: extensions.access)

        #expect(result.messages.first { $0.toolName == "delete_extension" }?.isError == true)
        #expect(extensions.installed.isEmpty)
    }

    @Test func extensionsListThroughTheAgent() async throws {
        let service = try makeAgentService()
        let extensions = FakeExtensions()
        let client = ScriptedClient([
            [call("create_extension", linkTool), .stopped(.toolUse)],
            [call("list_extensions"), .stopped(.toolUse)],
        ])
        let result = await run(client: client, service: service, extensions: extensions.access)
        #expect(result.toolResult("list_extensions")?.text.contains("local.markdown-link") == true)
    }
}
