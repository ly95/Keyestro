import Foundation
import KeyestroDomain

enum L10n {
    private static let bundle: Bundle = {
        if let resources = Bundle.main.resourceURL,
            let packaged = Bundle(
                url: resources.appendingPathComponent("Keyestro_KeyestroApp.bundle", isDirectory: true)
            )
        {
            return packaged
        }
        return .module
    }()

    static func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }

    static func errorMessage(_ error: ErrorDescriptor) -> String {
        if error.code == "calculator.invalidToken",
            let position = error.message.split(whereSeparator: { !$0.isNumber }).compactMap({ Int64($0) }).first
        {
            return format("Invalid token at position %lld.", position)
        }
        if error.code.hasPrefix("scripts.exit."),
            let value = error.code.split(separator: ".").last,
            let code = Int64(value)
        {
            return format("scripts.exit.format", code)
        }
        if error.code.hasPrefix("scripts.signal."),
            let value = error.code.split(separator: ".").last,
            let signal = Int64(value)
        {
            return format("scripts.signal.format", signal)
        }
        if error.code == "clipboard.keyMissing",
            let count = error.message.split(whereSeparator: { !$0.isNumber }).compactMap({ Int64($0) }).first
        {
            return format("clipboard.keyMissing.format", count)
        }
        return text(error.message)
    }

    static func recoverySuggestion(_ error: ErrorDescriptor) -> String? {
        if error.code.hasPrefix("database.newerSchema."),
            let suggestion = error.recoverySuggestion
        {
            let versions = suggestion.split(whereSeparator: { !$0.isNumber }).compactMap { Int64($0) }
            if versions.count >= 2 {
                return format("database.newerSchema.recovery", versions[0], versions[1])
            }
        }
        return error.recoverySuggestion.map(text)
    }
}
