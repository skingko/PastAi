import AppKit
import ClipCore
import Observation

enum LibrarySection: Hashable {
    case all
    case pinboard(Int64)
    case kind(ClipKind)
    case tag(String)
    case trash
}

@MainActor
@Observable
final class LibraryModel {
    static let pageSize = 80

    let service: ClipService
    private let writer: PasteWriter

    var section: LibrarySection = .all { didSet { if section != oldValue { selectionChanged([]); reload() } } }
    var search = "" { didSet { if search != oldValue { reload(debounce: true) } } }
    var selection: Set<Int64> = [] { didSet { if selection != oldValue { loadDetail() } } }

    private(set) var clips: [Clip] = []
    private(set) var total = 0
    private(set) var pinboards: [Pinboard] = []
    private(set) var pinboardCounts: [Int64: Int] = [:]
    private(set) var tags: [TagSummary] = []
    private(set) var detail: ClipDetail?

    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    @ObservationIgnored private var loadingMore = false

    struct TagSummary: Identifiable, Hashable {
        var name: String
        var count: Int
        var id: String { name }
    }

    init(service: ClipService) {
        self.service = service
        writer = PasteWriter(service: service)
        changesTask = Task { [weak self] in
            guard let stream = self?.service.changes() else { return }
            for await _ in stream {
                guard let self else { return }
                self.reload(debounce: true)
                self.loadSidebar()
            }
        }
        reload()
        loadSidebar()
    }

    deinit { changesTask?.cancel() }

    private func selectionChanged(_ ids: Set<Int64>) { selection = ids }

    private func query(offset: Int = 0) -> ClipQuery {
        var query = ClipQuery(text: search.trimmingCharacters(in: .whitespacesAndNewlines), limit: Self.pageSize, offset: offset)
        switch section {
        case .all: break
        case .pinboard(let id): query.collection = .pinboard(id)
        case .kind(let kind): query.kinds = [kind]
        case .tag(let tag): query.tag = tag
        case .trash: query.collection = .trash
        }
        return query
    }

    func reload(debounce: Bool = false) {
        reloadTask?.cancel()
        let query = query()
        reloadTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(90)) }
            guard let self, !Task.isCancelled else { return }
            guard let loaded = try? await self.service.list(query), !Task.isCancelled else { return }
            self.clips = loaded
            self.total = (try? await self.service.count(query)) ?? loaded.count
            self.loadDetail()
        }
    }

    func loadSidebar() {
        Task {
            pinboards = (try? await service.pinboards()) ?? []
            pinboardCounts = (try? await service.pinboardCounts()) ?? [:]
            tags = ((try? await service.tags()) ?? []).map { TagSummary(name: $0.name, count: $0.count) }
        }
    }

    func loadMoreIfNeeded(index: Int) {
        guard clips.count < total, !loadingMore, index >= clips.count - 15 else { return }
        loadingMore = true
        let next = query(offset: clips.count)
        Task {
            defer { loadingMore = false }
            guard let more = try? await service.list(next), next == query(offset: clips.count) else { return }
            clips.append(contentsOf: more)
        }
    }

    private func loadDetail() {
        guard selection.count == 1, let id = selection.first else {
            detail = nil
            return
        }
        Task {
            let loaded = try? await service.detail(id: id)
            if selection == [id] { detail = loaded }
        }
    }

    // MARK: Actions

    func saveContent(id: Int64, title: String, text: String?) {
        guard let current = detail, current.clip.id == id else { return }
        var mutations: [ClipMutation] = []
        let newTitle = title.isEmpty ? nil : title
        if newTitle != current.clip.title { mutations.append(.setTitle(clipID: id, title: newTitle)) }
        if let text, text != current.clip.plainText { mutations.append(.setText(clipID: id, text: text)) }
        guard !mutations.isEmpty else { return }
        Task { try? await service.apply(mutations, source: .user, summary: "编辑条目") }
    }

    func setTags(id: Int64, tags: [String]) {
        Task { try? await service.apply([.setTags(clipID: id, tags: tags)], source: .user, summary: "修改标签") }
    }

    func setAIHidden(id: Int64, hidden: Bool) {
        Task { try? await service.apply([.setAIHidden(clipID: id, hidden: hidden)], source: .user, summary: "调整 AI 可见性") }
    }

    func delete(_ ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        selection = []
        Task { try? await service.apply(ids.map { .softDelete(clipID: $0) }, source: .user, summary: "删除 \(ids.count) 项") }
    }

    func restore(_ ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        selection = []
        Task { try? await service.apply(ids.map { .restore(clipID: $0) }, source: .user, summary: "恢复 \(ids.count) 项") }
    }

    func emptyTrash() {
        Task { try? await service.emptyTrash() }
    }

    func copy(_ ids: Set<Int64>) {
        let ordered = clips.filter { ids.contains($0.id) }.map(\.id)
        Task {
            var details: [ClipDetail] = []
            for id in ordered {
                if let detail = try? await service.detail(id: id) { details.append(detail) }
            }
            _ = try? writer.write(details, mode: .original)
        }
    }

    func pin(_ ids: Set<Int64>, to board: Int64) {
        Task {
            try? await service.apply(ids.map { .addToPinboard(clipID: $0, pinboardID: board) }, source: .user, summary: "加入 Pinboard")
        }
    }

    func unpin(_ ids: Set<Int64>, from board: Int64) {
        Task {
            try? await service.apply(ids.map { .removeFromPinboard(clipID: $0, pinboardID: board) }, source: .user, summary: "移出 Pinboard")
        }
    }

    func thumbnailURL(_ clip: Clip) -> URL? {
        clip.thumbnailPath.map { service.paths.thumbnails.appending(path: $0) }
    }
}
