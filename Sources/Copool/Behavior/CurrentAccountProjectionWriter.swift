import Foundation

struct CurrentAccountProjectionWriter {
    let storeRepository: AccountsStoreRepository
    let authRepository: AuthRepository
    let dateProvider: DateProviding
    let runtimePlatform: RuntimePlatform

    func apply(account: StoredAccount, writeAuth: Bool = true) throws -> AccountsStore {
        try apply(
            selection: CurrentAccountProjectionWriter.selection(
                for: account,
                selectedAt: dateProvider.unixMillisecondsNow(),
                sourceDeviceID: defaultSourceDeviceID
            ),
            account: account,
            writeAuth: writeAuth
        )
    }

    func apply(
        selection: CurrentAccountSelection,
        account: StoredAccount,
        writeAuth: Bool
    ) throws -> AccountsStore {
        let latestStore = try storeRepository.mutateStore { store in
            guard store.accounts.contains(where: { $0.id == account.id }) else {
                throw AppError.invalidData(L10n.tr("error.accounts.account_not_found_for_switch"))
            }
            store.currentSelection = selection
            store.currentAccountID = account.id
        }
        if writeAuth {
            try authRepository.writeCurrentAuth(account.authJSON)
        }
        return latestStore
    }

    var defaultSourceDeviceID: String {
        runtimePlatform == .macOS ? "macos-local" : "ios-local"
    }

    static func selection(
        for account: StoredAccount,
        selectedAt: Int64,
        sourceDeviceID: String
    ) -> CurrentAccountSelection {
        CurrentAccountSelection(
            cardID: account.id,
            selectedAt: selectedAt,
            sourceDeviceID: sourceDeviceID
        )
    }
}
