import AppKit
import ClipCore
import Observation

public enum PanelTab: Hashable, Sendable {
    case history
    case kind(ClipKind)
    case pinboard(Int64)
}

public enum DateFilter: String, CaseIterable, Identifiable, Sendable {
    case today, week, month

    public var id: String { rawValue }
    var label: String {
        switch self {
        case .today: L("今天")
        case .week: L("近 7 天")
        case .month: L("近 30 天")
        }
    }

    var from: Date {
        switch self {
        case .today: Calendar.current.startOfDay(for: Date())
        case .week: Date().addingTimeInterval(-7 * 86_400)
        case .month: Date().addingTimeInterval(-30 * 86_400)
        }
    }
}

/// What the panel asks of its host. Keeps the model free of window and pasteboard plumbing.
@MainActor
struct PanelActions {
    var paste: ([Int64], PasteWriter.Mode) -> Void = { _, _ in }
    var hide: () -> Void = {}
    var edit: (Int64) -> Void = { _ in }
    var quickLook: (Int64) -> Void = { _ in }
    var sendToAgent: ([Int64]) -> Void = { _ in }
    var openMainWindow: () -> Void = {}
    var openSettings: () -> Void = {}
    var newText: () -> Void = {}
    var quit: () -> Void = {}
}

@MainActor
@Observable
public final class PanelModel {
    static let pageSize = 60

    let service: ClipService
    let settings: AppSettings
    @ObservationIgnored var actions = PanelActions()

    private(set) var pinboards: [Pinboard] = []
    private(set) var clips: [Clip] = []
    private(set) var sources: [SourceApp] = []
    private(set) var hasMore = false

    var tab: PanelTab = .history { didSet { if tab != oldValue { resetAndReload() } } }
    var query = "" { didSet { if query != oldValue { reload(debounce: true) } } }
    var kindFilter: ClipKind? { didSet { if kindFilter != oldValue { reload() } } }
    var sourceFilter: SourceApp? { didSet { if sourceFilter != oldValue { reload() } } }
    var dateFilter: DateFilter? { didSet { if dateFilter != oldValue { reload() } } }
    var showsFilters = false
    /// A brief message over the cards, for what a paste could not do.
    private(set) var notice: String?

    var cursorID: Int64?
    var selection: Set<Int64> = []
    /// Bumped to scroll even when the cursor itself did not change, such as on reopening.
    var scrollRequest = 0

    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    @ObservationIgnored private var loadingMore = false
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    public init(service: ClipService, settings: AppSettings) {
        self.service = service
        self.settings = settings
        // Stays current while hidden so the panel never opens on stale data.
        changesTask = Task { [weak self] in
            guard let stream = self?.service.changes() else { return }
            for await change in stream {
                guard let self else { return }
                if case .pinboardsChanged = change { await self.loadPinboards() }
                self.reload(debounce: true)
            }
        }
        Task { await loadPinboards() }
        reload()
    }

    deinit { changesTask?.cancel() }

    /// In a Pinboard tab, cards wear the board's color. Everywhere else the color tells kinds of content
    /// apart, since a clip can belong to several boards.
    var pinboardColorHex: String? {
        guard case .pinboard(let id) = tab else { return nil }
        return pinboards.first { $0.id == id }?.colorHex
    }

    var hasActiveFilters: Bool { kindFilter != nil || sourceFilter != nil || dateFilter != nil }

    var isSearching: Bool { !query.isEmpty || hasActiveFilters }

    /// Returns the panel to its opening state: newest history, first card selected.
    func prepareForShow() {
        query = ""
        kindFilter = nil
        sourceFilter = nil
        dateFilter = nil
        showsFilters = false
        notice = nil
        tab = .history
        cursorID = clips.first?.id
        selection = cursorID.map { [$0] } ?? []
        scrollRequest += 1
    }

    func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func resetAndReload() {
        cursorID = nil
        selection = []
        reload()
    }

    func currentQuery(offset: Int = 0) -> ClipQuery {
        var query = ClipQuery(limit: Self.pageSize, offset: offset)
        if case .pinboard(let id) = tab { query.collection = .pinboard(id) }
        query.text = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
        query.kinds = kindFilter.map { [$0] } ?? []
        if case .kind(let kind) = tab { query.kinds = [kind] }
        query.sourceBundleID = sourceFilter?.bundleID
        query.from = dateFilter?.from
        return query
    }

    func reload(debounce: Bool = false) {
        reloadTask?.cancel()
        let query = currentQuery()
        reloadTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(70)) }
            guard !Task.isCancelled, let self else { return }
            guard let loaded = try? await self.service.list(query), !Task.isCancelled else { return }
            self.apply(loaded)
        }
    }

    private func apply(_ loaded: [Clip]) {
        // Rebuilding every card is the expensive part of a refresh, so unchanged results are dropped here.
        if loaded != clips {
            clips = loaded
            hasMore = loaded.count == Self.pageSize
        }
        if cursorID == nil || !loaded.contains(where: { $0.id == cursorID }) {
            cursorID = loaded.first?.id
            selection = cursorID.map { [$0] } ?? []
            scrollRequest += 1
        }
        selection.formIntersection(loaded.map(\.id))
    }

    func loadPinboards() async {
        pinboards = (try? await service.pinboards()) ?? []
        if case .pinboard(let id) = tab, !pinboards.contains(where: { $0.id == id }) { tab = .history }
    }

    func loadSources() {
        Task { sources = (try? await service.sourceApps()) ?? [] }
    }

    func loadMoreIfNeeded(index: Int) {
        guard hasMore, !loadingMore, index >= clips.count - 12 else { return }
        loadingMore = true
        let query = currentQuery(offset: clips.count)
        Task {
            defer { loadingMore = false }
            guard let more = try? await service.list(query), query == currentQuery(offset: clips.count) else { return }
            clips.append(contentsOf: more)
            hasMore = more.count == Self.pageSize
        }
    }

    // MARK: Navigation

    func move(by offset: Int, extendSelection: Bool) {
        guard !clips.isEmpty else { return }
        let current = clips.firstIndex { $0.id == cursorID } ?? 0
        let next = min(max(current + offset, 0), clips.count - 1)
        let id = clips[next].id
        cursorID = id
        if extendSelection {
            selection.insert(id)
        } else {
            selection = [id]
        }
        loadMoreIfNeeded(index: next)
    }

    func select(_ id: Int64, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(id), selection.count > 1 {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
        } else if modifiers.contains(.shift),
                  let anchor = clips.firstIndex(where: { $0.id == cursorID }),
                  let target = clips.firstIndex(where: { $0.id == id }) {
            selection.formUnion(clips[min(anchor, target)...max(anchor, target)].map(\.id))
        } else {
            selection = [id]
        }
        cursorID = id
    }

    func selectAll() {
        selection = Set(clips.map(\.id))
    }

    func cycleTab(by offset: Int) {
        let tabs: [PanelTab] = [.history] + settings.pinnedKinds.map { .kind($0) } + pinboards.map { .pinboard($0.id) }
        guard let current = tabs.firstIndex(of: tab) else { return }
        tab = tabs[(current + offset + tabs.count) % tabs.count]
    }

    // MARK: Actions

    /// Selected clips in on-screen order, which is the order they paste in.
    var orderedSelection: [Int64] {
        let picked = clips.filter { selection.contains($0.id) }.map(\.id)
        return picked.isEmpty ? (cursorID.map { [$0] } ?? []) : picked
    }

    func pasteSelection(plain: Bool) {
        actions.paste(orderedSelection, plain ? .plainText : .original)
    }

    func quickPaste(number: Int, plain: Bool) {
        guard clips.indices.contains(number - 1) else { return }
        actions.paste([clips[number - 1].id], plain ? .plainText : .original)
    }

    func editCursor() {
        if let cursorID { actions.edit(cursorID) }
    }

    func quickLookCursor() {
        if let cursorID { actions.quickLook(cursorID) }
    }

    func deleteSelection() {
        let ids = orderedSelection
        guard !ids.isEmpty else { return }
        let next = neighbour(of: ids)
        cursorID = next
        selection = next.map { [$0] } ?? []
        Task {
            try? await service.apply(ids.map { .softDelete(clipID: $0) }, source: .user, summary: L("删除 \(ids.count) 项"))
        }
    }

    private func neighbour(of removed: [Int64]) -> Int64? {
        let gone = Set(removed)
        guard let first = clips.firstIndex(where: { gone.contains($0.id) }) else { return nil }
        return clips[first...].first { !gone.contains($0.id) }?.id ?? clips[..<first].last?.id
    }

    func pin(_ ids: [Int64], to board: Int64) {
        Task {
            try? await service.apply(ids.map { .addToPinboard(clipID: $0, pinboardID: board) }, source: .user, summary: L("加入 Pinboard"))
        }
    }

    func unpinFromCurrentBoard(_ ids: [Int64]) {
        guard case .pinboard(let board) = tab else { return }
        Task {
            try? await service.apply(ids.map { .removeFromPinboard(clipID: $0, pinboardID: board) }, source: .user, summary: L("移出 Pinboard"))
        }
    }

    func createPinboard(name: String, colorHex: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            if let id = try? await service.createPinboard(name: name, colorHex: colorHex) {
                await loadPinboards()
                tab = .pinboard(id)
            }
        }
    }

    func update(_ board: Pinboard) {
        Task { try? await service.updatePinboard(board) }
    }

    func delete(_ board: Pinboard) {
        Task { try? await service.deletePinboard(id: board.id) }
    }

    func setAIHidden(_ ids: [Int64], hidden: Bool) {
        Task {
            try? await service.apply(ids.map { .setAIHidden(clipID: $0, hidden: hidden) }, source: .user, summary: L("调整 AI 可见性"))
        }
    }

    func iconURL(for clip: Clip) -> URL? {
        clip.thumbnailPath.map { service.paths.thumbnails.appending(path: $0) }
    }
}
