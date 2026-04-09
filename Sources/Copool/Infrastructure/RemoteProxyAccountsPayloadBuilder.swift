import Foundation

struct RemoteProxyAccountsPayloadBuilder {
    let sourceAccountStorePath: URL
    let fileManager: FileManager

    func build() throws -> Data {
        var mergedStore = AccountsStore()
        var loadDiagnostics: [String] = []

        for path in candidateAccountStorePaths() {
            guard fileManager.fileExists(atPath: path.path) else {
                continue
            }
            do {
                let store = try decodeAccountsStore(from: path)
                mergeAccounts(from: store.accounts, into: &mergedStore)
                mergeCurrentSelection(from: store.currentSelection, accounts: store.accounts, into: &mergedStore)
                let usable = store.accounts.filter(isProxyUsable(account:)).count
                loadDiagnostics.append("\(path.path): total=\(store.accounts.count), usable=\(usable)")
            } catch {
                loadDiagnostics.append("\(path.path): decode_failed=\(error.localizedDescription)")
            }
        }

        let usableAccounts = mergedStore.accounts.filter(isProxyUsable(account:))
        guard !usableAccounts.isEmpty else {
            let details = loadDiagnostics.isEmpty ? "" : " [\(loadDiagnostics.joined(separator: " | "))]"
            throw AppError.invalidData("\(L10n.tr("error.remote.no_usable_accounts_for_deploy"))\(details)")
        }

        return try encodeRemoteCompatibleStore(mergedStore)
    }

    private func candidateAccountStorePaths() -> [URL] {
        [sourceAccountStorePath]
    }

    private func decodeAccountsStore(from path: URL) throws -> AccountsStore {
        let data = try Data(contentsOf: path)
        do {
            return try JSONDecoder().decode(AccountsStore.self, from: data)
        } catch {
            throw AppError.invalidData("Invalid accounts.json format")
        }
    }

    private func mergeAccounts(from incoming: [StoredAccount], into merged: inout AccountsStore) {
        for account in incoming {
            if let index = merged.accounts.firstIndex(where: {
                AccountIdentity.matches($0, account)
            }) {
                merged.accounts[index] = preferredAccount(existing: merged.accounts[index], incoming: account)
            } else {
                merged.accounts.append(account)
            }
        }
    }

    private func preferredAccount(existing: StoredAccount, incoming: StoredAccount) -> StoredAccount {
        let existingUsable = isProxyUsable(account: existing)
        let incomingUsable = isProxyUsable(account: incoming)
        if incomingUsable != existingUsable {
            return incomingUsable ? incoming : existing
        }
        if incoming.updatedAt != existing.updatedAt {
            return incoming.updatedAt > existing.updatedAt ? incoming : existing
        }
        return existing
    }

    private func mergeCurrentSelection(
        from incoming: CurrentAccountSelection?,
        accounts: [StoredAccount],
        into merged: inout AccountsStore
    ) {
        guard let incoming else { return }
        guard selectionMatchesAnyAccount(incoming, accounts: accounts) else { return }

        guard let existing = merged.currentSelection else {
            merged.currentSelection = incoming
            return
        }

        if incoming.selectedAt >= existing.selectedAt {
            merged.currentSelection = incoming
        }
    }

    private func selectionMatchesAnyAccount(
        _ selection: CurrentAccountSelection,
        accounts: [StoredAccount]
    ) -> Bool {
        accounts.contains { AccountIdentity.matches(selection: selection, account: $0) }
    }

    private func encodeRemoteCompatibleStore(_ store: AccountsStore) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(store)
    }

    private func isProxyUsable(account: StoredAccount) -> Bool {
        guard let tokens = AuthJWTDecoder.tokenObject(from: account.authJSON) else {
            return false
        }
        return tokens["access_token"]?.stringValue != nil && tokens["id_token"]?.stringValue != nil
    }
}
