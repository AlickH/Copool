import Foundation

enum L10n {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var localeOverrideIdentifier: String?
    private nonisolated(unsafe) static var cachedBundle: Bundle = rootBundle

    private static var rootBundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    static func setLocale(identifier: String) {
        let resolved = AppLocale.resolve(identifier).identifier
        lock.lock()
        defer { lock.unlock() }
        guard localeOverrideIdentifier != resolved else {
            return
        }

        localeOverrideIdentifier = resolved
        cachedBundle = localizedBundle(for: resolved) ?? rootBundle
    }

    static func tr(_ key: String) -> String {
        let bundle = currentBundle()
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = tr(key)
        guard !args.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: args)
    }

    private static func currentBundle() -> Bundle {
        lock.lock()
        defer { lock.unlock() }
        return cachedBundle
    }

    private static func localizedBundle(for identifier: String) -> Bundle? {
        guard let path = rootBundle.path(forResource: identifier, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }
}
