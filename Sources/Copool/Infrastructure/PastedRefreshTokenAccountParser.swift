import Foundation

struct PastedRefreshTokenAccountRecord: Equatable {
    let email: String
    let refreshToken: String
}

enum PastedRefreshTokenAccountParser {
    enum ParseError: Error, Equatable, LocalizedError {
        case invalidEmail(line: Int)
        case invalidRefreshToken(line: Int)

        var errorDescription: String? {
            switch self {
            case .invalidEmail(let line):
                return L10n.tr("error.accounts.paste_import_invalid_email_format", line)
            case .invalidRefreshToken(let line):
                return L10n.tr("error.accounts.paste_import_invalid_refresh_token_format", line)
            }
        }
    }

    static func parse(_ input: String) throws -> [PastedRefreshTokenAccountRecord] {
        try input
            .components(separatedBy: .newlines)
            .enumerated()
            .compactMap { offset, rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return nil }

                let segments = line
                    .components(separatedBy: "----")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

                guard let first = segments.first, isValidEmail(first) else {
                    throw ParseError.invalidEmail(line: offset + 1)
                }
                guard let last = segments.last, last.hasPrefix("rt_") else {
                    throw ParseError.invalidRefreshToken(line: offset + 1)
                }

                return PastedRefreshTokenAccountRecord(
                    email: first,
                    refreshToken: last
                )
            }
    }

    private static func isValidEmail(_ value: String) -> Bool {
        guard let atIndex = value.firstIndex(of: "@"),
              atIndex != value.startIndex,
              atIndex != value.index(before: value.endIndex) else {
            return false
        }

        let domain = value[value.index(after: atIndex)...]
        return domain.contains(".")
    }
}
