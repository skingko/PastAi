import Foundation

public struct LLMImage: Codable, Sendable, Hashable {
    public var mediaType: String
    public var base64: String

    public init(mediaType: String, base64: String) {
        self.mediaType = mediaType
        self.base64 = base64
    }
}

public struct LLMToolCall: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct LLMMessage: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable {
        case user, assistant, tool
    }

    public var role: Role
    public var text: String
    /// What the transcript shows when it differs from `text`, which also carries injected context.
    public var displayText: String?
    public var images: [LLMImage]
    public var toolCalls: [LLMToolCall]
    public var toolCallID: String?
    public var toolName: String?
    public var isError: Bool
    /// DeepSeek-style `reasoning_content`, which must be echoed back during a tool loop.
    public var reasoning: String?
    /// Anthropic content blocks, replayed verbatim: thinking blocks are only valid if returned unchanged.
    public var anthropicBlocks: [JSONValue]?

    public init(
        role: Role,
        text: String = "",
        displayText: String? = nil,
        images: [LLMImage] = [],
        toolCalls: [LLMToolCall] = [],
        toolCallID: String? = nil,
        toolName: String? = nil,
        isError: Bool = false,
        reasoning: String? = nil,
        anthropicBlocks: [JSONValue]? = nil
    ) {
        self.role = role
        self.text = text
        self.displayText = displayText
        self.images = images
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.isError = isError
        self.reasoning = reasoning
        self.anthropicBlocks = anthropicBlocks
    }
}

public struct LLMToolSpec: Sendable, Hashable {
    public var name: String
    public var description: String
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct LLMRequest: Sendable {
    public enum Effort: String, Sendable {
        case low, medium
    }

    public var model: String
    public var system: String
    public var messages: [LLMMessage]
    public var tools: [LLMToolSpec]
    public var effort: Effort
    public var maxTokens: Int

    public init(model: String, system: String, messages: [LLMMessage], tools: [LLMToolSpec] = [], effort: Effort = .medium, maxTokens: Int = 64_000) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.effort = effort
        self.maxTokens = maxTokens
    }
}

public enum LLMStopReason: Sendable, Equatable {
    case endTurn
    case toolUse
    case maxTokens
    case refusal(String?)
    case other(String)
}

public enum LLMEvent: Sendable {
    case textDelta(String)
    case reasoning(String)
    case toolCall(LLMToolCall)
    case usage(input: Int, output: Int)
    case assistantBlocks([JSONValue])
    /// Tool calls emitted so far were superseded, as when a safety fallback restarts the turn.
    case discardToolCalls
    case stopped(LLMStopReason)
}

public enum LLMError: Error, LocalizedError, Equatable {
    /// `code` is the provider's own error code from the response body, which often says far more than
    /// the HTTP status: Zhipu answers almost every plan and quota problem with a bare 429.
    case http(status: Int, message: String, code: String? = nil, retryAfter: Double? = nil)
    case invalidBaseURL(String)
    case invalidResponse(String)

    /// One line saying what went wrong, in terms of what the user can act on.
    public var title: String {
        switch self {
        case .http(let status, _, let code, _):
            if let code, let known = ProviderErrorCatalog.title(forCode: code) { return known }
            switch status {
            case 401, 403: return "模型服务拒绝了访问"
            case 404: return "找不到模型或接口地址"
            case 429: return "模型服务拒绝了这次请求"
            case 500...: return "模型服务暂时不可用"
            default: return "模型服务返回了错误"
            }
        case .invalidBaseURL: return "Base URL 无效"
        case .invalidResponse: return "模型返回了无法解析的内容"
        }
    }

    /// The provider's words, kept verbatim: only they can say which limit or setting is involved.
    public var detail: String? {
        switch self {
        case .http(let status, let message, let code, _):
            let prefix = code.map { "HTTP \(status)，错误码 \($0)" } ?? "HTTP \(status)"
            let note = code.flatMap(ProviderErrorCatalog.advice(forCode:))
            return ["\(prefix)：\(message)", note].compactMap(\.self).joined(separator: "\n")
        case .invalidBaseURL(let url): return url
        case .invalidResponse(let detail): return detail
        }
    }

    public var errorDescription: String? {
        [title, detail].compactMap(\.self).joined(separator: "：")
    }

    var isRetryable: Bool {
        guard case .http(let status, _, let code, _) = self else { return false }
        // Quota, plan and policy refusals never clear on their own, and repeating them can make things worse.
        if status == 429, let code { return ProviderErrorCatalog.isTransient(code) }
        return status == 408 || status == 409 || status == 429 || status >= 500
    }

    var retryDelay: Duration? {
        guard case .http(_, _, _, let retryAfter?) = self, retryAfter > 0 else { return nil }
        return .seconds(min(retryAfter, 30))
    }
}

/// Provider error codes worth explaining. Anything else still shows the provider's own message.
enum ProviderErrorCatalog {
    static func isTransient(_ code: String) -> Bool {
        ["1302", "1305", "rate_limit_exceeded", "rate_limit_error", "overloaded_error"].contains(code)
    }

    static func title(forCode code: String) -> String? {
        switch code {
        case "1113", "insufficient_quota": "账户余额不足，或这次调用不在套餐内"
        case "1302", "rate_limit_exceeded", "rate_limit_error": "请求频率超过了限制"
        case "1305", "overloaded_error": "模型当前负载过高"
        case "1308", "1310", "1316", "1317": "用量额度已用完"
        case "1309": "Coding Plan 套餐已到期"
        case "1311": "当前套餐不包含这个模型"
        case "1313": "账号的套餐权益被限制"
        case "1315": "API Key 类型与服务不匹配"
        case "model_not_found", "1211": "找不到这个模型"
        case "invalid_api_key": "API Key 无效"
        default: nil
        }
    }

    static func advice(forCode code: String) -> String? {
        switch code {
        case "1311": "换一个套餐包含的模型，或改用按量计费的 API Key。"
        case "1113": "Coding Plan 的额度只在官方支持的工具里生效。在 PastAi 里使用时，请用按量计费的 API Key 和 /api/paas/v4 地址。"
        case "1313": "Coding Plan 只能在官方支持的工具里使用，请停止用这个 Key 调用，并到智谱个人中心处理。"
        default: nil
        }
    }
}

public protocol LLMClient: Sendable {
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, any Error>
    func listModels() async throws -> [String]
}

/// The smallest request that proves a key, a model and tool calling all work. Run only when the user asks.
public enum ConnectionProbe {
    public static func run(client: any LLMClient, model: String) async throws -> String {
        let request = LLMRequest(
            model: model,
            system: "Reply with the single word OK.",
            messages: [LLMMessage(role: .user, text: "ping")],
            tools: [LLMToolSpec(name: "ping", description: "Connectivity check. Do not call this.", parameters: ["type": "object", "properties": [:]])],
            effort: .low,
            maxTokens: 64
        )
        var reply = ""
        for try await event in client.stream(request) {
            switch event {
            case .textDelta(let delta): reply += delta
            case .toolCall: reply = "OK"
            default: break
            }
        }
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum HTTPTransport {
    /// SSE replies can sit idle for a long time while a model thinks, so the idle timeout is generous.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 1_800
        return URLSession(configuration: configuration)
    }

    static func endpoint(_ baseURL: String, _ path: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n"))
        guard let url = URL(string: trimmed + path), url.scheme != nil, url.host != nil else {
            throw LLMError.invalidBaseURL(baseURL)
        }
        return url
    }

    /// Opens a stream, throwing on non-2xx with the provider's own message when it gave one.
    static func open(_ request: URLRequest, session: URLSession) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse("非 HTTP 响应") }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes.prefix(16_384) { body.append(byte) }
            throw failure(http, body: body)
        }
        return bytes
    }

    static func get(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse("非 HTTP 响应") }
        guard (200..<300).contains(http.statusCode) else { throw failure(http, body: data) }
        return data
    }

    private static func failure(_ response: HTTPURLResponse, body: Data) -> LLMError {
        let parsed = try? JSONDecoder().decode(JSONValue.self, from: body)
        let error = parsed?["error"]
        let message = error?["message"]?.string ?? error?.string ?? parsed?["message"]?.string
            ?? String(data: body.prefix(400), encoding: .utf8) ?? "未知错误"
        // Providers send this as a string or a number, and Anthropic keeps it in `type`.
        let code = error?["code"]?.string ?? error?["code"]?.int.map(String.init) ?? error?["type"]?.string
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
        return .http(status: response.statusCode, message: message, code: code, retryAfter: retryAfter)
    }

    /// Retries transient failures, but only before anything reached the caller:
    /// replaying a partly delivered stream would duplicate text in the transcript.
    static func withRetry(
        delays: [Duration] = [.seconds(1), .seconds(3)],
        hasDelivered: @Sendable () -> Bool,
        _ body: @Sendable () async throws -> Void
    ) async throws {
        var remaining = delays[...]
        while true {
            do {
                return try await body()
            } catch {
                guard !hasDelivered(), let delay = remaining.first, isTransient(error) else { throw error }
                remaining = remaining.dropFirst()
                try await Task.sleep(for: (error as? LLMError)?.retryDelay ?? delay)
            }
        }
    }

    private static func isTransient(_ error: any Error) -> Bool {
        if let error = error as? LLMError { return error.isRetryable }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code)
    }
}
