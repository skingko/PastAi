import Foundation
import Observation
import Security

public struct ModelProvider: Codable, Sendable, Hashable, Identifiable {
    public enum Format: String, Codable, Sendable, CaseIterable, Identifiable {
        case openAICompatible, anthropic

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .openAICompatible: "OpenAI 兼容"
            case .anthropic: "Anthropic"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var format: Format
    public var baseURL: String
    public var models: [String]
    public var supportsVision: Bool

    public init(id: UUID = UUID(), name: String, format: Format, baseURL: String, models: [String] = [], supportsVision: Bool = true) {
        self.id = id
        self.name = name
        self.format = format
        self.baseURL = baseURL
        self.models = models
        self.supportsVision = supportsVision
    }

    /// Local providers keep clipboard content on this Mac, so no cloud notice is needed.
    public var isLocal: Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
    }

    public func makeClient(apiKey: String) -> any LLMClient {
        switch format {
        case .openAICompatible: OpenAICompatibleClient(baseURL: baseURL, apiKey: apiKey)
        case .anthropic: AnthropicClient(baseURL: baseURL, apiKey: apiKey)
        }
    }

    public static let presets: [ModelProvider] = [
        ModelProvider(name: "Anthropic", format: .anthropic, baseURL: AnthropicClient.defaultBaseURL, models: ["claude-opus-5-5", "claude-haiku-5-5"]),
        ModelProvider(name: "OpenAI", format: .openAICompatible, baseURL: "https://api.openai.com/v1"),
        ModelProvider(name: "Google Gemini", format: .openAICompatible, baseURL: "https://generativelanguage.googleapis.com/v1beta/openai"),
        ModelProvider(name: "DeepSeek", format: .openAICompatible, baseURL: "https://api.deepseek.com/v1", supportsVision: false),
        ModelProvider(name: "通义千问", format: .openAICompatible, baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"),
        ModelProvider(name: "Kimi", format: .openAICompatible, baseURL: "https://api.moonshot.cn/v1"),
        ModelProvider(name: "智谱 GLM", format: .openAICompatible, baseURL: "https://open.bigmodel.cn/api/paas/v4"),
        ModelProvider(name: "OpenRouter", format: .openAICompatible, baseURL: "https://openrouter.ai/api/v1"),
        ModelProvider(name: "Ollama", format: .openAICompatible, baseURL: "http://127.0.0.1:11434/v1"),
        ModelProvider(name: "LM Studio", format: .openAICompatible, baseURL: "http://127.0.0.1:1234/v1"),
    ]
}

public struct ModelRef: Codable, Sendable, Hashable {
    public var providerID: UUID
    public var model: String

    public init(providerID: UUID, model: String) {
        self.providerID = providerID
        self.model = model
    }
}

/// API keys live in the login keychain, never in UserDefaults, the database or logs.
public struct KeychainStore: Sendable {
    let service: String

    public init(service: String = "io.github.skingko.pastai.provider-key") {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read(_ account: String) -> String? {
        var lookup = query(account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func save(_ value: String, account: String) -> Bool {
        guard !value.isEmpty else { return delete(account) }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query(account)
        item[kSecValueData as String] = data
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func delete(_ account: String) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

@MainActor
@Observable
public final class AgentSettings {
    private let defaults: UserDefaults
    public let keychain: KeychainStore

    public var providers: [ModelProvider] { didSet { persist(providers, key: "agent.providers") } }
    public var mainModel: ModelRef? { didSet { persist(mainModel, key: "agent.mainModel") } }
    public var lightModel: ModelRef? { didSet { persist(lightModel, key: "agent.lightModel") } }
    /// Providers the user has agreed may receive clipboard content.
    public var cloudConsent: Set<UUID> { didSet { persist(cloudConsent, key: "agent.cloudConsent") } }

    public init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        providers = Self.load([ModelProvider].self, key: "agent.providers", from: defaults) ?? []
        mainModel = Self.load(ModelRef.self, key: "agent.mainModel", from: defaults)
        lightModel = Self.load(ModelRef.self, key: "agent.lightModel", from: defaults)
        cloudConsent = Self.load(Set<UUID>.self, key: "agent.cloudConsent", from: defaults) ?? []
    }

    public func provider(for reference: ModelRef?) -> ModelProvider? {
        providers.first { $0.id == reference?.providerID }
    }

    public func client(for reference: ModelRef?) -> (any LLMClient)? {
        guard let provider = provider(for: reference) else { return nil }
        return provider.makeClient(apiKey: keychain.read(provider.id.uuidString) ?? "")
    }

    public func remove(_ provider: ModelProvider) {
        providers.removeAll { $0.id == provider.id }
        keychain.delete(provider.id.uuidString)
        if mainModel?.providerID == provider.id { mainModel = nil }
        if lightModel?.providerID == provider.id { lightModel = nil }
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, from defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
