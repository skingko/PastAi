import Foundation
import os

/// `/chat/completions` with SSE. Covers OpenAI, DeepSeek, Qwen, Kimi, GLM, Gemini's compatibility
/// endpoint, OpenRouter, Ollama and LM Studio.
public struct OpenAICompatibleClient: LLMClient {
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
                        try await run(request, continuation: continuation, delivered: delivered, includeUsage: true)
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
        var request = URLRequest(url: try HTTPTransport.endpoint(baseURL, "/models"))
        authorize(&request)
        let parsed = try JSONDecoder().decode(JSONValue.self, from: try await HTTPTransport.get(request, session: session))
        return (parsed["data"]?.array ?? []).compactMap { $0["id"]?.string }.sorted()
    }

    private func authorize(_ request: inout URLRequest) {
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
    }

    private func run(
        _ request: LLMRequest,
        continuation: AsyncThrowingStream<LLMEvent, any Error>.Continuation,
        delivered: OSAllocatedUnfairLock<Bool>,
        includeUsage: Bool
    ) async throws {
        var http = URLRequest(url: try HTTPTransport.endpoint(baseURL, "/chat/completions"))
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        authorize(&http)
        http.httpBody = try Self.body(for: request, includeUsage: includeUsage).encoded()

        let bytes: URLSession.AsyncBytes
        do {
            bytes = try await HTTPTransport.open(http, session: session)
        } catch LLMError.http(let status, let message, _, _) where includeUsage && (400..<500).contains(status) && message.contains("stream_options") {
            // Some self-hosted servers reject the option outright; usage is a nicety, so drop it.
            return try await run(request, continuation: continuation, delivered: delivered, includeUsage: false)
        }

        var assembler = ToolCallAssembler()
        var finish: String?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let chunk = try? JSONValue.parse(payload) else { continue }

            if let usage = chunk["usage"], let input = usage["prompt_tokens"]?.int, let output = usage["completion_tokens"]?.int {
                continuation.yield(.usage(input: input, output: output))
            }
            if let message = chunk["error"]?["message"]?.string {
                throw LLMError.invalidResponse(message)
            }
            guard let choice = chunk["choices"]?.array?.first else { continue }
            let delta = choice["delta"]
            if let text = delta?["content"]?.string, !text.isEmpty {
                delivered.withLock { $0 = true }
                continuation.yield(.textDelta(text))
            }
            if let reasoning = delta?["reasoning_content"]?.string, !reasoning.isEmpty {
                delivered.withLock { $0 = true }
                continuation.yield(.reasoning(reasoning))
            }
            for fragment in delta?["tool_calls"]?.array ?? [] {
                delivered.withLock { $0 = true }
                assembler.add(fragment)
            }
            if let reason = choice["finish_reason"]?.string { finish = reason }
        }

        for call in assembler.finished() { continuation.yield(.toolCall(call)) }
        continuation.yield(.stopped(Self.stopReason(finish, hasToolCalls: assembler.hasCalls)))
    }

    private static func stopReason(_ finish: String?, hasToolCalls: Bool) -> LLMStopReason {
        switch finish {
        case "length": .maxTokens
        case "content_filter": .refusal(nil)
        case "tool_calls": .toolUse
        default: hasToolCalls ? .toolUse : .endTurn
        }
    }

    /// `max_tokens` is left out on purpose: newer OpenAI models reject it in favour of
    /// `max_completion_tokens`, which other servers reject in turn. The server default works everywhere.
    static func body(for request: LLMRequest, includeUsage: Bool) throws -> JSONValue {
        var fields: [String: JSONValue] = [
            "model": .string(request.model),
            "stream": true,
            "messages": .array([["role": "system", "content": .string(request.system)]] + request.messages.map(encode)),
        ]
        if includeUsage { fields["stream_options"] = ["include_usage": true] }
        if !request.tools.isEmpty {
            fields["tools"] = .array(request.tools.map { tool in
                [
                    "type": "function",
                    "function": ["name": .string(tool.name), "description": .string(tool.description), "parameters": tool.parameters],
                ]
            })
        }
        return .object(fields)
    }

    private static func encode(_ message: LLMMessage) -> JSONValue {
        switch message.role {
        case .tool:
            return ["role": "tool", "tool_call_id": .string(message.toolCallID ?? ""), "content": .string(message.text)]
        case .assistant:
            // An empty string rather than null: OpenAI accepts both, several compatible servers only the string.
            var fields: [String: JSONValue] = ["role": "assistant", "content": .string(message.text)]
            if let reasoning = message.reasoning { fields["reasoning_content"] = .string(reasoning) }
            if !message.toolCalls.isEmpty {
                fields["tool_calls"] = .array(message.toolCalls.map { call in
                    [
                        "id": .string(call.id),
                        "type": "function",
                        "function": ["name": .string(call.name), "arguments": .string(call.argumentsJSON)],
                    ]
                })
            }
            return .object(fields)
        case .user:
            guard !message.images.isEmpty else {
                return ["role": "user", "content": .string(message.text)]
            }
            let images: [JSONValue] = message.images.map { image in
                ["type": "image_url", "image_url": ["url": .string("data:\(image.mediaType);base64,\(image.base64)")]]
            }
            let text: JSONValue = ["type": "text", "text": .string(message.text)]
            return ["role": "user", "content": .array([text] + images)]
        }
    }
}

/// Tool calls arrive as fragments keyed by index; the id and name come first, arguments in pieces after.
struct ToolCallAssembler {
    private struct Pending {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private var pending: [Int: Pending] = [:]
    private var order: [Int] = []

    var hasCalls: Bool { !pending.isEmpty }

    mutating func add(_ fragment: JSONValue) {
        let index = fragment["index"]?.int ?? order.count
        if pending[index] == nil {
            pending[index] = Pending()
            order.append(index)
        }
        if let id = fragment["id"]?.string, !id.isEmpty { pending[index]?.id = id }
        if let name = fragment["function"]?["name"]?.string, !name.isEmpty { pending[index]?.name = name }
        if let arguments = fragment["function"]?["arguments"]?.string { pending[index]?.arguments += arguments }
    }

    func finished() -> [LLMToolCall] {
        order.compactMap { index in
            guard let call = pending[index], !call.name.isEmpty else { return nil }
            // Ollama can omit the id; the tool result still has to reference something.
            let id = call.id.isEmpty ? "call_\(UUID().uuidString.prefix(8))" : call.id
            return LLMToolCall(id: id, name: call.name, argumentsJSON: call.arguments.isEmpty ? "{}" : call.arguments)
        }
    }
}
