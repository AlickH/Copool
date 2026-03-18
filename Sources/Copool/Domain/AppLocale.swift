import Foundation

enum AppLocale: String, CaseIterable, Identifiable, Codable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case spanish = "es"
    case russian = "ru"
    case dutch = "nl"

    var id: String { rawValue }
    var identifier: String { rawValue }

    var displayNameKey: String {
        switch self {
        case .english:
            return "language.english"
        case .simplifiedChinese:
            return "language.simplified_chinese"
        case .traditionalChinese:
            return "language.traditional_chinese"
        case .japanese:
            return "language.japanese"
        case .korean:
            return "language.korean"
        case .french:
            return "language.french"
        case .german:
            return "language.german"
        case .italian:
            return "language.italian"
        case .spanish:
            return "language.spanish"
        case .russian:
            return "language.russian"
        case .dutch:
            return "language.dutch"
        }
    }

    static var systemDefault: AppLocale {
        preferred(from: Locale.preferredLanguages)
    }

    static func preferred(from identifiers: [String]) -> AppLocale {
        for identifier in identifiers {
            let resolved = resolve(identifier)
            if resolved != .english || identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("en") {
                return resolved
            }
        }
        return .english
    }

    static func resolve(_ value: String) -> AppLocale {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalized.hasPrefix("zh-hant") || normalized.hasPrefix("zh-tw") || normalized.hasPrefix("zh-hk") || normalized.hasPrefix("zh-mo") {
            return .traditionalChinese
        }
        if normalized.hasPrefix("zh") { return .simplifiedChinese }
        if normalized.hasPrefix("ja") { return .japanese }
        if normalized.hasPrefix("ko") { return .korean }
        if normalized.hasPrefix("fr") { return .french }
        if normalized.hasPrefix("de") { return .german }
        if normalized.hasPrefix("it") { return .italian }
        if normalized.hasPrefix("es") { return .spanish }
        if normalized.hasPrefix("ru") { return .russian }
        if normalized.hasPrefix("nl") { return .dutch }
        return .english
    }
}
