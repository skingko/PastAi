import ClipCore
import Foundation

public enum ToolRisk: Sendable, Hashable {
    /// Reads, run without asking.
    case read
    /// Adds or organises; nothing is lost and it can be undone.
    case reversible
    /// Changes or removes existing content. Always needs a person.
    case destructive
}

public struct ChangeItem: Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var label: String
    public var before: String?
    public var after: String?

    public init(label: String, before: String? = nil, after: String? = nil) {
        self.label = label
        self.before = before
        self.after = after
    }
}

public struct ChangeProposal: Sendable, Identifiable, Hashable {
    public var id = UUID()
    public var toolName: String
    public var summary: String
    public var risk: ToolRisk
    public var items: [ChangeItem]

    public init(toolName: String, summary: String, risk: ToolRisk, items: [ChangeItem]) {
        self.toolName = toolName
        self.summary = summary
        self.risk = risk
        self.items = items
    }
}

public enum ApprovalDecision: Sendable, Equatable {
    case approved
    /// Approves this proposal and every later reversible one in the same conversation.
    case approvedForSession
    case rejected(reason: String?)
}

public typealias ApprovalHandler = @Sendable (ChangeProposal) async -> ApprovalDecision

/// The approval boundary sits inside tool execution, not in the model's instructions. No tool can reach
/// a write without passing here, so text injected through clipboard content cannot talk its way past it.
public actor ApprovalGate {
    private let handler: ApprovalHandler
    private var reversibleApproved = false

    public init(handler: @escaping ApprovalHandler) {
        self.handler = handler
    }

    public func review(_ proposal: ChangeProposal) async -> ApprovalDecision {
        if proposal.risk == .reversible, reversibleApproved { return .approved }
        let decision = await handler(proposal)
        if case .approvedForSession = decision {
            // A session-wide yes only ever covers additive changes; destructive ones still come back here.
            if proposal.risk == .reversible { reversibleApproved = true }
            return .approved
        }
        return decision
    }
}

public enum AgentToolError: Error, LocalizedError, Equatable {
    case badArguments(String)
    case notAccessible(Int64)
    case pinboardNotAccessible(Int64)

    public var errorDescription: String? {
        switch self {
        case .badArguments(let detail): "Bad arguments: \(detail)"
        case .notAccessible(let id): "Clip \(id) does not exist or is not accessible"
        case .pinboardNotAccessible(let id): "Pinboard \(id) does not exist or is not accessible"
        }
    }
}

/// The agent's only route to the library. Every read uses the agent scope and every write is checked
/// against it, so hidden clips look exactly like clips that do not exist.
public struct AgentClipAccess: Sendable {
    public let service: ClipService

    public init(service: ClipService) {
        self.service = service
    }

    public func search(_ query: ClipQuery) async throws -> [Clip] {
        try await service.list(query, scope: .agent)
    }

    public func count(_ query: ClipQuery) async throws -> Int {
        try await service.count(query, scope: .agent)
    }

    public func detail(_ id: Int64) async throws -> ClipDetail {
        guard let detail = try await service.detail(id: id, scope: .agent) else { throw AgentToolError.notAccessible(id) }
        return detail
    }

    public func pinboards() async throws -> [Pinboard] {
        try await service.pinboards(scope: .agent)
    }

    public func pinboardCounts() async throws -> [Int64: Int] {
        try await service.pinboardCounts()
    }

    public func tags() async throws -> [(name: String, count: Int)] {
        try await service.tags(scope: .agent)
    }

    public func stats() async throws -> LibraryStats {
        try await service.stats(scope: .agent)
    }

    public func duplicates() async throws -> [[Int64]] {
        try await service.duplicateGroups(scope: .agent)
    }

    public func requirePinboard(_ id: Int64) async throws -> Pinboard {
        guard let board = try await pinboards().first(where: { $0.id == id }) else {
            throw AgentToolError.pinboardNotAccessible(id)
        }
        return board
    }

    @discardableResult
    public func apply(_ mutations: [ClipMutation], summary: String, batchID: String) async throws -> AppliedMutations {
        for mutation in mutations {
            for id in mutation.referencedClipIDs { _ = try await detail(id) }
            for id in mutation.referencedPinboardIDs { _ = try await requirePinboard(id) }
        }
        return try await service.apply(mutations, source: .agent, summary: summary, batchID: batchID)
    }
}

extension ClipMutation {
    var referencedClipIDs: [Int64] {
        switch self {
        case .setText(let id, _), .restoreContent(let id, _, _, _, _), .setTitle(let id, _), .setTags(let id, _),
             .setAIHidden(let id, _), .addToPinboard(let id, _), .removeFromPinboard(let id, _), .softDelete(let id), .restore(let id):
            [id]
        case .createText, .createPinboard, .deletePinboard:
            []
        }
    }

    var referencedPinboardIDs: [Int64] {
        switch self {
        case .addToPinboard(_, let id), .removeFromPinboard(_, let id), .deletePinboard(let id): [id]
        case .createText(_, _, let id): id.map { [$0] } ?? []
        default: []
        }
    }
}
