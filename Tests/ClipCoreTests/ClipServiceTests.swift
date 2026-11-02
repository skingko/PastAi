import AppKit
import Foundation
import Testing
@testable import ClipCore

func makeService() throws -> ClipService {
    let root = FileManager.default.temporaryDirectory.appending(path: "pastai-\(UUID().uuidString)", directoryHint: .isDirectory)
    return try ClipService(paths: AppPaths(root: root))
}

extension ClipService {
    @discardableResult
    func addText(_ text: String, at date: Date = Date(), app: String = "com.test") async throws -> Int64 {
        let snapshot = PasteboardSnapshot(items: [[PasteboardEntry(uti: PasteboardTypes.plainText, data: Data(text.utf8))]])
        let draft = try #require(ClipBuilder.build(snapshot, source: SourceInfo(bundleID: app, name: app)))
        return try await ingest(draft, now: date).clipID
    }
}

@Suite struct IngestAndSearchTests {
    @Test func duplicateCopyMovesToTopInsteadOfInserting() async throws {
        let service = try makeService()
        let old = Date(timeIntervalSince1970: 1_000)
        let first = try await service.addText("same", at: old)
        try await service.addText("other", at: old.addingTimeInterval(1))
        let second = try await service.addText("same", at: old.addingTimeInterval(2))
        #expect(first == second)

        let clips = try await service.list(ClipQuery())
        #expect(clips.count == 2)
        #expect(clips[0].id == first)
        #expect(clips[0].copyCount == 2)
    }

    @Test func recopyingAClipRestoresItFromTrash() async throws {
        let service = try makeService()
        let id = try await service.addText("back again")
        try await service.apply([.softDelete(clipID: id)], source: .user, summary: "删除")
        #expect(try await service.list(ClipQuery()).isEmpty)
        try await service.addText("back again")
        #expect(try await service.list(ClipQuery()).map(\.id) == [id])
    }

    @Test func chineseTwoCharacterSearchFindsOnlyContiguousMatches() async throws {
        let service = try makeService()
        let hit = try await service.addText("今天天气不错")
        try await service.addText("气象台说天很蓝")
        #expect(try await service.list(ClipQuery(text: "天气")).map(\.id) == [hit])
    }

    @Test func mixedAndPrefixSearch() async throws {
        let service = try makeService()
        let hit = try await service.addText("远程部署 nginx 配置")
        try await service.addText("nginx 官方文档")
        #expect(try await service.list(ClipQuery(text: "nginx 配置")).map(\.id) == [hit])
        #expect(try await service.list(ClipQuery(text: "ngi")).count == 2)
    }

    @Test func punctuationSearchFallsBackToSubstring() async throws {
        let service = try makeService()
        let hit = try await service.addText("https://example.com/path")
        try await service.addText("plain words")
        #expect(try await service.list(ClipQuery(text: "://")).map(\.id) == [hit])
    }

    @Test func substringInsideAWordFallsBackWhenTheIndexMisses() async throws {
        let service = try makeService()
        let hit = try await service.addText("kubernetes cluster")
        #expect(try await service.list(ClipQuery(text: "bernet")).map(\.id) == [hit])
    }

    @Test func filtersCombineWithSearch() async throws {
        let service = try makeService()
        let now = Date()
        try await service.addText("部署 old", at: now.addingTimeInterval(-10 * 86_400), app: "com.a")
        let hit = try await service.addText("部署 new", at: now, app: "com.b")
        try await service.addText("https://部署.example.com", at: now, app: "com.b")

        let bySource = try await service.list(ClipQuery(text: "部署", kinds: [.text], sourceBundleID: "com.b"))
        #expect(bySource.map(\.id) == [hit])
        let byDate = try await service.list(ClipQuery(text: "部署", kinds: [.text], from: now.addingTimeInterval(-86_400)))
        #expect(byDate.map(\.id) == [hit])
    }

    @Test func filteredSearchStillReachesClipsOlderThanTheRankingWindow() async throws {
        let service = try makeService()
        let base = Date()
        let old = try await service.addText("https://部署.example.com/old", at: base)
        for index in 0..<(ClipService.rankingWindow + 50) {
            try await service.addText("部署 第 \(index) 条", at: base.addingTimeInterval(Double(index + 1)))
        }
        #expect(try await service.list(ClipQuery(text: "部署", kinds: [.link])).map(\.id) == [old])
        #expect(try await service.count(ClipQuery(text: "部署")) == ClipService.rankingWindow + 51)
    }

    @Test func titleMatchOutranksBodyMatchOfSimilarAge() async throws {
        let service = try makeService()
        let now = Date()
        let body = try await service.addText("这里随口提到了 kubernetes 这个词", at: now)
        let titled = try await service.addText("完全无关的内容", at: now)
        try await service.apply([.setTitle(clipID: titled, title: "kubernetes 手册")], source: .user, summary: "标题")
        #expect(try await service.list(ClipQuery(text: "kubernetes")).map(\.id) == [titled, body])
    }

    @Test func paginationWalksEveryRowOnce() async throws {
        let service = try makeService()
        let base = Date()
        for index in 0..<25 { try await service.addText("row \(index)", at: base.addingTimeInterval(Double(index))) }
        var seen: [Int64] = []
        for page in 0..<3 {
            seen += try await service.list(ClipQuery(limit: 10, offset: page * 10)).map(\.id)
        }
        #expect(seen.count == 25)
        #expect(Set(seen).count == 25)
    }

    @Test func listTruncatesLongTextButDetailReturnsAll() async throws {
        let service = try makeService()
        let text = String(repeating: "长", count: 5_000)
        let id = try await service.addText(text)
        let listed = try #require(try await service.list(ClipQuery()).first)
        #expect(listed.isTextTruncated)
        let detail = try #require(try await service.detail(id: id))
        #expect(detail.clip.plainText == text)
    }
}

@Suite struct MutationTests {
    @Test func editIsSearchableAndUndoRestoresRichContent() async throws {
        let service = try makeService()
        let snapshot = PasteboardSnapshot(items: [[
            PasteboardEntry(uti: PasteboardTypes.plainText, data: Data("原文内容".utf8)),
            PasteboardEntry(uti: PasteboardTypes.html, data: Data("<b>原文内容</b>".utf8)),
        ]])
        let draft = try #require(ClipBuilder.build(snapshot, source: SourceInfo(bundleID: nil, name: nil)))
        let id = try await service.ingest(draft).clipID

        let applied = try await service.apply([.setText(clipID: id, text: "修改之后")], source: .agent, summary: "改写")
        #expect(try await service.list(ClipQuery(text: "修改")).map(\.id) == [id])
        #expect(try await service.list(ClipQuery(text: "原文")).isEmpty)
        let edited = try #require(try await service.detail(id: id))
        #expect(edited.representations.map(\.uti) == [PasteboardTypes.plainText])

        try await service.undo(batchID: applied.batchID)
        let restored = try #require(try await service.detail(id: id))
        #expect(restored.clip.plainText == "原文内容")
        #expect(restored.representations.map(\.uti) == [PasteboardTypes.plainText, PasteboardTypes.html])
        #expect(try await service.list(ClipQuery(text: "原文")).map(\.id) == [id])
    }

    @Test func editCollidingWithAnotherClipKeepsBoth() async throws {
        let service = try makeService()
        try await service.addText("alpha")
        let id = try await service.addText("beta")
        try await service.apply([.setText(clipID: id, text: "alpha")], source: .user, summary: "改")
        #expect(try await service.list(ClipQuery()).count == 2)
    }

    @Test func imagesCannotBeEditedAsText() async throws {
        let service = try makeService()
        let snapshot = PasteboardSnapshot(items: [[PasteboardEntry(uti: PasteboardTypes.png, data: Data([1, 2, 3]))]])
        let draft = try #require(ClipBuilder.build(snapshot, source: SourceInfo(bundleID: nil, name: nil)))
        let id = try await service.ingest(draft).clipID
        await #expect(throws: ClipServiceError.notEditable(id)) {
            try await service.apply([.setText(clipID: id, text: "x")], source: .agent, summary: "改")
        }
    }

    @Test func failedBatchChangesNothing() async throws {
        let service = try makeService()
        let id = try await service.addText("keep")
        await #expect(throws: ClipServiceError.clipNotFound(9_999)) {
            try await service.apply(
                [.setTitle(clipID: id, title: "新标题"), .setTitle(clipID: 9_999, title: "x")],
                source: .agent, summary: "批量"
            )
        }
        #expect(try await service.detail(id: id)?.clip.title == nil)
        #expect(try await service.recentBatches().isEmpty)
    }

    @Test func undoReversesAWholeRun() async throws {
        let service = try makeService()
        let a = try await service.addText("a")
        let b = try await service.addText("b")
        let batch = "run-1"
        let board = try await service.apply([.createPinboard(name: "整理", colorHex: nil)], source: .agent, summary: "建", batchID: batch).createdPinboardIDs[0]
        let created = try await service.apply(
            [.createText(text: "合并结果", title: "合并", pinboardID: board)], source: .agent, summary: "合并", batchID: batch
        ).createdClipIDs[0]
        try await service.apply(
            [.addToPinboard(clipID: a, pinboardID: board), .setTags(clipID: b, tags: ["工作"]), .softDelete(clipID: b)],
            source: .agent, summary: "整理", batchID: batch
        )

        try await service.undo(batchID: batch)
        #expect(try await service.pinboards().isEmpty)
        #expect(try await service.detail(id: a)?.pinboardIDs.isEmpty == true)
        let restored = try #require(try await service.detail(id: b))
        #expect(restored.clip.deletedAt == nil)
        #expect(restored.tags.isEmpty)
        #expect(try await service.detail(id: created)?.clip.deletedAt != nil)
    }

    @Test func tagsAreSearchable() async throws {
        let service = try makeService()
        let id = try await service.addText("plain body")
        try await service.apply([.setTags(clipID: id, tags: ["运维", " 脚本 "])], source: .user, summary: "标签")
        #expect(try await service.list(ClipQuery(text: "运维")).map(\.id) == [id])
        #expect(try await service.list(ClipQuery(tag: "脚本")).map(\.id) == [id])
    }
}

@Suite struct VisibilityTests {
    @Test func agentScopeHidesSensitiveHiddenAndHiddenPinboards() async throws {
        let service = try makeService()
        let open = try await service.addText("普通内容 alpha")
        let secret = try await service.addText("sk-abcdefghijklmnopqrstuvwxyz123456 alpha")
        let flagged = try await service.addText("手动隐藏 alpha")
        let boarded = try await service.addText("快捷密码 alpha")

        let board = try await service.createPinboard(name: "快捷密码")
        var pinboard = try #require(try await service.pinboards().first)
        pinboard.aiHidden = true
        try await service.updatePinboard(pinboard)
        try await service.apply(
            [.addToPinboard(clipID: boarded, pinboardID: board), .setAIHidden(clipID: flagged, hidden: true)],
            source: .user, summary: "隐藏"
        )

        #expect(try await service.list(ClipQuery(text: "alpha")).count == 4)
        #expect(try await service.list(ClipQuery(text: "alpha"), scope: .agent).map(\.id) == [open])
        #expect(try await service.list(ClipQuery(), scope: .agent).map(\.id) == [open])
        #expect(try await service.count(ClipQuery(), scope: .agent) == 1)
        #expect(try await service.detail(id: secret, scope: .agent) == nil)
        #expect(try await service.detail(id: boarded, scope: .agent) == nil)
        #expect(try await service.pinboards(scope: .agent).isEmpty)
        #expect(try await service.stats(scope: .agent).total == 1)
    }
}

@Suite struct RetentionTests {
    let policy = RetentionPolicy(historyDays: 90, mediaCapBytes: 1_000)

    @Test func expiresOldHistoryButNeverPinned() async throws {
        let service = try makeService()
        let now = Date()
        let old = now.addingTimeInterval(-100 * 86_400)
        let expired = try await service.addText("expired", at: old)
        let pinned = try await service.addText("pinned", at: old)
        let fresh = try await service.addText("fresh", at: now)
        let board = try await service.createPinboard(name: "保留")
        try await service.apply([.addToPinboard(clipID: pinned, pinboardID: board)], source: .user, summary: "钉")

        let report = try await service.runRetention(policy, now: now)
        #expect(report.trashed == 1)
        #expect(try await service.detail(id: expired)?.clip.deletedAt != nil)
        #expect(try await service.list(ClipQuery()).map(\.id).sorted() == [pinned, fresh].sorted())
    }

    @Test func aUsedClipBecomesTheFirstCard() async throws {
        let service = try makeService()
        let now = Date()
        let older = try await service.addText("较早", at: now.addingTimeInterval(-100))
        let newer = try await service.addText("较新", at: now.addingTimeInterval(-50))
        #expect(try await service.list(ClipQuery()).map(\.id) == [newer, older])

        try await service.recordUse(clipID: older, now: now)

        #expect(try await service.list(ClipQuery()).map(\.id) == [older, newer])
        let clip = try #require(try await service.detail(id: older)).clip
        #expect(clip.useCount == 1)
        #expect(clip.createdAt < clip.lastCopiedAt)
    }

    @Test func aUsedClipMovesToTheFrontOfItsPinboardToo() async throws {
        let service = try makeService()
        let now = Date()
        let board = try await service.createPinboard(name: "常用")
        let first = try await service.addText("甲", at: now.addingTimeInterval(-100))
        let second = try await service.addText("乙", at: now.addingTimeInterval(-90))
        try await service.apply([.addToPinboard(clipID: first, pinboardID: board)], source: .user, summary: "x", now: now.addingTimeInterval(-80))
        try await service.apply([.addToPinboard(clipID: second, pinboardID: board)], source: .user, summary: "x", now: now.addingTimeInterval(-70))
        #expect(try await service.list(ClipQuery(collection: .pinboard(board))).map(\.id) == [second, first])

        try await service.recordUse(clipID: first, now: now)

        #expect(try await service.list(ClipQuery(collection: .pinboard(board))).map(\.id) == [first, second])
    }

    @Test func aFileReferenceTakesNoRoomInTheMediaCap() async throws {
        let service = try makeService()
        let now = Date()
        let picture = PasteboardSnapshot(items: [[PasteboardEntry(uti: PasteboardTypes.png, data: Data(repeating: 7, count: 2_000))]])
        let image = try await service.ingest(try #require(ClipBuilder.build(picture, source: SourceInfo(bundleID: nil, name: nil))), now: now).clipID
        var draft = try #require(ClipBuilder.build(picture, source: SourceInfo(bundleID: nil, name: nil)))
        draft.kind = .video
        draft.contentHash = "reference"
        draft.entries = []
        draft.files = [DraftFile(path: "/Volumes/nas/huge.mov", fileName: "huge.mov", uti: "public.movie", byteSize: 500_000_000_000, isDirectory: false, bookmark: nil)]
        let reference = try await service.ingest(draft, now: now).clipID

        let report = try await service.runRetention(RetentionPolicy(historyDays: 0, mediaCapBytes: 10_000), now: now)

        #expect(report.evicted == 0)
        #expect(try await service.detail(id: image) != nil)
        #expect(try await service.detail(id: reference) != nil)
    }

    @Test func importedClipsRetainTheirDateButGetAFullRetentionPeriod() async throws {
        let service = try makeService()
        let now = Date()
        let original = now.addingTimeInterval(-400 * 86_400)
        let snapshot = PasteboardSnapshot(items: [[PasteboardEntry(uti: PasteboardTypes.plainText, data: Data("旧记录".utf8))]])
        let draft = try #require(ClipBuilder.build(snapshot, source: SourceInfo(bundleID: nil, name: nil)))
        let id = try await service.ingest(draft, now: original, importedAt: now).clipID

        try await service.runRetention(policy, now: now)
        let clip = try #require(try await service.detail(id: id)).clip
        #expect(clip.deletedAt == nil)
        #expect(abs(clip.lastCopiedAt.timeIntervalSince(original)) < 1)
    }

    @Test func importingNeverRegressesAClipAlreadyInTheLibrary() async throws {
        let service = try makeService()
        let now = Date()
        let id = try await service.addText("两边都有", at: now)
        let snapshot = PasteboardSnapshot(items: [[PasteboardEntry(uti: PasteboardTypes.plainText, data: Data("两边都有".utf8))]])
        let draft = try #require(ClipBuilder.build(snapshot, source: SourceInfo(bundleID: nil, name: nil)))
        let result = try await service.ingest(draft, now: now.addingTimeInterval(-1_000), importedAt: now)

        #expect(!result.isNew)
        #expect(result.clipID == id)
        let clip = try #require(try await service.detail(id: id)).clip
        #expect(clip.copyCount == 1)
        #expect(abs(clip.lastCopiedAt.timeIntervalSince(now)) < 1)
    }

    @Test func purgesTrashAfterThirtyDays() async throws {
        let service = try makeService()
        let now = Date()
        let id = try await service.addText("gone")
        try await service.apply([.softDelete(clipID: id)], source: .user, summary: "删", now: now.addingTimeInterval(-31 * 86_400))
        let report = try await service.runRetention(policy, now: now)
        #expect(report.purged == 1)
        #expect(try await service.detail(id: id) == nil)
        #expect(try await service.list(ClipQuery(text: "gone")).isEmpty)
    }

    @Test func mediaCapEvictsLeastRecentlyUsedUnpinned() async throws {
        let service = try makeService()
        let now = Date()
        func addImage(_ byte: UInt8, at date: Date) async throws -> Int64 {
            let snapshot = PasteboardSnapshot(items: [[PasteboardEntry(uti: PasteboardTypes.png, data: Data(repeating: byte, count: 600))]])
            let draft = try #require(ClipBuilder.build(snapshot, source: SourceInfo(bundleID: nil, name: nil)))
            return try await service.ingest(draft, now: date).clipID
        }
        let oldest = try await addImage(1, at: now.addingTimeInterval(-300))
        let middle = try await addImage(2, at: now.addingTimeInterval(-200))
        let newest = try await addImage(3, at: now.addingTimeInterval(-100))

        let report = try await service.runRetention(policy, now: now)
        #expect(report.evicted == 2)
        #expect(try await service.detail(id: oldest) == nil)
        #expect(try await service.detail(id: middle) == nil)
        #expect(try await service.detail(id: newest) != nil)
    }
}
