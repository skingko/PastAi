import ClipCore
import Foundation
import os

/// Raw HTTP against `POST /v1/messages`, since there is no official Swift SDK.
///
/// Sampling parameters and forced `tool_choice` are never sent: current models answer them with a 400.
public struct AnthropicClient: LLMClient {
    static let defaultBaseURL = "https://api.anthropic.com"
    static let version = "2023-06-01"
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    let baseURL: String
    let apiKey: String
    let session: URLSession

    public init(baseURL: String, apiKey: String, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session ?? HTTPTransport.makeSession()
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let delivered = OSAllocatedUnfairLock(initialState: false)
                do {
                    try await HTTPTransport.withRetry(hasDelivered: { delivered.withLock { $0 } }) {
                        try await run(request, continuation: continuation, delivered: delivered, includeThinking: true)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func listModels() async throws -> [String] {
        var request = URLRequest(url: try HTTPTransport.endpoint(baseURL, "/v1/models?limit=100"))
        authorize(&request, betas: [])
        let parsed = try JSONDecoder().decode(JSONValue.self, from: try await HTTPTransport.get(request, session: session))
        return (parsed["data"]?.array ?? []).compactMap { $0["id"]?.string }
    }

    private var isOfficialEndpoint: Bool {
        URL(string: baseURL)?.host == "api.anthropic.com"
    }

    private func authorize(_ request: inout URLRequest, betas: [String]) {
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.version, forHTTPHeaderField: "anthropic-version")
        if !betas.isEmpty { request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
    }

    private func run(
        _ request: LLMRequest,
        continuation: AsyncThrowingStream<LLMEvent, any Error>.Continuation,
        delivered: OSAllocatedUnfairLock<Bool>,
        includeThinking: Bool
    ) async throws {
        let usesFallback = isOfficialEndpoint && Self.supportsFallback(request.model)
        var http = URLRequest(url: try HTTPTransport.endpoint(baseURL, "/v1/messages"))
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&http, betas: usesFallback ? [Self.fallbackBeta] : [])
        http.httpBody = try Self.body(
            for: request, usesFallback: usesFallback, usesCaching: isOfficialEndpoint, includeThinking: includeThinking
        ).encoded()

        let bytes: URLSession.AsyncBytes
        do {
            bytes = try await HTTPTransport.open(http, session: session)
        } catch LLMError.http(400, let message, _, _) where includeThinking && message.contains("`thinking` block") {
            // One-time recovery if stored history no longer matches what the blocks were signed against.
            return try await run(request, continuation: continuation, delivered: delivered, includeThinking: false)
        }

        var assembler = AnthropicStreamAssembler()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let event = try? JSONValue.parse(payload) else { continue }
            for output in try assembler.consume(event) {
                if case .usage = output {} else { delivered.withLock { $0 = true } }
                continuation.yield(output)
            }
        }
        for output in assembler.finish() { continuation.yield(output) }
    }

    /// Models whose safety classifiers can decline; the API then reruns the request on a fallback itself.
    static func supportsFallback(_ model: String) -> Bool {
        ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"].contains(model)
    }

    /// Older models and third-party gateways reject `output_config`, so it is opt-in by model family.
    static func supportsEffort(_ model: String) -> Bool {
        ["claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable-5", "claude-mythos-5", "claude-opus-4-8", "claude-opus-4-7"]
            .contains(where: model.hasPrefix)
    }

    static func body(for request: LLMRequest, usesFallback: Bool, usesCaching: Bool, includeThinking: Bool) throws -> JSONValue {
        var fields: [String: JSONValue] = [
            "model": .string(request.model),
            "max_tokens": .number(Double(request.maxTokens)),
            "stream": true,
            "system": .string(request.system),
            "messages": .array(encodeMessages(request.messages, includeThinking: includeThinking)),
        ]
        if !request.tools.isEmpty {
            fields["tools"] = .array(request.tools.map { tool in
                ["name": .string(tool.name), "description": .string(tool.description), "input_schema": tool.parameters]
            })
        }
        if supportsEffort(request.model) {
            fields["output_config"] = ["effort": .string(request.effort.rawValue)]
        }
        if usesFallback { fields["fallbacks"] = "default" }
        if usesCaching { fields["cache_control"] = ["type": "ephemeral"] }
        return .object(fields)
    }

    /// Consecutive tool results and the images that follow them must share one user message:
    /// splitting parallel results across messages teaches the model to stop calling tools in parallel.
    static func encodeMessages(_ messages: [LLMMessage], includeThinking: Bool) -> [JSONValue] {
        var output: [JSONValue] = []
        var pendingUser: [JSONValue] = []

        func flush() {
            guard !pendingUser.isEmpty else { return }
            output.append(["role": "user", "content": .array(pendingUser)])
            pendingUser = []
        }

        for message in messages {
            switch message.role {
            case .tool:
                pendingUser.append([
                    "type": "tool_result",
                    "tool_use_id": .string(message.toolCallID ?? ""),
                    "content": .string(message.text),
                    "is_error": .bool(message.isError),
                ])
            case .user:
                for image in message.images {
                    pendingUser.append([
                        "type": "image",
                        "source": ["type": "base64", "media_type": .string(image.mediaType), "data": .string(image.base64)],
                    ])
                }
                if !message.text.isEmpty { pendingUser.append(["type": "text", "text": .string(message.text)]) }
            case .assistant:
                flush()
                output.append(["role": "assistant", "content": .array(assistantContent(message, includeThinking: includeThinking))])
            }
        }
        flush()
        return output
    }

    private static func assistantContent(_ message: LLMMessage, includeThinking: Bool) -> [JSONValue] {
        if let blocks = message.anthropicBlocks {
            if includeThinking { return blocks }
            return blocks.filter { !["thinking", "redacted_thinking"].contains($0["type"]?.string ?? "") }
        }
        // History written by another provider has no raw blocks; rebuild the plain equivalent.
        var content: [JSONValue] = []
        if !message.text.isEmpty { content.append(["type": "text", "text": .string(message.text)]) }
        for call in message.toolCalls {
            let input = (try? JSONValue.parse(call.argumentsJSON)) ?? [:]
            content.append(["type": "tool_use", "id": .string(call.id), "name": .string(call.name), "input": input])
        }
        return content
    }
}

/// Rebuilds content blocks from SSE events so the assistant turn can be replayed exactly.
struct AnthropicStreamAssembler {
    private struct Block {
        var fields: [String: JSONValue]
        var text = ""
        var thinking = ""
        var signature: String?
        var partialJSON = ""
    }

    private var blocks: [Int: Block] = [:]
    private var order: [Int] = []
    private var stopReason: String?
    private var refusalCategory: String?
    private var inputTokens = 0
    private var outputTokens = 0

    mutating func consume(_ event: JSONValue) throws -> [LLMEvent] {
        switch event["type"]?.string {
        case "message_start":
            inputTokens = event["message"]?["usage"]?["input_tokens"]?.int ?? 0
            return []

        case "content_block_start":
            guard let index = event["index"]?.int, let start = event["content_block"]?.object else { return [] }
            blocks[index] = Block(fields: start)
            order.append(index)
            // Tool calls before a fallback belong to a declined attempt and must never run.
            return start["type"]?.string == "fallback" ? [.discardToolCalls] : []

        case "content_block_delta":
            guard let index = event["index"]?.int, let delta = event["delta"] else { return [] }
            switch delta["type"]?.string {
            case "text_delta":
                let text = delta["text"]?.string ?? ""
                blocks[index]?.text += text
                return text.isEmpty ? [] : [.textDelta(text)]
            case "input_json_delta":
                blocks[index]?.partialJSON += delta["partial_json"]?.string ?? ""
            case "thinking_delta":
                blocks[index]?.thinking += delta["thinking"]?.string ?? ""
            case "signature_delta":
                blocks[index]?.signature = delta["signature"]?.string
            default:
                break
            }
            return []

        case "content_block_stop":
            guard let index = event["index"]?.int, let block = blocks[index], block.fields["type"]?.string == "tool_use" else { return [] }
            let call = LLMToolCall(
                id: block.fields["id"]?.string ?? "",
                name: block.fields["name"]?.string ?? "",
                argumentsJSON: block.partialJSON.isEmpty ? "{}" : block.partialJSON
            )
            return [.toolCall(call)]

        case "message_delta":
            if let reason = event["delta"]?["stop_reason"]?.string { stopReason = reason }
            if let category = event["delta"]?["stop_details"]?["category"]?.string { refusalCategory = category }
            if let output = event["usage"]?["output_tokens"]?.int { outputTokens = output }
            return []

        case "error":
            throw LLMError.invalidResponse(event["error"]?["message"]?.string ?? L("流式响应出错"))

        default:
            return []
        }
    }

    mutating func finish() -> [LLMEvent] {
        var events: [LLMEvent] = [.usage(input: inputTokens, output: outputTokens), .assistantBlocks(replayableBlocks())]
        let stop: LLMStopReason
        switch stopReason {
        case "end_turn", "stop_sequence", nil: stop = .endTurn
        case "tool_use": stop = .toolUse
        case "max_tokens": stop = .maxTokens
        case "refusal": stop = .refusal(refusalCategory)
        case let other?: stop = .other(other)
        }
        events.append(.stopped(stop))
        return events
    }

    /// After a fallback, thinking and tool_use blocks before the switch point must not be echoed.
    /// The fallback marker itself carries nothing the model needs.
    private func replayableBlocks() -> [JSONValue] {
        let rebuilt = order.compactMap { blocks[$0] }
        let lastFallback = rebuilt.lastIndex { $0.fields["type"]?.string == "fallback" }
        var output: [JSONValue] = []
        for (position, block) in rebuilt.enumerated() {
            let type = block.fields["type"]?.string
            if let lastFallback, position < lastFallback, type != "text" { continue }
            if type == "fallback" { continue }
            var fields = block.fields
            switch type {
            case "text":
                fields["text"] = .string(block.text)
            case "thinking":
                fields["thinking"] = .string(block.thinking)
                if let signature = block.signature { fields["signature"] = .string(signature) }
            case "tool_use":
                fields["input"] = (try? JSONValue.parse(block.partialJSON.isEmpty ? "{}" : block.partialJSON)) ?? [:]
            default:
                break
            }
            output.append(.object(fields))
        }
        return output
    }
}
