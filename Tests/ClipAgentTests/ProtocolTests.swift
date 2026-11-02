import Foundation
import os
import Testing
@testable import ClipAgent

/// Answers URLSession requests from a script, delivering the body in separate chunks like a real stream.
final class StubProtocol: URLProtocol {
    struct Reply: Sendable {
        var status = 200
        var chunks: [String]
    }

    private static let state = OSAllocatedUnfairLock(initialState: (replies: [Reply](), requests: [URLRequest](), bodies: [Data]()))

    static func script(_ replies: [Reply]) {
        state.withLock { $0 = (replies, [], []) }
    }

    static var bodies: [JSONValue] {
        state.withLock { $0.bodies }.compactMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    }

    static var requests: [URLRequest] { state.withLock { $0.requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let captured = request
        let received = body
        let reply = Self.state.withLock { state -> Reply? in
            state.requests.append(captured)
            state.bodies.append(received)
            return state.replies.isEmpty ? nil : state.replies.removeFirst()
        } ?? Reply(status: 500, chunks: ["no scripted reply"])
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks {
            client?.urlProtocol(self, didLoad: Data(chunk.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private func collect(_ client: any LLMClient, _ request: LLMRequest) async throws -> [LLMEvent] {
    var events: [LLMEvent] = []
    for try await event in client.stream(request) { events.append(event) }
    return events
}

private func text(_ events: [LLMEvent]) -> String {
    events.compactMap { if case .textDelta(let delta) = $0 { delta } else { nil } }.joined()
}

private func calls(_ events: [LLMEvent]) -> [LLMToolCall] {
    events.compactMap { if case .toolCall(let call) = $0 { call } else { nil } }
}

private func stop(_ events: [LLMEvent]) -> LLMStopReason? {
    events.compactMap { if case .stopped(let reason) = $0 { reason } else { nil } }.last
}

private func sse(_ events: [JSONValue]) -> [String] {
    events.map { "event: \($0["type"]?.string ?? "x")\ndata: \($0.jsonString)\n\n" }
}

private let sampleRequest = LLMRequest(
    model: "test-model", system: "SYSTEM",
    messages: [LLMMessage(role: .user, text: "hi")],
    tools: [LLMToolSpec(name: "search_clips", description: "d", parameters: ["type": "object"])]
)

/// The stub is process-wide, so every suite that scripts it runs one test at a time.
@Suite(.serialized) enum StubbedHTTP {}

extension StubbedHTTP {
@Suite struct OpenAICompatibleTests {
    let client = OpenAICompatibleClient(baseURL: "https://example.test/v1/", apiKey: "secret", session: StubProtocol.session())

    @Test func reassemblesStreamedTextAndToolCallFragments() async throws {
        StubProtocol.script([.init(chunks: [
            #"data: {"choices":[{"delta":{"content":"你"}}]}"# + "\n\n",
            #"data: {"choices":[{"delta":{"content":"好"}}]}"# + "\n\n",
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"search_clips","arguments":"{\"qu"}}]}}]}"# + "\n\n",
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ery\":\"部署\"}"}}]}}]}"# + "\n\n",
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_2","function":{"name":"stats","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"# + "\n\n",
            #"data: {"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":7}}"# + "\n\n",
            "data: [DONE]\n\n",
        ])])
        let events = try await collect(client, sampleRequest)

        #expect(text(events) == "你好")
        #expect(calls(events).map(\.name) == ["search_clips", "stats"])
        #expect(try JSONValue.parse(calls(events)[0].argumentsJSON)["query"]?.string == "部署")
        #expect(stop(events) == .toolUse)
        #expect(events.contains { if case .usage(11, 7) = $0 { true } else { false } })
    }

    @Test func requestShapeMatchesTheChatCompletionsContract() async throws {
        StubProtocol.script([.init(chunks: ["data: [DONE]\n\n"])])
        let history = [
            LLMMessage(role: .user, text: "看图", images: [LLMImage(mediaType: "image/jpeg", base64: "AAAA")]),
            LLMMessage(role: .assistant, toolCalls: [LLMToolCall(id: "c1", name: "stats", argumentsJSON: "{}")], reasoning: "因为"),
            LLMMessage(role: .tool, text: "结果", toolCallID: "c1", toolName: "stats"),
        ]
        var request = sampleRequest
        request.messages = history
        _ = try await collect(client, request)

        #expect(StubProtocol.requests[0].url?.absoluteString == "https://example.test/v1/chat/completions")
        #expect(StubProtocol.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let body = try #require(StubProtocol.bodies.first)
        #expect(body["max_tokens"] == nil)
        #expect(body["stream"]?.bool == true)
        let messages = try #require(body["messages"]?.array)
        #expect(messages[0]["role"]?.string == "system")
        #expect(messages[0]["content"]?.string == "SYSTEM")
        #expect(messages[1]["content"]?.array?[1]["image_url"]?["url"]?.string == "data:image/jpeg;base64,AAAA")
        #expect(messages[2]["content"]?.string == "")
        #expect(messages[2]["reasoning_content"]?.string == "因为")
        #expect(messages[2]["tool_calls"]?.array?[0]["function"]?["name"]?.string == "stats")
        #expect(messages[3]["role"]?.string == "tool")
        #expect(messages[3]["tool_call_id"]?.string == "c1")
        #expect(body["tools"]?.array?[0]["function"]?["name"]?.string == "search_clips")
    }

    @Test func ollamaStyleCallsWithoutIdStillGetOne() async throws {
        StubProtocol.script([.init(chunks: [
            #"data: {"choices":[{"delta":{"tool_calls":[{"function":{"name":"stats","arguments":"{}"}}]}}]}"# + "\n\n",
            "data: [DONE]\n\n",
        ])])
        let events = try await collect(client, sampleRequest)
        #expect(calls(events).first?.id.isEmpty == false)
        #expect(stop(events) == .toolUse)
    }

    @Test func serverRejectingStreamOptionsIsRetriedWithoutThem() async throws {
        StubProtocol.script([
            .init(status: 400, chunks: [#"{"error":{"message":"unknown field stream_options"}}"#]),
            .init(chunks: [#"data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"# + "\n\n", "data: [DONE]\n\n"]),
        ])
        let events = try await collect(client, sampleRequest)
        #expect(text(events) == "ok")
        #expect(StubProtocol.bodies[0]["stream_options"] != nil)
        #expect(StubProtocol.bodies[1]["stream_options"] == nil)
    }

    @Test func httpErrorSurfacesTheProviderMessage() async throws {
        StubProtocol.script([.init(status: 401, chunks: [#"{"error":{"message":"bad key"}}"#])])
        await #expect(throws: LLMError.http(status: 401, message: "bad key")) {
            _ = try await collect(client, sampleRequest)
        }
    }

    @Test func zhipuPlanErrorKeepsItsCodeAndIsNotRetried() async throws {
        StubProtocol.script([.init(status: 429, chunks: [#"{"error":{"code":"1311","message":"当前订阅套餐暂未开放 glm-5.3-flashx 模型权限"}}"#])])
        do {
            _ = try await collect(client, sampleRequest)
            Issue.record("expected a failure")
        } catch let error as LLMError {
            #expect(error.title == "当前套餐不包含这个模型")
            #expect(error.detail?.contains("错误码 1311") == true)
            #expect(error.detail?.contains("glm-5.3-flashx") == true)
        }
        #expect(StubProtocol.requests.count == 1, "plan refusals must not be repeated")
    }

    @Test func numericProviderCodesAreRead() async throws {
        StubProtocol.script([.init(status: 429, chunks: [#"{"error":{"code":1313,"message":"fair use"}}"#])])
        await #expect(throws: LLMError.http(status: 429, message: "fair use", code: "1313")) {
            _ = try await collect(client, sampleRequest)
        }
        #expect(StubProtocol.requests.count == 1)
    }

    @Test func rateLimitWithoutACodeIsStillRetried() async throws {
        StubProtocol.script([
            .init(status: 429, chunks: [#"{"error":{"message":"slow down"}}"#]),
            .init(chunks: [#"data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"# + "\n\n", "data: [DONE]\n\n"]),
        ])
        #expect(text(try await collect(client, sampleRequest)) == "ok")
    }

    @Test func zhipuRateLimitCodeIsRetried() async throws {
        StubProtocol.script([
            .init(status: 429, chunks: [#"{"error":{"code":"1302","message":"并发过高"}}"#]),
            .init(chunks: [#"data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"# + "\n\n", "data: [DONE]\n\n"]),
        ])
        #expect(text(try await collect(client, sampleRequest)) == "ok")
    }

    @Test func connectionProbeReportsReplyAndSendsOneTool() async throws {
        StubProtocol.script([.init(chunks: [#"data: {"choices":[{"delta":{"content":"OK"},"finish_reason":"stop"}]}"# + "\n\n", "data: [DONE]\n\n"])])
        #expect(try await ConnectionProbe.run(client: client, model: "m") == "OK")
        #expect(StubProtocol.bodies[0]["tools"]?.array?.count == 1)
    }

    @Test func noArgumentToolsOmitRequired() {
        let tool = ClipToolbox.stats.spec.parameters
        #expect(tool["required"] == nil)
        #expect(ClipToolbox.getClips.spec.parameters["required"]?.array?.count == 1)
    }

    @Test func transientFailureBeforeAnyOutputIsRetried() async throws {
        StubProtocol.script([
            .init(status: 503, chunks: ["overloaded"]),
            .init(chunks: [#"data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"# + "\n\n", "data: [DONE]\n\n"]),
        ])
        #expect(text(try await collect(client, sampleRequest)) == "ok")
        #expect(StubProtocol.requests.count == 2)
    }

    @Test func listsModels() async throws {
        StubProtocol.script([.init(chunks: [#"{"data":[{"id":"b"},{"id":"a"}]}"#])])
        #expect(try await client.listModels() == ["a", "b"])
    }
}

@Suite struct AnthropicTests {
    let official = AnthropicClient(baseURL: "https://api.anthropic.com", apiKey: "sk-test", session: StubProtocol.session())
    let gateway = AnthropicClient(baseURL: "https://proxy.example.test", apiKey: "sk-test", session: StubProtocol.session())

    let turnWithThinkingAndTool: [JSONValue] = [
        ["type": "message_start", "message": ["usage": ["input_tokens": 20]]],
        ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": "", "signature": ""]],
        ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "想一想"]],
        ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "SIG"]],
        ["type": "content_block_stop", "index": 0],
        ["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": ""]],
        ["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": "查一下"]],
        ["type": "content_block_stop", "index": 1],
        ["type": "content_block_start", "index": 2, "content_block": ["type": "tool_use", "id": "toolu_1", "name": "search_clips", "input": [:]]],
        ["type": "content_block_delta", "index": 2, "delta": ["type": "input_json_delta", "partial_json": "{\"query\":"]],
        ["type": "content_block_delta", "index": 2, "delta": ["type": "input_json_delta", "partial_json": "\"部署\"}"]],
        ["type": "content_block_stop", "index": 2],
        ["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 9]],
        ["type": "message_stop"],
    ]

    @Test func keepsThinkingBlocksVerbatimForReplay() async throws {
        StubProtocol.script([.init(chunks: sse(turnWithThinkingAndTool))])
        let events = try await collect(official, sampleRequest)

        #expect(text(events) == "查一下")
        #expect(calls(events).first?.name == "search_clips")
        #expect(stop(events) == .toolUse)
        let blocks = try #require(events.compactMap { if case .assistantBlocks(let blocks) = $0 { blocks } else { nil } }.first)
        #expect(blocks.map { $0["type"]?.string } == ["thinking", "text", "tool_use"])
        #expect(blocks[0]["thinking"]?.string == "想一想")
        #expect(blocks[0]["signature"]?.string == "SIG")
        #expect(blocks[2]["input"]?["query"]?.string == "部署")
    }

    @Test func requestNeverCarriesParametersCurrentModelsReject() async throws {
        StubProtocol.script([.init(chunks: sse([["type": "message_stop"]]))])
        var request = sampleRequest
        request.model = "claude-opus-5-5"
        _ = try await collect(official, request)

        let body = try #require(StubProtocol.bodies.first)
        for rejected in ["temperature", "top_p", "top_k", "tool_choice", "thinking"] {
            #expect(body[rejected] == nil, "\(rejected) must not be sent")
        }
        #expect(body["max_tokens"]?.int == 64_000)
        #expect(body["system"]?.string == "SYSTEM")
        #expect(body["output_config"]?["effort"]?.string == "medium")
        #expect(body["tools"]?.array?[0]["input_schema"]?["type"]?.string == "object")
        let http = StubProtocol.requests[0]
        #expect(http.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(http.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(http.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }

    @Test func refusalFallbackIsOnForOfficialEndpointOnly() async throws {
        var request = sampleRequest
        request.model = "claude-opus-5-5"

        StubProtocol.script([.init(chunks: sse([["type": "message_stop"]]))])
        _ = try await collect(official, request)
        #expect(StubProtocol.bodies[0]["fallbacks"]?.string == "default")
        #expect(StubProtocol.requests[0].value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")

        StubProtocol.script([.init(chunks: sse([["type": "message_stop"]]))])
        _ = try await collect(gateway, request)
        #expect(StubProtocol.bodies[0]["fallbacks"] == nil)
        #expect(StubProtocol.bodies[0]["cache_control"] == nil)
        #expect(StubProtocol.requests[0].value(forHTTPHeaderField: "anthropic-beta") == nil)
    }

    @Test func olderModelsGetNoEffortParameter() throws {
        let body = try AnthropicClient.body(
            for: LLMRequest(model: "claude-haiku-4-5", system: "s", messages: []),
            usesFallback: false, usesCaching: false, includeThinking: true
        )
        #expect(body["output_config"] == nil)
    }

    @Test func parallelToolResultsShareOneUserMessageWithTheirImages() {
        let messages = [
            LLMMessage(role: .user, text: "问"),
            LLMMessage(role: .assistant, toolCalls: [
                LLMToolCall(id: "a", name: "stats", argumentsJSON: "{}"),
                LLMToolCall(id: "b", name: "view_media", argumentsJSON: #"{"id":1}"#),
            ]),
            LLMMessage(role: .tool, text: "1", toolCallID: "a", isError: true),
            LLMMessage(role: .tool, text: "2", toolCallID: "b"),
            LLMMessage(role: .user, text: "图", images: [LLMImage(mediaType: "image/jpeg", base64: "AA")]),
        ]
        let encoded = AnthropicClient.encodeMessages(messages, includeThinking: true)

        #expect(encoded.count == 3)
        #expect(encoded[1]["content"]?.array?.compactMap { $0["type"]?.string } == ["tool_use", "tool_use"])
        #expect(encoded[1]["content"]?.array?[1]["input"]?["id"]?.int == 1)
        let results = encoded[2]["content"]?.array ?? []
        #expect(results.compactMap { $0["type"]?.string } == ["tool_result", "tool_result", "image", "text"])
        #expect(results[0]["is_error"]?.bool == true)
        #expect(results[2]["source"]?["media_type"]?.string == "image/jpeg")
    }

    @Test func refusalStopsWithCategory() async throws {
        StubProtocol.script([.init(chunks: sse([
            ["type": "message_delta", "delta": ["stop_reason": "refusal", "stop_details": ["category": "cyber"]], "usage": ["output_tokens": 0]],
        ]))])
        #expect(stop(try await collect(official, sampleRequest)) == .refusal("cyber"))
    }

    @Test func toolCallsBeforeAFallbackAreDiscardedAndNotReplayed() async throws {
        StubProtocol.script([.init(chunks: sse([
            ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": "", "signature": ""]],
            ["type": "content_block_stop", "index": 0],
            ["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": ""]],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": "前半"]],
            ["type": "content_block_stop", "index": 1],
            ["type": "content_block_start", "index": 2, "content_block": ["type": "tool_use", "id": "declined", "name": "delete_clips", "input": [:]]],
            ["type": "content_block_stop", "index": 2],
            ["type": "content_block_start", "index": 3, "content_block": ["type": "fallback", "from": ["model": "a"], "to": ["model": "b"]]],
            ["type": "content_block_stop", "index": 3],
            ["type": "content_block_start", "index": 4, "content_block": ["type": "text", "text": ""]],
            ["type": "content_block_delta", "index": 4, "delta": ["type": "text_delta", "text": "后半"]],
            ["type": "content_block_stop", "index": 4],
            ["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 3]],
        ]))])
        let events = try await collect(official, sampleRequest)

        var surviving: [LLMToolCall] = []
        for event in events {
            if case .toolCall(let call) = event { surviving.append(call) }
            if case .discardToolCalls = event { surviving = [] }
        }
        #expect(surviving.isEmpty)
        #expect(text(events) == "前半后半")
        let blocks = try #require(events.compactMap { if case .assistantBlocks(let blocks) = $0 { blocks } else { nil } }.first)
        #expect(blocks.map { $0["type"]?.string } == ["text", "text"])
    }

    @Test func invalidThinkingSignatureRecoversOnceWithoutThinking() async throws {
        let blocks: [JSONValue] = [["type": "thinking", "thinking": "x", "signature": "old"], ["type": "text", "text": "答"]]
        var request = sampleRequest
        request.messages = [LLMMessage(role: .user, text: "问"), LLMMessage(role: .assistant, text: "答", anthropicBlocks: blocks), LLMMessage(role: .user, text: "再问")]
        StubProtocol.script([
            .init(status: 400, chunks: [#"{"error":{"message":"messages.1.content.0: Invalid `signature` in `thinking` block."}}"#]),
            .init(chunks: sse([["type": "message_stop"]])),
        ])
        _ = try await collect(official, request)

        func assistantTypes(_ body: JSONValue) -> [String?] {
            body["messages"]?.array?[1]["content"]?.array?.map { $0["type"]?.string } ?? []
        }
        #expect(assistantTypes(StubProtocol.bodies[0]) == ["thinking", "text"])
        #expect(assistantTypes(StubProtocol.bodies[1]) == ["text"])
    }

    @Test func midStreamErrorEventThrows() async throws {
        StubProtocol.script([.init(chunks: sse([["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]]]))])
        await #expect(throws: LLMError.invalidResponse("Overloaded")) {
            _ = try await collect(official, sampleRequest)
        }
    }
}

}

@Suite struct JSONValueTests {
    @Test func integersEncodeWithoutFractions() {
        #expect(JSONValue.object(["id": .number(12)]).jsonString == #"{"id":12}"#)
        #expect(JSONValue.number(1.5).jsonString == "1.5")
    }

    @Test func encodingIsDeterministic() {
        let value: JSONValue = ["b": 1, "a": ["z": true, "c": nil], "url": "http://a/b"]
        #expect(value.jsonString == #"{"a":{"c":null,"z":true},"b":1,"url":"http://a/b"}"#)
    }

    @Test func roundTripsThroughCodable() throws {
        let value: JSONValue = ["text": "中文", "list": [1, "x", false, nil]]
        #expect(try JSONValue.parse(value.jsonString) == value)
    }
}

@Suite struct ProviderTests {
    @Test func localProvidersAreRecognised() {
        #expect(ModelProvider(name: "x", format: .openAICompatible, baseURL: "http://127.0.0.1:11434/v1").isLocal)
        #expect(ModelProvider(name: "x", format: .openAICompatible, baseURL: "http://localhost:1234/v1").isLocal)
        #expect(ModelProvider(name: "x", format: .openAICompatible, baseURL: "http://studio.local:1234/v1").isLocal)
        #expect(!ModelProvider(name: "x", format: .openAICompatible, baseURL: "https://api.openai.com/v1").isLocal)
    }

    @Test func invalidBaseURLIsReported() async {
        let client = OpenAICompatibleClient(baseURL: "not a url", apiKey: "")
        await #expect(throws: LLMError.invalidBaseURL("not a url")) {
            _ = try await collect(client, sampleRequest)
        }
    }

    @Test func parsesJSONWrappedInCommentary() throws {
        let parsed = try BulkProcessor.parseJSONObject("好的：\n```json\n{\"results\":[{\"id\":1}]}\n```")
        #expect(parsed["results"]?.array?.count == 1)
    }
}
