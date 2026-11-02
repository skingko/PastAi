import Foundation

/// A string to translate, written as ordinary Swift interpolation: `L("删除 \(count) 项")`.
/// Interpolated values become `%@` in the lookup key, so `L10n.english` holds `"删除 %@ 项"`.
public struct LocalizedKey: ExpressibleByStringInterpolation, Sendable {
    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []

        public init(literalCapacity: Int, interpolationCount: Int) {}

        public mutating func appendLiteral(_ literal: String) {
            key += literal
        }

        public mutating func appendInterpolation<T>(_ value: T) {
            key += "%@"
            arguments.append(String(describing: value))
        }
    }

    let key: String
    let arguments: [String]

    public init(stringLiteral value: String) {
        key = value
        arguments = []
    }

    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }
}

public enum AppLanguage: Sendable {
    case chinese
    case english

    /// Follows the first language in System Settings, and English for anything but Chinese.
    /// macOS relaunches an app to change its language, so reading it once is enough.
    public static let current: AppLanguage = (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? .chinese : .english

    /// How the language is written in its own script, for handing to a model or a script.
    public var nativeName: String {
        switch self {
        case .chinese: "简体中文"
        case .english: "English"
        }
    }

    /// The other language, for text that is already in this one.
    public var secondary: AppLanguage { self == .chinese ? .english : .chinese }

    public var code: String {
        switch self {
        case .chinese: "zh"
        case .english: "en"
        }
    }
}

/// Strings are written in Chinese in the source, and that text is the key. The translations live in
/// `L10n.english`, a Swift table rather than `.lproj` resources so every target can use it, including
/// tests and tools, without any bundle lookup.
public func L(_ key: LocalizedKey) -> String {
    L10n.resolve(key, language: AppLanguage.current)
}

public enum L10n {
    static func resolve(_ key: LocalizedKey, language: AppLanguage) -> String {
        var template = key.key
        if language == .english, let translation = english[key.key] { template = translation }
        return fill(template, arguments: key.arguments)
    }

    /// `%@` fills in order and `%1$@` by position, for sentences that reorder in translation.
    /// `{s}` becomes a plural "s" unless the first argument is 1.
    /// One pass over the template, so a value that happens to contain `%@` or `{s}` stays as written.
    static func fill(_ template: String, arguments: [String]) -> String {
        var output = ""
        var rest = template[...]
        var next = 0
        while let first = rest.first {
            if rest.hasPrefix("%@") {
                if next < arguments.count { output += arguments[next] }
                next += 1
                rest = rest.dropFirst(2)
            } else if rest.hasPrefix("{s}") {
                if arguments.first != "1" { output += "s" }
                rest = rest.dropFirst(3)
            } else if first == "%", let position = rest.dropFirst().first?.wholeNumberValue, rest.dropFirst(2).hasPrefix("$@") {
                if arguments.indices.contains(position - 1) { output += arguments[position - 1] }
                rest = rest.dropFirst(4)
            } else {
                output.append(first)
                rest = rest.dropFirst()
            }
        }
        return output
    }
}
