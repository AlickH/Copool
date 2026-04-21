import Foundation

enum AccountIdentity {
    private static let separator = "|"

    static func normalizedAccountID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedEmail(_ value: String?) -> String? {
        guard let normalized = normalizedIdentifier(value) else { return nil }
        return normalized.contains("@") ? normalized.lowercased() : normalized
    }

    static func normalizedPrincipalID(
        _ principalID: String?,
        email: String?,
        accountID: String
    ) -> String {
        if let normalized = normalizedIdentifier(principalID) {
            return normalized.contains("@") ? normalized.lowercased() : normalized
        }
        if let normalizedEmail = normalizedEmail(email) {
            return normalizedEmail
        }
        return normalizedAccountID(accountID)
    }

    static func key(
        principalID: String?,
        email: String?,
        accountID: String
    ) -> String {
        "\(normalizedPrincipalID(principalID, email: email, accountID: accountID))\(separator)\(normalizedAccountID(accountID))"
    }

    static func key(for account: StoredAccount) -> String {
        key(principalID: account.principalID, email: account.email, accountID: account.accountID)
    }

    static func key(for account: AccountSummary) -> String {
        key(principalID: account.principalID, email: account.email, accountID: account.accountID)
    }

    static func key(for auth: ExtractedAuth) -> String {
        key(principalID: auth.principalID, email: auth.email, accountID: auth.accountID)
    }

    static func normalizedSelectionKey(_ value: String?) -> String? {
        normalizedIdentifier(value)
    }

    static func matches(_ stored: StoredAccount, extracted: ExtractedAuth) -> Bool {
        if key(for: stored) == key(for: extracted) {
            return true
        }

        guard normalizedAccountID(stored.accountID) == normalizedAccountID(extracted.accountID) else {
            return false
        }

        if let storedEmail = normalizedEmail(stored.email),
           let extractedEmail = normalizedEmail(extracted.email),
           storedEmail == extractedEmail {
            return true
        }

        return !hasExplicitPrincipal(principalID: stored.principalID, email: stored.email)
    }

    static func matches(_ lhs: StoredAccount, _ rhs: StoredAccount) -> Bool {
        if key(for: lhs) == key(for: rhs) {
            return true
        }

        guard normalizedAccountID(lhs.accountID) == normalizedAccountID(rhs.accountID) else {
            return false
        }

        if let lhsEmail = normalizedEmail(lhs.email),
           let rhsEmail = normalizedEmail(rhs.email),
           lhsEmail == rhsEmail {
            return true
        }

        return !hasExplicitPrincipal(principalID: lhs.principalID, email: lhs.email)
            || !hasExplicitPrincipal(principalID: rhs.principalID, email: rhs.email)
    }

    static func matches(selection: CurrentAccountSelection, account: StoredAccount) -> Bool {
        selection.cardID == account.id
    }

    static func preferredMatchIndex(
        for extracted: ExtractedAuth,
        in accounts: [StoredAccount]
    ) -> Int? {
        let extractedKey = key(for: extracted)
        if let exactKeyIndex = accounts.firstIndex(where: { key(for: $0) == extractedKey }) {
            return exactKeyIndex
        }

        let normalizedExtractedAccountID = normalizedAccountID(extracted.accountID)
        let normalizedExtractedEmail = normalizedEmail(extracted.email)
        if let normalizedExtractedEmail,
           let emailMatchIndex = accounts.firstIndex(where: {
               normalizedAccountID($0.accountID) == normalizedExtractedAccountID
                   && normalizedEmail($0.email) == normalizedExtractedEmail
           }) {
            return emailMatchIndex
        }

        let wildcardMatches = accounts.indices.filter {
            normalizedAccountID(accounts[$0].accountID) == normalizedExtractedAccountID
                && !hasExplicitPrincipal(
                    principalID: accounts[$0].principalID,
                    email: accounts[$0].email
                )
        }
        guard wildcardMatches.count == 1 else {
            return nil
        }
        return wildcardMatches[0]
    }

    static func hasExplicitPrincipal(principalID: String?, email: String?) -> Bool {
        normalizedIdentifier(principalID) != nil || normalizedEmail(email) != nil
    }

    private static func normalizedIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
