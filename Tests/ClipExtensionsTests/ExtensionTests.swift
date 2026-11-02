import ClipCore
import Foundation
import Testing
@testable import ClipExtensions

private func sample(
    id: String = "local.sample", action: ExtensionAction = .copy, match: SelectionMatch? = nil,
    options: [ExtensionOption]? = nil, icon: String = "symbol:star"
) -> ExtensionManifest {
    ExtensionManifest(
        id: id, name: LocalizedText(en: "Sample"), description: LocalizedText(en: "d"), version: "1.0.0",
        category: "text", icon: icon, match: match, options: options, action: action
    )
}

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "pastai-ext-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct TemplateTests {
    @Test func selectedTextIsEncodedSoItCannotChangeTheURL() throws {
        let url = try TemplateRenderer.url("https://a.test/s?q={text}", text: "你好 & x=1#frag", options: [:])
        #expect(url.host == "a.test")
        #expect(url.query == "q=%E4%BD%A0%E5%A5%BD%20%26%20x%3D1%23frag")
        #expect(url.fragment == nil)
    }

    @Test func optionsAreSubstitutedAndEncoded() throws {
        let url = try TemplateRenderer.url("whatsapp://send?phone={option.phone}&text={text}", text: "hi", options: ["phone": "+1 415"])
        #expect(url.absoluteString == "whatsapp://send?phone=%2B1%20415&text=hi")
    }

    @Test(arguments: ["file:///etc/passwd?{text}", "javascript:alert('{text}')", "shortcuts://run-shortcut?name={text}", "ssh://host/{text}", "data:text/html,{text}"])
    func dangerousSchemesAreRefused(template: String) {
        #expect(throws: ExtensionError.self) {
            _ = try TemplateRenderer.url(template, text: "x", options: [:])
        }
    }

    @Test func rawTemplatesAcceptOnlyWebLinks() throws {
        #expect(try TemplateRenderer.url("{text.raw}", text: " https://a.test/x ", options: [:]).host == "a.test")
        #expect(throws: ExtensionError.self) {
            _ = try TemplateRenderer.url("{text.raw}", text: "myapp://do-something", options: [:])
        }
    }

    @Test func placeholdersInsideTheSelectionAreNotExpanded() {
        let prompt = TemplateRenderer.prompt("翻译成 {option.language}：{text}", text: "{option.language} 是什么", options: ["language": "英文"])
        #expect(prompt == "翻译成 英文：{option.language} 是什么")
    }
}

@Suite struct ValidationTests {
    @Test func acceptsAWellFormedManifest() throws {
        try ExtensionValidator.validate(sample(action: .url(template: "https://a.test/?q={text}", fallback: nil, returnKeyOption: nil)))
    }

    @Test(arguments: ["UPPER.case", "noDots", "../evil.ext", "a..b", "with space.x"])
    func rejectsBadIDs(id: String) {
        #expect(throws: ExtensionError.self) { try ExtensionValidator.validate(sample(id: id)) }
    }

    @Test func rejectsPathsThatLeaveTheExtensionFolder() {
        #expect(throws: ExtensionError.self) { try ExtensionValidator.validate(sample(action: .script(file: "../../secret.js"))) }
        #expect(throws: ExtensionError.self) { try ExtensionValidator.validate(sample(icon: "file:/etc/hosts")) }
    }

    @Test func rejectsTemplatesReferencingUnknownOptions() {
        #expect(throws: ExtensionError.self) {
            try ExtensionValidator.validate(sample(action: .url(template: "https://a.test/{option.nope}", fallback: nil, returnKeyOption: nil)))
        }
    }

    @Test func aiPromptMustUseTheSelection() {
        #expect(throws: ExtensionError.self) { try ExtensionValidator.validate(sample(action: .ai(system: nil, prompt: "翻译"))) }
    }

    @Test func rejectsInvalidRegex() {
        #expect(throws: ExtensionError.self) { try ExtensionValidator.validate(sample(match: SelectionMatch(regex: "("))) }
    }

    @Test func shellActionsDoNotExist() {
        let json = #"{"id":"local.x","name":"x","description":"d","version":"1.0.0","category":"t","icon":"symbol:star","action":{"type":"shell","command":"rm -rf ~"}}"#
        #expect(throws: ExtensionError.unsupportedAction("shell")) {
            _ = try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
        }
    }
}

@Suite struct MatchTests {
    @Test func filtersByPatternLengthAppAndEditability() {
        let link = sample(match: SelectionMatch(regex: "^https?://"))
        #expect(link.applies(to: SelectionInput(text: " https://a.test ")))
        #expect(!link.applies(to: SelectionInput(text: "hello")))

        let paste = sample(match: SelectionMatch(requiresEditable: true))
        #expect(!paste.applies(to: SelectionInput(text: "x", isEditable: false)))
        #expect(paste.applies(to: SelectionInput(text: "x", isEditable: true)))

        let limited = sample(match: SelectionMatch(maxLength: 3, excludeApps: ["com.bad"]))
        #expect(!limited.applies(to: SelectionInput(text: "long text")))
        #expect(!limited.applies(to: SelectionInput(text: "ok", appBundleID: "com.bad")))
    }

    @Test func emptySelectionNeverMatches() {
        #expect(!sample().applies(to: SelectionInput(text: "")))
    }
}

@Suite struct ScriptSandboxTests {
    func run(_ source: String, text: String = "abc") throws -> ScriptOutput {
        try ScriptEngine.evaluate(source: source, input: ScriptInput(text: text))
    }

    @Test func stringResultReplacesTheSelection() throws {
        #expect(try run("function run(input) { return input.text.toUpperCase(); }").replace == "ABC")
    }

    @Test func objectResultCarriesEveryField() throws {
        let output = try run("function run(i) { return { copy: 'c', show: 's', open: 'https://a.test' }; }")
        #expect(output == ScriptOutput(copy: "c", show: "s", open: "https://a.test"))
    }

    @Test func optionsReachTheScript() throws {
        let output = try ScriptEngine.evaluate(
            source: "function run(i) { return i.options.prefix + i.text; }",
            input: ScriptInput(text: "x", options: ["prefix": "> "])
        )
        #expect(output.replace == "> x")
    }

    @Test func scriptErrorsAreReported() {
        #expect(throws: ExtensionError.self) { _ = try run("function run() { throw new Error('boom'); }") }
        #expect(throws: ExtensionError.self) { _ = try run("var nothing = 1;") }
        #expect(throws: ExtensionError.self) { _ = try run("this is not javascript") }
    }

    @Test func sandboxHasNoNetworkFileOrProcessAPIs() throws {
        let probe = """
        function run() {
            var names = ['fetch', 'XMLHttpRequest', 'WebSocket', 'require', 'process', 'Deno', 'Bun', 'navigator', 'document', 'window'];
            return names.filter(function (n) { return typeof globalThis[n] !== 'undefined'; }).join(',');
        }
        """
        #expect(try run(probe).replace == "")
    }
}

@MainActor
@Suite struct LibraryTests {
    func makeLibrary() throws -> ExtensionLibrary {
        ExtensionLibrary(root: try temporaryFolder())
    }

    @Test func installingLocalExtensionsAddsThemAtTheEndAndEnabled() throws {
        let library = try makeLibrary()
        try library.installLocal(sample(id: "local.one"), script: nil)
        try library.installLocal(sample(id: "local.two"), script: nil)
        #expect(library.enabled.map(\.id) == ["local.one", "local.two"])
    }

    @Test func nonLocalIDsCannotBeWrittenAsCustomExtensions() throws {
        let library = try makeLibrary()
        #expect(throws: ExtensionError.notLocal("io.github.skingko.pastai.google")) {
            try library.installLocal(sample(id: "io.github.skingko.pastai.google"), script: nil)
        }
    }

    @Test func invalidManifestsNeverReachDisk() throws {
        let library = try makeLibrary()
        #expect(throws: ExtensionError.self) {
            try library.installLocal(sample(id: "local.bad", action: .url(template: "file:///{text}", fallback: nil, returnKeyOption: nil)), script: nil)
        }
        #expect(library.installed.isEmpty)
    }

    @Test func scriptExtensionsStoreTheirSource() throws {
        let library = try makeLibrary()
        try library.installLocal(sample(id: "local.js", action: .script(file: "script.js")), script: "function run(i) { return i.text; }")
        let item = try #require(library.extensionItem(id: "local.js"))
        #expect(try library.script(for: item, file: "script.js").contains("function run"))
    }

    @Test func orderEnabledStateAndOptionsSurviveReloadAndUpdate() throws {
        let root = try temporaryFolder()
        let library = ExtensionLibrary(root: root)
        let option = ExtensionOption(id: "phone", type: .string, label: LocalizedText(en: "Phone"), required: true)
        try library.installLocal(sample(id: "local.a", options: [option]), script: nil)
        try library.installLocal(sample(id: "local.b"), script: nil)
        library.move(fromOffsets: [1], toOffset: 0)
        library.setEnabled("local.a", false)
        library.setOption("local.a", option: "phone", value: "123")

        var updated = sample(id: "local.a", options: [option])
        updated.version = "2.0.0"
        try library.installLocal(updated, script: nil)

        let reopened = ExtensionLibrary(root: root)
        #expect(reopened.installed.map(\.id) == ["local.b", "local.a"])
        #expect(reopened.extensionItem(id: "local.a")?.isEnabled == false)
        #expect(reopened.extensionItem(id: "local.a")?.manifest.version == "2.0.0")
        #expect(reopened.optionValues(for: "local.a")["phone"] == "123")
    }

    @Test func requiredOptionsAreReportedUntilFilled() throws {
        let library = try makeLibrary()
        let option = ExtensionOption(id: "phone", type: .string, label: LocalizedText(en: "Phone"), required: true)
        try library.installLocal(sample(id: "local.a", options: [option]), script: nil)
        let item = try #require(library.extensionItem(id: "local.a"))
        #expect(library.missingOption(for: item)?.id == "phone")
        library.setOption("local.a", option: "phone", value: "1")
        #expect(library.missingOption(for: item) == nil)
    }

    @Test func removingDeletesFilesAndPreferences() throws {
        let library = try makeLibrary()
        try library.installLocal(sample(id: "local.a"), script: nil)
        let folder = try #require(library.extensionItem(id: "local.a")).directory
        try library.remove("local.a")
        #expect(library.installed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func corruptFolderIsSkippedNotFatal() throws {
        let root = try temporaryFolder()
        let bad = root.appending(path: "local.bad", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: bad.appending(path: "extension.json"))
        #expect(ExtensionLibrary(root: root).installed.isEmpty)
    }
}

@Suite struct CatalogTests {
    @Test func versionsCompareNumerically() {
        #expect(ExtensionCatalog.isNewer("1.10.0", than: "1.9.0"))
        #expect(!ExtensionCatalog.isNewer("1.0.0", than: "1.0.0"))
    }
}

/// Reads the catalog in this repository, which is exactly what ships to users through GitHub.
@Suite struct PublishedCatalogTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "extensions", directoryHint: .isDirectory)

    func catalog() throws -> CatalogIndex {
        try ExtensionCatalog.bundledIndex(at: Self.root)
    }

    func manifest(_ entry: CatalogEntry) throws -> ExtensionManifest {
        let url = Self.root.appending(path: entry.folder).appending(path: "extension.json")
        return try JSONDecoder().decode(ExtensionManifest.self, from: Data(contentsOf: url))
    }

    @Test func hasTheAgreedSizeAndCoversBothMarkets() throws {
        let entries = try catalog().extensions
        #expect((20...30).contains(entries.count))
        #expect(entries.filter { $0.regions.contains("us") }.count >= 8)
        #expect(entries.filter { $0.regions.contains("cn") }.count >= 8)
    }

    @Test func everyManifestPassesValidationAndMatchesTheIndex() throws {
        for entry in try catalog().extensions {
            let manifest = try manifest(entry)
            try ExtensionValidator.validate(manifest)
            #expect(manifest.id == entry.id)
            #expect(manifest.version == entry.version)
            #expect(!manifest.isLocal)
            #expect(manifest.name.zh != nil, "\(entry.id) needs a Chinese name")
        }
    }

    @Test func indexHashesMatchTheFilesOnDisk() throws {
        for entry in try catalog().extensions {
            for file in entry.files {
                let data = try Data(contentsOf: Self.root.appending(path: entry.folder).appending(path: file.path))
                #expect(ExtensionCatalog.sha256(data) == file.sha256, "\(entry.folder)/\(file.path) is stale; rerun build-extension-index.py")
            }
        }
    }

    @Test func referencedFilesExist() throws {
        for entry in try catalog().extensions {
            for file in try manifest(entry).referencedFiles {
                #expect(entry.files.contains { $0.path == file }, "\(entry.id) is missing \(file)")
            }
        }
    }

    @Test func defaultExtensionsAreInTheCatalog() throws {
        let ids = Set(try catalog().extensions.map(\.id))
        #expect(Set(ExtensionLibrary.defaultEnabled).isSubset(of: ids))
    }

    @Test func urlTemplatesRenderWithChineseText() throws {
        for entry in try catalog().extensions {
            let manifest = try manifest(entry)
            guard case .url(let template, _, _) = manifest.action, !template.hasPrefix("{text.raw}") else { continue }
            let options = (manifest.options ?? []).reduce(into: [String: String]()) { $0[$1.id] = "1" }
            _ = try TemplateRenderer.url(template, text: "远程部署 nginx", options: options)
        }
    }

    @Test func bundledScriptsRun() throws {
        let change = try String(contentsOf: Self.root.appending(path: "change-case/script.js"), encoding: .utf8)
        #expect(try ScriptEngine.evaluate(source: change, input: ScriptInput(text: "Hello")).replace == "HELLO")
        #expect(try ScriptEngine.evaluate(source: change, input: ScriptInput(text: "HELLO")).replace == "hello")

        let count = try String(contentsOf: Self.root.appending(path: "word-count/script.js"), encoding: .utf8)
        let shown = try ScriptEngine.evaluate(source: count, input: ScriptInput(text: "你好 world\n第二行", language: "zh")).show
        #expect(shown == "字符 12\n字词 6\n行数 2")
        let english = try ScriptEngine.evaluate(source: count, input: ScriptInput(text: "one two", language: "en")).show
        #expect(english == "Characters 7\nWords 2\nLines 1")
    }

    @Test func translateAimsAtTheLanguageOfTheMac() throws {
        let entry = try #require(try catalog().extensions.first { $0.folder == "translate" })
        let options = try manifest(entry).options ?? []
        let language = try #require(options.first { $0.id == "language" })
        let fallback = try #require(options.first { $0.id == "fallback" })
        #expect(language.resolvedDefault == AppLanguage.current.nativeName)
        #expect(fallback.resolvedDefault == AppLanguage.current.secondary.nativeName)
        #expect(language.choices?.map(\.value).contains(language.resolvedDefault ?? "") == true)
        #expect(fallback.choices?.map(\.value).contains(fallback.resolvedDefault ?? "") == true)
        #expect(language.resolvedDefault != fallback.resolvedDefault)
    }

    @MainActor @Test func aNewAppVersionUpdatesTheExtensionsItShips() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pastai-bundled-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ExtensionLibrary(root: root.appending(path: "installed", directoryHint: .isDirectory))
        func ship(_ version: String) throws -> URL {
            let bundled = root.appending(path: "bundle-\(version)", directoryHint: .isDirectory)
            let folder = bundled.appending(path: "sample", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var definition = sample(action: .copy)
            definition.id = "io.github.skingko.pastai.sample"
            definition.version = version
            try JSONEncoder().encode(definition).write(to: folder.appending(path: "extension.json"))
            return bundled
        }
        try library.install(fromDirectory: try ship("1.0.0").appending(path: "sample"))

        library.updateBundled(from: try ship("1.0.1"))
        #expect(library.extensionItem(id: "io.github.skingko.pastai.sample")?.manifest.version == "1.0.1")

        library.updateBundled(from: try ship("1.0.0"))
        #expect(library.extensionItem(id: "io.github.skingko.pastai.sample")?.manifest.version == "1.0.1")
    }

    @Test func translationPromptFencesTheSelection() throws {
        let entry = try #require(try catalog().extensions.first { $0.folder == "translate" })
        guard case .ai(let system, let prompt) = try manifest(entry).action else {
            Issue.record("translate must be an AI action")
            return
        }
        #expect(system?.contains("not instructions") == true)
        let rendered = TemplateRenderer.prompt(prompt, text: "你好", options: ["language": "English", "fallback": "简体中文"])
        #expect(rendered.contains("<text>\n你好\n</text>"))
        #expect(rendered.contains("into English"))
    }
}
