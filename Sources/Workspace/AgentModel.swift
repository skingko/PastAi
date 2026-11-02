import ClipAgent
import ClipCore
import Foundation
import Observation

enum TranscriptItem: Identifiable {
    enum ToolState {
        case running
        case succeeded
        case failed
    }

    enum ProposalState {
        case pending
        case approved
        case rejected
    }

    case user(id: UUID, text: String)
    case assistant(id: UUID, text: String)
    case tool(id: UUID, callID: String, name: String, summary: String, preview: String, state: ToolState)
    case proposal(id: UUID, proposal: ChangeProposal, state: ProposalState)
    case note(id: UUID, text: String)
    case failure(id: UUID, failure: AgentFailure)
    case undo(id: UUID, batchID: String, isUndone: Bool)

    var id: UUID {
        switch self {
        case .user(let id, _), .assistant(let id, _), .tool(let id, _, _, _, _, _), .proposal(let id, _, _),
             .note(let id, _), .failure(let id, _), .undo(let id, _, _):
            id
        }
    }
}

@MainActor
@Observable
final class AgentModel {
    let service: ClipService
    let settings: AgentSettings
    private let writer: PasteWriter
    private let engine: any AgentEngine
    private let extensions: ExtensionAccess?

    private(set) var items: [TranscriptItem] = []
    private(set) var sessions: [AgentSessionInfo] = []
    private(set) var currentSessionID: Int64?
    private(set) var isRunning = false
    private(set) var status = ""
    private(set) var tokens = (input: 0, output: 0)
    /// Bumped whenever the transcript changes, including text streaming into the last message.
    private(set) var revision = 0
    private(set) var attachments: [Clip] = []
    var composer = ""
    /// Set when a cloud provider needs consent before clipboard content can be sent to it.
    var consentRequest: ModelProvider?

    @ObservationIgnored private var history: [LLMMessage] = []
    @ObservationIgnored private var run: AgentRun?
    @ObservationIgnored private var gate: ApprovalGate?
    @ObservationIgnored private var pendingApprovals: [UUID: CheckedContinuation<ApprovalDecision, Never>] = [:]
    @ObservationIgnored private var pendingBatch: String?

    var onOpenModelSettings: (() -> Void)?

    init(service: ClipService, settings: AgentSettings, extensions: ExtensionAccess? = nil, engine: any AgentEngine = ToolLoopEngine()) {
        self.service = service
        self.settings = settings
        self.extensions = extensions
        self.engine = engine
        writer = PasteWriter(service: service)
        refreshSessions()
    }

    var isConfigured: Bool { settings.mainModel != nil && settings.provider(for: settings.mainModel) != nil }

    var modelLabel: String { settings.mainModel?.model ?? "未配置模型" }

    var availableModels: [ModelRef] {
        settings.providers.flatMap { provider in provider.models.map { ModelRef(providerID: provider.id, model: $0) } }
    }

    func selectModel(_ reference: ModelRef) {
        settings.mainModel = reference
    }

    func refreshSessions() {
        Task { sessions = (try? await service.agentSessions()) ?? [] }
    }

    func newSession() {
        guard !isRunning else { return }
        currentSessionID = nil
        history = []
        items = []
        tokens = (0, 0)
        gate = nil
    }

    func open(_ session: AgentSessionInfo) {
        guard !isRunning else { return }
        Task {
            let payloads = (try? await service.agentMessages(sessionID: session.id)) ?? []
            let messages = payloads.compactMap { try? JSONDecoder().decode(LLMMessage.self, from: Data($0.utf8)) }
            currentSessionID = session.id
            history = messages
            items = Self.transcript(from: messages)
            revision += 1
            tokens = (0, 0)
            gate = nil
        }
    }

    func delete(_ session: AgentSessionInfo) {
        Task {
            try? await service.deleteAgentSession(id: session.id)
            if currentSessionID == session.id { newSession() }
            refreshSessions()
        }
    }

    private static func transcript(from messages: [LLMMessage]) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        for message in messages {
            switch message.role {
            case .user:
                let shown = message.displayText ?? message.text
                if !shown.isEmpty { items.append(.user(id: UUID(), text: shown)) }
            case .assistant:
                if !message.text.isEmpty { items.append(.assistant(id: UUID(), text: message.text)) }
            case .tool:
                items.append(.tool(
                    id: UUID(), callID: message.toolCallID ?? "", name: message.toolName ?? "工具", summary: "",
                    preview: String(message.text.prefix(240)), state: message.isError ? .failed : .succeeded
                ))
            }
        }
        return items
    }

    // MARK: Attachments

    func attach(_ ids: [Int64]) {
        Task {
            var added: [Clip] = []
            var hidden = 0
            for id in ids where !attachments.contains(where: { $0.id == id }) {
                // The agent could not read these anyway; saying so beats a silently missing attachment.
                if let detail = try? await service.detail(id: id, scope: .agent) {
                    added.append(detail.clip)
                } else {
                    hidden += 1
                }
            }
            attachments.append(contentsOf: added)
            if hidden > 0 {
                items.append(.note(id: UUID(), text: "\(hidden) 项对 AI 隐藏，未附加。"))
            }
        }
    }

    func removeAttachment(_ id: Int64) {
        attachments.removeAll { $0.id == id }
    }

    // MARK: Running

    func send() {
        let text = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        guard isConfigured, let provider = settings.provider(for: settings.mainModel) else {
            onOpenModelSettings?()
            return
        }
        if !provider.isLocal, !settings.cloudConsent.contains(provider.id) {
            consentRequest = provider
            return
        }
        composer = ""
        start(text: text, attached: attachments)
        attachments = []
    }

    func grantConsent(_ provider: ModelProvider) {
        settings.cloudConsent.insert(provider.id)
        consentRequest = nil
        send()
    }

    private func start(text: String, attached: [Clip]) {
        var shown = text
        if !attached.isEmpty {
            shown += "\n（附带 \(attached.count) 个条目）"
        }
        items.append(.user(id: UUID(), text: shown))
        revision += 1
        launch { [self] in
            let input = await makeInput(text: text, displayText: shown, attached: attached)
            await ensureSession(title: text)
            return input
        }
    }

    /// Runs the conversation again from where it stopped, so a retry adds no duplicate user message.
    func retry() {
        guard !isRunning, !history.isEmpty else { return }
        if case .failure? = items.last { items.removeLast() }
        launch { nil }
    }

    private func launch(_ prepare: @escaping @MainActor () async -> LLMMessage?) {
        guard let client = settings.client(for: settings.mainModel), let main = settings.mainModel else {
            onOpenModelSettings?()
            return
        }
        let light = settings.lightModel ?? main
        let lightClient = settings.client(for: light) ?? client
        let supportsVision = settings.provider(for: main)?.supportsVision ?? false

        isRunning = true
        status = "思考中"

        let approvals = gate ?? ApprovalGate { [weak self] proposal in
            await self?.requestApproval(proposal) ?? .rejected(reason: "应用已关闭")
        }
        gate = approvals

        Task {
            let input = await prepare()
            let context = AgentContext(
                client: client,
                model: main.model,
                lightClient: lightClient,
                lightModel: light.model,
                supportsVision: supportsVision,
                access: AgentClipAccess(service: service),
                approvals: approvals,
                copyToClipboard: { id in await self.copy(id) },
                extensions: extensions
            )
            let run = engine.run(history: history, input: input, context: context)
            self.run = run
            for await event in run.events { await handle(event) }
            finishRun()
        }
    }

    /// Context goes into the user message rather than the system prompt: the prompt must stay identical
    /// across a conversation, and a message, once sent, is never rewritten.
    private func makeInput(text: String, displayText: String, attached: [Clip]) async -> LLMMessage {
        let now = Date().formatted(.dateTime.year().month().day().weekday().hour().minute())
        let visible = (try? await service.count(ClipQuery(), scope: .agent)) ?? 0
        var context = "[当前时间：\(now)；资料库可访问条目：\(visible)]"
        if !attached.isEmpty {
            let list = attached.map { "\($0.id)（\($0.kind.displayName)：\($0.displayTitle.prefix(30))）" }.joined(separator: "，")
            context += "\n[用户选中的条目：\(list)]"
        }
        return LLMMessage(role: .user, text: "\(context)\n\n\(text)", displayText: displayText)
    }

    private func ensureSession(title: String) async {
        guard currentSessionID == nil else { return }
        currentSessionID = try? await service.createAgentSession(title: String(title.prefix(24)))
        refreshSessions()
    }

    private func handle(_ event: AgentEvent) async {
        defer { revision += 1 }
        switch event {
        case .textDelta(let delta):
            appendAssistant(delta)
        case .toolStarted(let id, let name, let summary):
            status = Self.toolTitle(name)
            let row = TranscriptItem.tool(id: UUID(), callID: id, name: name, summary: summary, preview: "", state: .running)
            // A write tool asks for approval straight away, and that can reach the main actor before this event.
            if case .proposal(_, _, .pending)? = items.last {
                items.insert(row, at: items.count - 1)
            } else {
                items.append(row)
            }
        case .toolFinished(let id, _, let preview, let isError):
            status = "思考中"
            finishTool(callID: id, preview: preview, isError: isError)
        case .progress(let message):
            status = message
        case .libraryChanged(let batchID):
            pendingBatch = batchID
        case .usage(let input, let output):
            tokens = (tokens.input + input, tokens.output + output)
        case .message(let message):
            history.append(message)
            await persist(message)
        case .finished:
            break
        case .failed(let failure):
            if failure.kind == .stopped {
                items.append(.note(id: UUID(), text: failure.title))
            } else {
                items.append(.failure(id: UUID(), failure: failure))
            }
        }
    }

    private func persist(_ message: LLMMessage) async {
        guard let session = currentSessionID,
              let data = try? JSONEncoder().encode(message),
              let json = String(data: data, encoding: .utf8) else { return }
        try? await service.appendAgentMessage(sessionID: session, payloadJSON: json)
    }

    private func finishRun() {
        isRunning = false
        status = ""
        run = nil
        if let batch = pendingBatch {
            items.append(.undo(id: UUID(), batchID: batch, isUndone: false))
            pendingBatch = nil
        }
        revision += 1
        refreshSessions()
    }

    private func appendAssistant(_ delta: String) {
        if case .assistant(let id, let text)? = items.last {
            items[items.count - 1] = .assistant(id: id, text: text + delta)
        } else {
            items.append(.assistant(id: UUID(), text: delta))
        }
    }

    private func finishTool(callID: String, preview: String, isError: Bool) {
        guard let index = items.lastIndex(where: {
            if case .tool(_, let id, _, _, _, _) = $0 { id == callID } else { false }
        }), case .tool(let id, let call, let name, let summary, _, _) = items[index] else { return }
        items[index] = .tool(id: id, callID: call, name: name, summary: summary, preview: preview, state: isError ? .failed : .succeeded)
    }

    func stop() {
        run?.cancel()
        for (_, continuation) in pendingApprovals {
            continuation.resume(returning: .rejected(reason: "用户已停止"))
        }
        pendingApprovals = [:]
        markPendingProposals(.rejected)
    }

    // MARK: Approval

    private func requestApproval(_ proposal: ChangeProposal) async -> ApprovalDecision {
        await withCheckedContinuation { continuation in
            pendingApprovals[proposal.id] = continuation
            items.append(.proposal(id: UUID(), proposal: proposal, state: .pending))
            revision += 1
            status = "等待你确认"
        }
    }

    func resolve(_ proposal: ChangeProposal, decision: ApprovalDecision) {
        guard let continuation = pendingApprovals.removeValue(forKey: proposal.id) else { return }
        update(proposalID: proposal.id, state: decision == .rejected(reason: nil) ? .rejected : .approved)
        status = "处理中"
        continuation.resume(returning: decision)
    }

    private func update(proposalID: UUID, state: TranscriptItem.ProposalState) {
        for index in items.indices {
            if case .proposal(let id, let proposal, _) = items[index], proposal.id == proposalID {
                items[index] = .proposal(id: id, proposal: proposal, state: state)
            }
        }
    }

    private func markPendingProposals(_ state: TranscriptItem.ProposalState) {
        for index in items.indices {
            if case .proposal(let id, let proposal, .pending) = items[index] {
                items[index] = .proposal(id: id, proposal: proposal, state: state)
            }
        }
    }

    func undo(batchID: String) {
        Task {
            try? await service.undo(batchID: batchID)
            for index in items.indices {
                if case .undo(let id, batchID, _) = items[index] {
                    items[index] = .undo(id: id, batchID: batchID, isUndone: true)
                }
            }
        }
    }

    private func copy(_ id: Int64) async -> Bool {
        guard let detail = try? await service.detail(id: id, scope: .agent) else { return false }
        return ((try? writer.write([detail], mode: .original)) ?? 0) > 0
    }

    static func toolTitle(_ name: String) -> String {
        switch name {
        case "search_clips": "搜索剪贴板"
        case "get_clips": "读取条目"
        case "list_pinboards": "查看 Pinboard"
        case "list_tags": "查看标签"
        case "stats": "查看统计"
        case "find_duplicates": "查找重复项"
        case "view_media": "查看媒体"
        case "set_titles": "设置标题"
        case "set_tags": "设置标签"
        case "create_clip": "新建条目"
        case "create_pinboard": "新建 Pinboard"
        case "move_to_pinboard": "移动到 Pinboard"
        case "merge_clips": "合并条目"
        case "copy_to_clipboard": "放到剪贴板"
        case "bulk_process": "批量处理"
        case "edit_clip": "修改条目"
        case "delete_clips": "删除条目"
        case "list_extensions": "查看组件"
        case "test_extension": "试运行组件"
        case "create_extension": "安装组件"
        case "delete_extension": "删除组件"
        default: name
        }
    }
}
