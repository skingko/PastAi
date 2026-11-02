import AppKit
import ClipCore
import ClipEnrich
import ClipImport
import Foundation

// Developer tool, not shipped in the app.
//   PastAiBench demo <library-dir> [--lang en|zh]            a small realistic library for looking at the UI
//   PastAiBench perf <library-dir> <count>    synthetic rows plus timings for the performance targets
//   PastAiBench paste-import <library-dir> [--dry-run]    imports Paste's data, printing counts only

private func renderImage(_ text: String, background: NSColor, size: NSSize = NSSize(width: 960, height: 600)) -> Data {
    let image = NSImage(size: size)
    image.lockFocus()
    background.setFill()
    NSRect(origin: .zero, size: size).fill()
    (text as NSString).draw(
        at: NSPoint(x: 60, y: size.height / 2 - 40),
        withAttributes: [.font: NSFont.systemFont(ofSize: 72, weight: .semibold), .foregroundColor: NSColor.white]
    )
    image.unlockFocus()
    return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
}

private func ingest(_ service: ClipService, text: String, app: (String, String), at date: Date) async throws -> Int64 {
    let snapshot = PasteboardSnapshot(items: [[PasteboardEntry(uti: PasteboardTypes.plainText, data: Data(text.utf8))]])
    let draft = ClipBuilder.build(snapshot, source: SourceInfo(bundleID: app.0, name: app.1))!
    return try await service.ingest(draft, now: date).clipID
}

private func ingest(_ service: ClipService, entries: [PasteboardEntry], app: (String, String), at date: Date) async throws -> Int64 {
    let draft = ClipBuilder.build(PasteboardSnapshot(items: [entries]), source: SourceInfo(bundleID: app.0, name: app.1))!
    return try await service.ingest(draft, now: date).clipID
}

private let safari = ("com.apple.Safari", "Safari")
private let code = ("com.microsoft.VSCode", "Visual Studio Code")

private func seedDemo(_ root: URL, chinese: Bool) async throws {
    func text(_ zh: String, _ en: String) -> String { chinese ? zh : en }
    let finder = ("com.apple.finder", text("访达", "Finder"))
    let notes = ("com.apple.Notes", text("备忘录", "Notes"))
    let wechat = ("com.tencent.xinWeChat", text("微信", "WeChat"))
    let paths = try AppPaths(root: root)
    let service = try ClipService(paths: paths)
    let now = Date()
    func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    let test = try await service.createPinboard(name: text("稍后阅读", "Read Later"), colorHex: "#FF8A1F")
    let prompts = try await service.createPinboard(name: text("常用提示词", "Prompts"), colorHex: "#C026D3")
    let deploy = try await service.createPinboard(name: text("远程部署", "Deployment"), colorHex: "#FF8A1F")
    let passwords = try await service.createPinboard(name: text("账号备忘", "Accounts"), colorHex: "#22C55E")
    if var board = try await service.pinboards().first(where: { $0.id == passwords }) {
        board.aiHidden = true
        try await service.updatePinboard(board)
    }

    let files = root.appending(path: "demo-files", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    let report = files.appending(path: text("季度复盘.pdf", "Quarterly Review.pdf"))
    let pdf = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 400, height: 500)
    let context = CGContext(consumer: CGDataConsumer(data: pdf)!, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    context.setFillColor(NSColor.systemBlue.cgColor)
    context.fill(CGRect(x: 40, y: 300, width: 320, height: 160))
    context.endPDFPage()
    context.closePDF()
    try (pdf as Data).write(to: report)

    let enrichment = EnrichmentPipeline(service: service)
    var ids: [Int64] = []
    ids.append(try await ingest(service, text: text("把下面的内容整理成结构清晰的 Markdown，保留所有数字和专有名词，语气保持专业。", "Rewrite the notes below as clean Markdown. Keep every number and proper noun, and stay professional."), app: notes, at: ago(1)))
    ids.append(try await ingest(service, text: "https://pasteapp.io/help/paste-on-mac", app: safari, at: ago(4)))
    ids.append(try await ingest(service, entries: [PasteboardEntry(uti: PasteboardTypes.png, data: renderImage(text("产品原型 v2", "Prototype v2"), background: .systemIndigo))], app: safari, at: ago(9)))
    ids.append(try await ingest(service, text: """
    server {
        listen 80;
        server_name deploy.example.com;
        location / {
            proxy_pass http://127.0.0.1:3000;
            proxy_set_header Host $host;
        }
    }
    """, app: code, at: ago(16)))
    ids.append(try await ingest(service, text: "#FF8A1F", app: code, at: ago(25)))
    ids.append(try await ingest(service, entries: [PasteboardEntry(uti: PasteboardTypes.fileURL, data: Data(report.absoluteString.utf8))], app: finder, at: ago(48)))
    ids.append(try await ingest(service, text: text("明天下午三点和设计团队评审剪贴板面板，重点看卡片密度和搜索交互。", "Design review tomorrow at 3 PM: clipboard panel, focusing on card density and search."), app: wechat, at: ago(120)))
    ids.append(try await ingest(service, entries: [PasteboardEntry(uti: PasteboardTypes.png, data: renderImage(text("架构草图", "Architecture"), background: .systemTeal))], app: wechat, at: ago(200)))
    ids.append(try await ingest(service, text: text("import Foundation\n\nfunc greet(name: String) -> String {\n    return \"你好，\\(name)\"\n}\n", "import Foundation\n\nfunc greet(name: String) -> String {\n    return \"Hello, \\(name)\"\n}\n"), app: code, at: ago(400)))
    ids.append(try await ingest(service, text: "ssh -p 2222 deploy@10.0.0.8 'cd /srv/app && docker compose up -d'", app: code, at: ago(1500)))
    let promptClip = try await ingest(service, text: text("你是一名资深编辑，请用不超过 100 字总结下文的核心观点。", "You are a senior editor. Summarize the main argument below in under 100 words."), app: notes, at: ago(2000))
    let scriptClip = try await ingest(service, text: "curl -fsSL https://example.com/install.sh | sh", app: safari, at: ago(2200))
    let secretClip = try await ingest(service, text: text("数据库账号 admin / 备用口令请到密码管理器查看", "Database user is admin. The backup password is in the password manager."), app: notes, at: ago(2600))
    ids += [promptClip, scriptClip, secretClip]

    try await service.apply(
        [
            .addToPinboard(clipID: promptClip, pinboardID: prompts),
            .addToPinboard(clipID: ids[0], pinboardID: prompts),
            .addToPinboard(clipID: scriptClip, pinboardID: deploy),
            .addToPinboard(clipID: ids[3], pinboardID: deploy),
            .addToPinboard(clipID: secretClip, pinboardID: passwords),
            .addToPinboard(clipID: ids[1], pinboardID: test),
        ],
        source: .user, summary: "演示数据"
    )
    for id in ids { await enrichment.enqueue(id) }
    await enrichment.drain()
    print("demo library ready: \(root.path) (\(ids.count) clips)")
}

private func measure(_ label: String, runs: Int = 7, _ body: () async throws -> Int) async rethrows {
    var samples: [Double] = []
    var rows = 0
    for _ in 0..<runs {
        let start = ContinuousClock.now
        rows = try await body()
        let elapsed = ContinuousClock.now - start
        samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
    }
    samples.sort()
    print(String(format: "%-34@ median %7.2f ms  worst %7.2f ms  rows %d", label as NSString, samples[samples.count / 2], samples.last!, rows))
}

private func seedPerf(_ root: URL, count: Int) async throws {
    let service = try ClipService(paths: AppPaths(root: root))
    let existing = try await service.count(ClipQuery())
    if existing < count {
        let words = ["远程部署", "配置", "脚本", "会议纪要", "产品原型", "数据库", "性能优化", "nginx", "docker", "kubernetes", "swift", "设计评审", "接口文档", "周报", "提示词", "账单"]
        let base = Date().addingTimeInterval(-86_400 * 80)
        let start = ContinuousClock.now
        var generator = SystemRandomNumberGenerator()
        for index in existing..<count {
            var parts: [String] = []
            for _ in 0..<Int.random(in: 8...40, using: &generator) { parts.append(words.randomElement(using: &generator)!) }
            let text = "第 \(index) 条 " + parts.joined(separator: " ")
            _ = try await ingest(service, text: text, app: safari, at: base.addingTimeInterval(Double(index)))
            if index % 10_000 == 0, index > 0 { print("  seeded \(index)") }
        }
        print("ingest: \(ContinuousClock.now - start) for \(count - existing) rows")
    }

    print("rows: \(try await service.count(ClipQuery()))")
    try await measure("first page (open panel)") { try await service.list(ClipQuery(limit: 60)).count }
    try await measure("deep page offset 40000") { try await service.list(ClipQuery(limit: 60, offset: 40_000)).count }
    try await measure("search 两字中文 部署") { try await service.list(ClipQuery(text: "部署", limit: 60)).count }
    try await measure("search 长词 会议纪要") { try await service.list(ClipQuery(text: "会议纪要", limit: 60)).count }
    try await measure("search english prefix kube") { try await service.list(ClipQuery(text: "kube", limit: 60)).count }
    try await measure("search mixed nginx 配置") { try await service.list(ClipQuery(text: "nginx 配置", limit: 60)).count }
    try await measure("search no hit (LIKE fallback)") { try await service.list(ClipQuery(text: "zzzqqq", limit: 60)).count }
    try await measure("filter by kind") { try await service.list(ClipQuery(kinds: [.text], limit: 60)).count }
    try await measure("agent scope first page") { try await service.list(ClipQuery(limit: 60), scope: .agent).count }
    try await measure("stats") { try await service.stats().total }
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: PastAiBench demo <dir> | perf <dir> <count>")
    exit(2)
}
let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
switch arguments[1] {
case "demo":
    try await seedDemo(root, chinese: arguments.contains("zh"))
case "perf":
    try await seedPerf(root, count: Int(arguments[3]) ?? 50_000)
case "paste-import":
    guard let source = PasteImporter.locateLibrary() else {
        print("no Paste library found")
        exit(1)
    }
    let service = try ClipService(paths: AppPaths(root: root))
    let dryRun = arguments.contains("--dry-run")
    let report = try await PasteImporter(library: source, service: service, ignoredApps: Set(AppSettings.defaultIgnoredApps))
        .run(dryRun: dryRun) { done, total in
            if done % 250 == 0 { print("  \(done) / \(total)") }
        }
    // The report holds counts only, so printing it cannot reveal clipboard content.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(data: try encoder.encode(report), encoding: .utf8) ?? "")
default:
    print("unknown command \(arguments[1])")
    exit(2)
}
