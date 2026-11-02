import Foundation
import JavaScriptCore

public struct ScriptInput: Codable, Sendable, Hashable {
    public var text: String
    public var options: [String: String]

    public init(text: String, options: [String: String] = [:]) {
        self.text = text
        self.options = options
    }
}

/// What a script asks for. All fields are optional and can be combined.
public struct ScriptOutput: Codable, Sendable, Hashable {
    /// Replaces the selected text.
    public var replace: String?
    /// Puts text on the clipboard.
    public var copy: String?
    /// Shows text in the result popover.
    public var show: String?
    /// Opens a URL, subject to the same scheme rules as URL actions.
    public var open: String?

    public init(replace: String? = nil, copy: String? = nil, show: String? = nil, open: String? = nil) {
        self.replace = replace
        self.copy = copy
        self.show = show
        self.open = open
    }
}

/// Runs extension JavaScript in a bare `JSContext`. JavaScriptCore on its own has no network, file or
/// process APIs, so a script can only compute on its input and hand back a `ScriptOutput`.
public enum ScriptEngine {
    public static func evaluate(source: String, input: ScriptInput) throws -> ScriptOutput {
        guard let context = JSContext() else { throw ExtensionError.scriptFailed("无法创建脚本环境") }
        var failure: String?
        context.exceptionHandler = { _, exception in
            failure = exception?.toString()
        }
        _ = context.evaluateScript("var console = { log: function () {}, warn: function () {}, error: function () {} };")
        _ = context.evaluateScript(source)
        if let failure { throw ExtensionError.scriptFailed(failure) }

        guard let run = context.objectForKeyedSubscript("run"), run.isObject, !run.isUndefined else {
            throw ExtensionError.scriptFailed("脚本必须定义 run(input) 函数")
        }
        let argument: [String: Any] = ["text": input.text, "options": input.options]
        guard let result = run.call(withArguments: [argument]) else {
            throw ExtensionError.scriptFailed("run 没有返回结果")
        }
        if let failure { throw ExtensionError.scriptFailed(failure) }
        return output(from: result)
    }

    private static func output(from value: JSValue) -> ScriptOutput {
        // A bare string is the common case for a transform, so it means "replace the selection".
        if value.isString { return ScriptOutput(replace: value.toString()) }
        guard value.isObject else { return ScriptOutput() }
        func field(_ name: String) -> String? {
            guard let item = value.objectForKeyedSubscript(name), !item.isUndefined, !item.isNull else { return nil }
            return item.toString()
        }
        return ScriptOutput(replace: field("replace"), copy: field("copy"), show: field("show"), open: field("open"))
    }
}

/// Entry point for the helper process. The app re-launches itself with `flag` to run one script, because
/// JavaScriptCore has no public way to interrupt a running script and an infinite loop must stay killable.
public enum ScriptHost {
    public static let flag = "--run-extension-script"

    private struct Request: Codable {
        var source: String
        var input: ScriptInput
    }

    private struct Response: Codable {
        var output: ScriptOutput?
        var error: String?
    }

    public static func main() -> Never {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        var response = Response(output: nil, error: nil)
        do {
            let request = try JSONDecoder().decode(Request.self, from: data)
            response.output = try ScriptEngine.evaluate(source: request.source, input: request.input)
        } catch {
            response.error = error.localizedDescription
        }
        if let encoded = try? JSONEncoder().encode(response) {
            FileHandle.standardOutput.write(encoded)
        }
        exit(0)
    }

    static func encodeRequest(source: String, input: ScriptInput) throws -> Data {
        try JSONEncoder().encode(Request(source: source, input: input))
    }

    static func decodeResponse(_ data: Data) throws -> ScriptOutput {
        let response = try JSONDecoder().decode(Response.self, from: data)
        if let error = response.error { throw ExtensionError.scriptFailed(error) }
        return response.output ?? ScriptOutput()
    }
}

public struct SandboxedScriptRunner: Sendable {
    let executable: URL
    let timeout: Duration

    public init(executable: URL, timeout: Duration = .seconds(3)) {
        self.executable = executable
        self.timeout = timeout
    }

    public func run(source: String, input: ScriptInput) async throws -> ScriptOutput {
        let request = try ScriptHost.encodeRequest(source: source, input: input)
        let process = Process()
        process.executableURL = executable
        process.arguments = [ScriptHost.flag]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let finished = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in continuation.finish() }
        }
        try process.run()
        stdin.fileHandleForWriting.write(request)
        try stdin.fileHandleForWriting.close()

        let watchdog = Task {
            try await Task.sleep(for: timeout)
            process.terminate()
        }
        let output = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
        for await _ in finished {}
        watchdog.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ExtensionError.scriptTimedOut
        }
        return try ScriptHost.decodeResponse(await output.value)
    }
}
