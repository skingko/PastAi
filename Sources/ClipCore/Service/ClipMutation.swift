import Foundation

/// Every change to the library goes through here so edits made by people and by the agent
/// share one code path and one undo log.
public enum ClipMutation: Codable, Sendable, Hashable {
    case setText(clipID: Int64, text: String)
    case restoreContent(clipID: Int64, text: String?, kind: ClipKind, contentHash: String, representations: [Representation])
    case setTitle(clipID: Int64, title: String?)
    case setTags(clipID: Int64, tags: [String])
    case setAIHidden(clipID: Int64, hidden: Bool)
    case addToPinboard(clipID: Int64, pinboardID: Int64)
    case removeFromPinboard(clipID: Int64, pinboardID: Int64)
    case softDelete(clipID: Int64)
    case restore(clipID: Int64)
    case createText(text: String, title: String?, pinboardID: Int64?)
    case createPinboard(name: String, colorHex: String?)
    case deletePinboard(id: Int64)
}

public enum ChangeSource: String, Sendable, Codable {
    case user
    case agent
}

public struct AppliedMutations: Sendable {
    public var batchID: String
    public var createdClipIDs: [Int64]
    public var createdPinboardIDs: [Int64]
}

public struct ChangeBatch: Sendable, Hashable, Identifiable {
    public var id: String
    public var source: ChangeSource
    public var summary: String
    public var count: Int
    public var createdAt: Date
    public var isUndone: Bool
}

public enum ClipServiceError: Error, CustomStringConvertible, Equatable {
    case clipNotFound(Int64)
    case pinboardNotFound(Int64)
    case notEditable(Int64)

    public var description: String {
        switch self {
        case .clipNotFound(let id): "条目 \(id) 不存在"
        case .pinboardNotFound(let id): "Pinboard \(id) 不存在"
        case .notEditable(let id): "条目 \(id) 不是文本，无法修改内容"
        }
    }
}
