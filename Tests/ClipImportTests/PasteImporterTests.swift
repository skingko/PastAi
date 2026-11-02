import ClipCore
import Foundation
import Testing
@testable import ClipImport

/// A synthetic Paste library with made-up data, built from the schema so tests never need a real one.
private struct FakePasteLibrary {
    let root: URL
    let connection: SQLiteConnection
    private var nextKey: Int64 = 1

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "fake-paste-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: ".db_SUPPORT/_EXTERNAL_DATA"), withIntermediateDirectories: true)
        connection = try SQLiteConnection(path: root.appending(path: "db.sqlite").path)
        try connection.script(
            """
            CREATE TABLE ZAPPLICATIONENTITY(Z_PK INTEGER PRIMARY KEY, ZBUNDLEIDENTIFIER VARCHAR, ZNAME VARCHAR);
            CREATE TABLE ZLISTENTITY(Z_PK INTEGER PRIMARY KEY, ZRAWTYPE INTEGER, ZNAME VARCHAR);
            CREATE TABLE ZITEMDATAENTITY(Z_PK INTEGER PRIMARY KEY, ZITEM INTEGER, ZRAWPASTEBOARDITEMS BLOB);
            CREATE TABLE ZITEMENTITY(Z_PK INTEGER PRIMARY KEY, ZRAWTYPE INTEGER, ZDATA INTEGER, ZLIST INTEGER,
                ZSOURCEAPPLICATION INTEGER, ZTIMESTAMP TIMESTAMP, ZTITLE VARCHAR);
            INSERT INTO ZAPPLICATIONENTITY VALUES (1, 'com.test.notes', 'Notes');
            INSERT INTO ZAPPLICATIONENTITY VALUES (2, 'com.1password.1password', '1Password');
            """
        )
    }

    static func plist(_ items: [[String: Data]]) throws -> Data {
        let wrapped: [[String: Any]] = items.map { ["data": $0] }
        return try PropertyListSerialization.data(fromPropertyList: wrapped, format: .binary, options: 0)
    }

    func addBoard(key: Int64, name: String) throws {
        try connection.execute("INSERT INTO ZLISTENTITY VALUES (?, 2, ?)", [key, name])
    }

    mutating func addItem(
        _ blob: Data, rawType: Int = 1, app: Int64 = 1, date: Date = Date(timeIntervalSince1970: 1_700_000_000),
        title: String? = nil, list: Int64? = nil
    ) throws {
        let key = nextKey
        nextKey += 1
        try connection.execute("INSERT INTO ZITEMDATAENTITY VALUES (?, ?, ?)", [key, key, blob])
        try connection.execute(
            "INSERT INTO ZITEMENTITY VALUES (?, ?, ?, ?, ?, ?, ?)",
            [key, rawType, key, list, app, date.timeIntervalSinceReferenceDate, title]
        )
    }

    /// Stored inline, the way Core Data does for small values.
    static func inline(_ data: Data) -> Data { Data([1]) + data }

    /// Stored in a side file, the way Core Data does for large values.
    func external(_ data: Data) throws -> Data {
        let name = UUID().uuidString
        try data.write(to: root.appending(path: ".db_SUPPORT/_EXTERNAL_DATA").appending(path: name))
        return Data([2]) + Data(name.utf8) + Data([0])
    }
}

private func makeService() throws -> ClipService {
    let root = FileManager.default.temporaryDirectory.appending(path: "pastai-import-\(UUID().uuidString)", directoryHint: .isDirectory)
    return try ClipService(paths: AppPaths(root: root))
}

private func text(_ value: String) throws -> Data {
    try FakePasteLibrary.plist([[PasteboardTypes.plainText: Data(value.utf8)]])
}

@Suite struct PasteDecoderTests {
    @Test func readsInlineAndExternalAndCompressedRecords() throws {
        let library = try FakePasteLibrary()
        let external = library.root.appending(path: ".db_SUPPORT/_EXTERNAL_DATA")
        let plist = try text("内容")
        let compressed = try (plist as NSData).compressed(using: .lzfse) as Data
        let raw = try (plist as NSData).compressed(using: .zlib) as Data

        for stored in [FakePasteLibrary.inline(plist), FakePasteLibrary.inline(compressed), FakePasteLibrary.inline(raw), try library.external(compressed)] {
            let items = try PasteRecordDecoder.pasteboardItems(blob: stored, externalRoot: external)
            #expect(items.first?.first?.data == Data("内容".utf8))
        }
    }

    @Test func readsTheJSONFormOfARecord() throws {
        let library = try FakePasteLibrary()
        let encoded = Data("内容".utf8).base64EncodedString()
        let json = Data(#"[{"dataByType":{"public.utf8-plain-text":"\#(encoded)"},"types":["public.utf8-plain-text"]}]"#.utf8)
        let raw = try (json as NSData).compressed(using: .zlib) as Data

        for stored in [json, raw] {
            let items = try PasteRecordDecoder.pasteboardItems(blob: FakePasteLibrary.inline(stored), externalRoot: library.root)
            #expect(items == [[PasteboardEntry(uti: PasteboardTypes.plainText, data: Data("内容".utf8))]])
        }
    }

    @Test func textComesBeforeImagesWhateverTheDictionaryOrder() {
        let entries = ["public.png", "com.acme.x", PasteboardTypes.html, PasteboardTypes.plainText].map { PasteboardEntry(uti: $0, data: Data()) }
        #expect(PasteRecordDecoder.order(entries).map(\.uti) == [PasteboardTypes.plainText, PasteboardTypes.html, "public.png", "com.acme.x"])
    }

    @Test func unknownMarkerAndBrokenFilesAreReported() throws {
        let library = try FakePasteLibrary()
        let external = library.root
        #expect(throws: PasteRecordError.badMarker) {
            _ = try PasteRecordDecoder.pasteboardItems(blob: Data([9, 1]), externalRoot: external)
        }
        #expect(throws: PasteRecordError.missingExternalFile) {
            _ = try PasteRecordDecoder.pasteboardItems(blob: Data([2]) + Data("nope".utf8), externalRoot: external)
        }
    }

    @Test func externalNamesCannotLeaveTheFolder() throws {
        let library = try FakePasteLibrary()
        #expect(throws: PasteRecordError.badMarker) {
            _ = try PasteRecordDecoder.pasteboardItems(blob: Data([2]) + Data("../../etc/passwd".utf8), externalRoot: library.root)
        }
    }
}

@Suite struct PasteImportTests {
    @Test func importsClipsWithTheirDatesSourceTitlesAndPinboards() async throws {
        var library = try FakePasteLibrary()
        try library.addBoard(key: 7, name: "常用提示词")
        let date = Date(timeIntervalSince1970: 1_650_000_000)
        try library.addItem(FakePasteLibrary.inline(try text("第一条")), date: date, title: "标题", list: 7)
        let image = try FakePasteLibrary.plist([["public.png": Data([1, 2, 3])]])
        try library.addItem(try library.external(try (image as NSData).compressed(using: .lzfse) as Data), rawType: 5)

        let service = try makeService()
        let report = try await PasteImporter(library: library.root, service: service).run(dryRun: false)

        #expect(report.total == 2)
        #expect(report.imported == 2)
        #expect(report.kinds == ["text": 1, "image": 1])
        #expect(report.pinboardsCreated == 1)
        #expect(report.pinned == 1)
        let clips = try await service.list(ClipQuery())
        let first = try #require(clips.first { $0.plainText == "第一条" })
        #expect(first.title == "标题")
        #expect(first.sourceBundleID == "com.test.notes")
        #expect(first.sourceAppName == "Notes")
        #expect(abs(first.lastCopiedAt.timeIntervalSince(date)) < 1)
        let board = try #require(try await service.pinboards().first)
        #expect(try await service.list(ClipQuery(collection: .pinboard(board.id))).map(\.id) == [first.id])
    }

    @Test func dryRunCountsEverythingAndWritesNothing() async throws {
        var library = try FakePasteLibrary()
        try library.addBoard(key: 1, name: "x")
        try library.addItem(FakePasteLibrary.inline(try text("a")), list: 1)
        let service = try makeService()
        let report = try await PasteImporter(library: library.root, service: service).run(dryRun: true)

        #expect(report.imported == 1)
        #expect(try await service.list(ClipQuery()).isEmpty)
        #expect(try await service.pinboards().isEmpty)
    }

    @Test func runningTwiceAddsNothing() async throws {
        var library = try FakePasteLibrary()
        try library.addItem(FakePasteLibrary.inline(try text("a")))
        let service = try makeService()
        _ = try await PasteImporter(library: library.root, service: service).run(dryRun: false)
        let second = try await PasteImporter(library: library.root, service: service).run(dryRun: false)

        #expect(second.imported == 0)
        #expect(second.alreadyPresent == 1)
        #expect(try await service.list(ClipQuery()).count == 1)
    }

    @Test func pastesOwnHistoryListIsNotAPinboard() async throws {
        var library = try FakePasteLibrary()
        try library.connection.execute("INSERT INTO ZLISTENTITY VALUES (9, 1, 'Clipboard')")
        try library.addItem(FakePasteLibrary.inline(try text("a")), list: 9)
        let service = try makeService()
        let report = try await PasteImporter(library: library.root, service: service).run(dryRun: false)

        #expect(report.imported == 1)
        #expect(report.pinboardsCreated == 0)
        #expect(try await service.pinboards().isEmpty)
    }

    @Test func secondRunLeavesPinboardMembershipAlone() async throws {
        var library = try FakePasteLibrary()
        try library.addBoard(key: 1, name: "工作")
        try library.addItem(FakePasteLibrary.inline(try text("a")), list: 1)
        let service = try makeService()
        _ = try await PasteImporter(library: library.root, service: service).run(dryRun: false)
        _ = try await PasteImporter(library: library.root, service: service).run(dryRun: false)

        let board = try #require(try await service.pinboards().first)
        #expect(try await service.pinboardCounts()[board.id] == 1)
    }

    @Test func fileReferencesStayReferencesAndNothingIsCopied() async throws {
        var library = try FakePasteLibrary()
        let original = library.root.appending(path: "report.pdf")
        try Data("pdf".utf8).write(to: original)
        let record = try FakePasteLibrary.plist([[PasteboardTypes.fileURL: Data(original.absoluteString.utf8)]])
        try library.addItem(FakePasteLibrary.inline(record))
        let service = try makeService()
        let report = try await PasteImporter(library: library.root, service: service).run(dryRun: false)

        let clip = try #require(try await service.list(ClipQuery()).first)
        let detail = try #require(try await service.detail(id: clip.id))
        #expect(detail.files.map(\.originalPath) == [original.standardizedFileURL.path])
        #expect(detail.files.first?.snapshotPath == nil)
        #expect(report.bytes == 0)
        #expect(report.missingFiles == 0)
    }

    @Test func aFileThatIsGoneStaysAsAReferenceThatReportsIt() async throws {
        var library = try FakePasteLibrary()
        let record = try FakePasteLibrary.plist([[
            PasteboardTypes.fileURL: Data("file:///nowhere/gone.pdf".utf8), "com.apple.icns": Data([1]), "public.tiff": Data([2]),
        ]])
        try library.addItem(FakePasteLibrary.inline(record))
        let service = try makeService()
        let report = try await PasteImporter(library: library.root, service: service).run(dryRun: false)

        #expect(report.missingFiles == 1)
        #expect(report.recoveredImages == 0)
        #expect(report.kinds == ["file": 1])
    }

    @Test func aDeadFinderReferenceKeepsTheFileName() async throws {
        var library = try FakePasteLibrary()
        let record = try FakePasteLibrary.plist([[
            PasteboardTypes.fileURL: Data("file:///.file/id=1.999999999".utf8), PasteboardTypes.plainText: Data("gone.pdf".utf8),
        ]])
        try library.addItem(FakePasteLibrary.inline(record))
        let service = try makeService()
        let report = try await PasteImporter(library: library.root, service: service).run(dryRun: false)

        #expect(report.missingFiles == 1)
        #expect(try await service.list(ClipQuery()).first?.plainText == "gone.pdf")
    }

    @Test func aScreenshotWhoseTemporaryFileIsGoneKeepsThePicture() async throws {
        var library = try FakePasteLibrary()
        let picture = Data([9, 8, 7])
        let record = try FakePasteLibrary.plist([[
            PasteboardTypes.fileURL: Data("file:///private/var/folders/x/y.png".utf8),
            PasteboardTypes.plainText: Data("y.png".utf8),
            "public.png": picture,
        ]])
        try library.addItem(FakePasteLibrary.inline(record))
        let service = try makeService()
        let report = try await PasteImporter(library: library.root, service: service).run(dryRun: false)

        #expect(report.recoveredImages == 1)
        #expect(report.kinds == ["image": 1])
        let clip = try #require(try await service.list(ClipQuery()).first)
        let detail = try #require(try await service.detail(id: clip.id))
        #expect(detail.files.isEmpty)
        #expect(try detail.representations.first.flatMap(service.data(for:)) == picture)
    }

    @Test func existingPinboardIsReusedByName() async throws {
        var library = try FakePasteLibrary()
        try library.addBoard(key: 3, name: "工作")
        try library.addItem(FakePasteLibrary.inline(try text("a")), list: 3)
        let service = try makeService()
        let id = try await service.createPinboard(name: "工作")
        let report = try await PasteImporter(library: library.root, service: service).run(dryRun: false)

        #expect(report.pinboardsCreated == 0)
        #expect(try await service.pinboards().map(\.id) == [id])
        #expect(try await service.pinboardCounts()[id] == 1)
    }

    @Test(arguments: ["快捷密码", "Passwords", "API token", "我的账号"])
    func credentialBoardsAreHiddenFromAI(name: String) async throws {
        var library = try FakePasteLibrary()
        try library.addBoard(key: 1, name: name)
        try library.addItem(FakePasteLibrary.inline(try text("不是敏感格式的文字")), list: 1)
        let service = try makeService()
        let report = try await PasteImporter(library: library.root, service: service).run(dryRun: false)

        #expect(report.pinboardsHiddenFromAI == 1)
        #expect(try await service.list(ClipQuery(), scope: .agent).isEmpty)
    }

    @Test func ordinaryBoardsStayVisibleToAI() async throws {
        var library = try FakePasteLibrary()
        try library.addBoard(key: 1, name: "常用提示词")
        try library.addItem(FakePasteLibrary.inline(try text("公开内容")), list: 1)
        let service = try makeService()
        _ = try await PasteImporter(library: library.root, service: service).run(dryRun: false)
        #expect(try await service.list(ClipQuery(), scope: .agent).count == 1)
    }

    @Test func secretsAndIgnoredAppsAreLeftBehind() async throws {
        var library = try FakePasteLibrary()
        try library.addItem(FakePasteLibrary.inline(try text("来自密码管理器")), app: 2)
        let concealed = try FakePasteLibrary.plist([[PasteboardTypes.plainText: Data("hunter2".utf8), "org.nspasteboard.ConcealedType": Data()]])
        try library.addItem(FakePasteLibrary.inline(concealed))
        let service = try makeService()
        let report = try await PasteImporter(library: library.root, service: service, ignoredApps: ["com.1password.1password"]).run(dryRun: false)

        #expect(report.skippedIgnoredApp == 1)
        #expect(report.skippedSecret == 1)
        #expect(try await service.list(ClipQuery()).isEmpty)
    }

    @Test func detectedCredentialsStayHiddenFromAI() async throws {
        var library = try FakePasteLibrary()
        try library.addItem(FakePasteLibrary.inline(try text("sk-abcdefghijklmnopqrstuvwxyz123456")))
        let service = try makeService()
        _ = try await PasteImporter(library: library.root, service: service).run(dryRun: false)
        #expect(try await service.list(ClipQuery()).count == 1)
        #expect(try await service.list(ClipQuery(), scope: .agent).isEmpty)
    }

    @Test func oneBrokenRecordDoesNotStopTheRest() async throws {
        var library = try FakePasteLibrary()
        try library.addItem(Data([1, 0, 0, 0]))
        try library.addItem(FakePasteLibrary.inline(try text("完好")))
        let service = try makeService()
        let report = try await PasteImporter(library: library.root, service: service).run(dryRun: false)

        #expect(report.imported == 1)
        #expect(report.unreadable == 1)
        #expect(report.unreadableReasons == ["undecodableCompression": 1])
    }

    @Test func reportNeverContainsClipContent() async throws {
        var library = try FakePasteLibrary()
        let marker = "PRIVATE-MARKER-TEXT"
        try library.addBoard(key: 1, name: "board-\(marker)")
        try library.addItem(FakePasteLibrary.inline(try text(marker)), title: marker, list: 1)
        try library.addItem(Data([1]) + Data(marker.utf8))
        let service = try makeService()
        let report = try await PasteImporter(library: library.root, service: service).run(dryRun: false)

        let encoded = String(data: try JSONEncoder().encode(report), encoding: .utf8) ?? ""
        #expect(!encoded.contains(marker))
    }

    @Test func missingLibraryIsReported() async throws {
        let service = try makeService()
        let importer = PasteImporter(library: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), service: service)
        await #expect(throws: PasteImportError.libraryNotFound) {
            _ = try await importer.run(dryRun: true)
        }
    }

    @Test func sourceDatabaseIsOpenedReadOnly() async throws {
        var library = try FakePasteLibrary()
        try library.addItem(FakePasteLibrary.inline(try text("a")))
        let before = try Data(contentsOf: library.root.appending(path: "db.sqlite"))
        let service = try makeService()
        _ = try await PasteImporter(library: library.root, service: service).run(dryRun: false)
        #expect(try Data(contentsOf: library.root.appending(path: "db.sqlite")) == before)
    }
}
