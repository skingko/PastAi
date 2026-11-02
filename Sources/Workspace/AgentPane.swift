import ClipAgent
import ClipCore
import SwiftUI

/// Two radii for the whole pane: `outer` for anything that stands alone, `inner` for anything nested in it.
private enum Radius {
    static let outer: CGFloat = 12
    static let inner: CGFloat = 8
}

private func rounded(_ radius: CGFloat) -> RoundedRectangle {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
}

/// A press that gives way slightly, shared by every custom button here.
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct AgentPane: View {
    @Bindable var model: AgentModel

    var body: some View {
        VStack(spacing: 0) {
            AgentHeader(model: model)
            Divider()
            AgentTranscript(model: model)
            AgentComposer(model: model)
        }
        .frame(minWidth: 360, idealWidth: 420)
        .background(Color(nsColor: .textBackgroundColor))
        .alert(
            "把剪贴板内容发送给 \(model.consentRequest?.name ?? "")？",
            isPresented: Binding(get: { model.consentRequest != nil }, set: { if !$0 { model.consentRequest = nil } }),
            presenting: model.consentRequest
        ) { provider in
            Button("允许") { model.grantConsent(provider) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("Agent 读取的内容会发送到这个云端服务，对 AI 隐藏的内容不会发送。使用 Ollama 或 LM Studio 等本地模型时，内容不会离开这台 Mac。")
        }
    }
}

// MARK: Header

private struct AgentHeader: View {
    var model: AgentModel

    private var title: String {
        model.sessions.first { $0.id == model.currentSessionID }?.title ?? "新对话"
    }

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button("新对话") { model.newSession() }
                if !model.sessions.isEmpty {
                    Divider()
                    ForEach(model.sessions.prefix(20)) { session in
                        Button(session.title) { model.open(session) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("切换对话")
            .disabled(model.isRunning)

            Spacer(minLength: 12)

            Menu {
                ForEach(model.availableModels, id: \.self) { reference in
                    Button(reference.model) { model.selectModel(reference) }
                }
                if !model.availableModels.isEmpty { Divider() }
                Button("模型设置…") { model.onOpenModelSettings?() }
            } label: {
                HStack(spacing: 3) {
                    Text(model.modelLabel).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(model.tokens.input > 0 ? "本次对话：输入 \(model.tokens.input)，输出 \(model.tokens.output) tokens" : "切换模型")

            Button {
                model.newSession()
            } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 13))
            }
            .buttonStyle(PressableStyle())
            .foregroundStyle(.secondary)
            .help("新对话")
            .disabled(model.isRunning)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }
}

// MARK: Transcript

private struct ToolStep: Identifiable {
    var id: UUID
    var name: String
    var summary: String
    var preview: String
    var state: TranscriptItem.ToolState
}

/// Runs of tool calls fold into one row: what the agent looked at matters far less than what it found.
private enum TranscriptBlock: Identifiable {
    case item(TranscriptItem)
    case activity([ToolStep])

    var id: UUID {
        switch self {
        case .item(let item): item.id
        case .activity(let steps): steps[0].id
        }
    }

    static func group(_ items: [TranscriptItem]) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        for item in items {
            guard case .tool(let id, _, let name, let summary, let preview, let state) = item else {
                blocks.append(.item(item))
                continue
            }
            let step = ToolStep(id: id, name: name, summary: summary, preview: preview, state: state)
            if case .activity(let steps)? = blocks.last {
                blocks[blocks.count - 1] = .activity(steps + [step])
            } else {
                blocks.append(.activity([step]))
            }
        }
        return blocks
    }
}

private struct AgentTranscript: View {
    var model: AgentModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followsLatest = true
    @State private var isUserScrolling = false

    private static let end = "transcript-end"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.items.isEmpty {
                        AgentEmptyState(model: model)
                    }
                    ForEach(TranscriptBlock.group(model.items)) { block in
                        Group {
                            switch block {
                            case .activity(let steps): ActivityGroup(steps: steps)
                            case .item(let item): TranscriptRow(item: item, model: model)
                            }
                        }
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
                    }
                    if model.isRunning, !isAwaitingApproval {
                        ThinkingRow(text: model.status)
                    }
                    Color.clear.frame(height: 1).id(Self.end)
                }
                .padding(16)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.items.count)
            }
            .scrollIndicators(.automatic)
            .onScrollPhaseChange { _, phase in
                isUserScrolling = phase == .interacting || phase == .decelerating
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 60
            } action: { _, isAtEnd in
                // Only a deliberate scroll changes this. Content growing below the fold must not stop following.
                if isUserScrolling { followsLatest = isAtEnd }
            }
            .onChange(of: model.revision) { _, _ in
                if case .user? = model.items.last { followsLatest = true }
                if followsLatest { proxy.scrollTo(Self.end, anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(Self.end, anchor: .bottom) }
        }
    }

    /// The approval card already says what is happening, so a spinner below it would only compete.
    private var isAwaitingApproval: Bool {
        model.items.contains {
            if case .proposal(_, _, .pending) = $0 { true } else { false }
        }
    }
}

private struct TranscriptRow: View {
    var item: TranscriptItem
    var model: AgentModel

    var body: some View {
        switch item {
        case .user(_, let text):
            HStack {
                Spacer(minLength: 56)
                Text(text)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.065), in: rounded(Radius.outer))
            }
        case .assistant(_, let text):
            MarkdownText(source: text)
        case .proposal(_, let proposal, let state):
            ProposalCard(proposal: proposal, state: state, model: model)
        case .failure(_, let failure):
            FailureCard(failure: failure, model: model)
        case .note(_, let text):
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        case .undo(_, let batchID, let isUndone):
            HStack(spacing: 8) {
                Text(isUndone ? "这次的修改已撤销" : "这次修改了你的资料库")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if !isUndone {
                    Button("撤销") { model.undo(batchID: batchID) }
                        .font(.system(size: 12, weight: .medium))
                        .buttonStyle(PressableStyle())
                        .foregroundStyle(Color.accentColor)
                }
            }
        case .tool:
            EmptyView()
        }
    }
}

private struct ThinkingRow: View {
    var text: String

    var body: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.mini)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

private struct ActivityGroup: View {
    var steps: [ToolStep]
    @State private var isExpanded = false

    private var running: ToolStep? { steps.last { $0.state == .running } }
    private var failedCount: Int { steps.filter { $0.state == .failed }.count }

    private var title: String {
        if let running { return AgentModel.toolTitle(running.name) }
        if steps.count == 1 { return AgentModel.toolTitle(steps[0].name) }
        return "完成了 \(steps.count) 个步骤"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.14)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title).font(.system(size: 12))
                    if failedCount > 0 {
                        Text("\(failedCount) 个失败").font(.system(size: 12)).foregroundStyle(.red)
                    }
                    if running != nil {
                        ProgressView().controlSize(.mini)
                    }
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(steps) { step in
                        StepRow(step: step)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }
}

private struct StepRow: View {
    var step: ToolStep

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(AgentModel.toolTitle(step.name)).font(.system(size: 12, weight: .medium))
                Text(step.summary).font(.system(size: 11.5)).foregroundStyle(.tertiary).lineLimit(1)
            }
            if !step.preview.isEmpty {
                Text(step.preview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(step.state == .failed ? Color.red : Color.secondary)
                    .lineLimit(5)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct ProposalCard: View {
    var proposal: ChangeProposal
    var state: TranscriptItem.ProposalState
    var model: AgentModel

    private var visibleItems: [ChangeItem] { Array(proposal.items.prefix(6)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(proposal.summary).font(.system(size: 13, weight: .semibold))
                if proposal.risk == .destructive, state == .pending {
                    Text("会改动已有内容，确认后可以撤销").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(visibleItems) { item in
                    ChangeRow(item: item)
                }
                if proposal.items.count > visibleItems.count {
                    Text("还有 \(proposal.items.count - visibleItems.count) 项").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }

            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rounded(Radius.outer).fill(Color.primary.opacity(0.025)))
        .overlay(rounded(Radius.outer).strokeBorder(Color.primary.opacity(0.1)))
    }

    @ViewBuilder
    private var footer: some View {
        switch state {
        case .pending:
            HStack(spacing: 8) {
                Button("拒绝") { model.resolve(proposal, decision: .rejected(reason: nil)) }
                Spacer()
                if proposal.risk == .reversible {
                    Button("本次都允许") { model.resolve(proposal, decision: .approvedForSession) }
                }
                Button("允许") { model.resolve(proposal, decision: .approved) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        case .approved:
            Text("已允许").font(.system(size: 11.5)).foregroundStyle(.secondary)
        case .rejected:
            Text("已拒绝").font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}

private struct ChangeRow: View {
    var item: ChangeItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.label).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            if let before = item.before, !before.isEmpty {
                Text(before.prefix(300))
                    .font(.system(size: 12))
                    .strikethrough(item.after != nil, color: .secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            if let after = item.after, !after.isEmpty {
                Text(after.prefix(300)).font(.system(size: 12)).lineLimit(6)
            }
        }
    }
}

private struct FailureCard: View {
    var failure: AgentFailure
    var model: AgentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
                Text(failure.title).font(.system(size: 13, weight: .medium))
            }
            if let detail = failure.detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2.5)
                    .textSelection(.enabled)
                    .padding(.leading, 19)
            }
            HStack(spacing: 12) {
                if failure.canRetry {
                    Button("重试") { model.retry() }
                        .foregroundStyle(Color.accentColor)
                }
                if failure.suggestsModelSettings {
                    Button("模型设置") { model.onOpenModelSettings?() }
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .buttonStyle(PressableStyle())
            .padding(.leading, 19)
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.055), in: rounded(Radius.outer))
    }
}

private struct AgentEmptyState: View {
    var model: AgentModel

    private let suggestions = [
        "把这周复制的链接按主题分到 Pinboard",
        "找出上个月复制的 nginx 配置",
        "清理重复项和 30 天没用过的截图",
    ]

    var body: some View {
        if model.isConfigured {
            VStack(alignment: .leading, spacing: 10) {
                Text("整理、查找或改写你的剪贴板").font(.system(size: 15, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(suggestions, id: \.self) { text in
                        SuggestionRow(text: text) { model.composer = text }
                    }
                }
                .padding(.horizontal, -8)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("先连接一个模型").font(.system(size: 15, weight: .semibold))
                Text("可以用云端服务，也可以用 Ollama、LM Studio 等本地模型。本地模型不会把内容发出这台 Mac。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                Button("添加模型") { model.onOpenModelSettings?() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
    }
}

private struct SuggestionRow: View {
    var text: String
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isHovered ? Color.primary.opacity(0.05) : .clear, in: rounded(Radius.inner))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { isHovered = $0 }
    }
}

// MARK: Composer

private struct AgentComposer: View {
    @Bindable var model: AgentModel
    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !model.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(model.attachments) { clip in
                            AttachmentChip(clip: clip) { model.removeAttachment(clip.id) }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(model.isConfigured ? "想让 Agent 做什么？" : "添加模型后可用", text: $model.composer, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...8)
                    .focused($isFocused)
                    .onSubmit { model.send() }
                    .disabled(!model.isConfigured)
                    .padding(.vertical, 4)
                actionButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.035), in: rounded(Radius.outer))
        .overlay(rounded(Radius.outer).strokeBorder(Color.primary.opacity(isFocused ? 0.2 : 0.09)))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var actionButton: some View {
        if model.isRunning {
            Button {
                model.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.primary)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.09), in: Circle())
            }
            .buttonStyle(PressableStyle())
            .help("停止")
        } else {
            Button {
                model.send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(canSend ? Color.white : Color.secondary)
                    .frame(width: 26, height: 26)
                    .background(canSend ? Color.accentColor : Color.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(PressableStyle())
            .disabled(!canSend)
            .help("发送")
        }
    }
}

private struct AttachmentChip: View {
    var clip: Clip
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: clip.kind.symbolName).foregroundStyle(.secondary)
            Text(clip.displayTitle.prefix(18)).lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(PressableStyle())
            .help("移除")
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color.primary.opacity(0.06), in: rounded(Radius.inner))
    }
}
