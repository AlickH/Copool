import Foundation

enum AuthFlowDebugLog {
    private static let lock = NSLock()

    static func write(_ category: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }

        let fileManager = FileManager.default
        guard let appSupportBase = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return
        }

        let directory = appSupportBase.appendingPathComponent("CodexToolsSwift", isDirectory: true)
        let fileURL = directory.appendingPathComponent("auth-flow-debug.log", isDirectory: false)

        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) [\(category)] \(message)\n"
        NSLog("%@", line.trimmingCharacters(in: .newlines))

        if !fileManager.fileExists(atPath: fileURL.path) {
            try? line.data(using: .utf8)?.write(to: fileURL, options: .atomic)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            return
        }

        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {}
    }
}

enum AccountSwitchDebugLog {
    private static let isEnabled = false

    static func write(_ event: String, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        AuthFlowDebugLog.write("AccountSwitch.\(event)", message())
    }

    static func describe(store: AccountsStore, currentAuthAccountKey: String?) -> String {
        let resolvedCurrentCardID = store
            .accountSummaries()
            .first(where: \.isCurrent)?
            .id
        return "store[currentCard=\(render(store.currentAccountID)) selection=\(describe(selection: store.currentSelection)) authKey=\(render(currentAuthAccountKey)) resolvedCurrentCard=\(render(resolvedCurrentCardID))]"
    }

    static func describe(selection: CurrentAccountSelection?) -> String {
        guard let selection else { return "nil" }
        return "cardID=\(render(selection.cardID)) selectedAt=\(selection.selectedAt) source=\(render(selection.sourceDeviceID))"
    }

    static func describe(account: StoredAccount) -> String {
        "card[id=\(render(account.id)) label=\(renderLabel(account.label)) accountID=\(render(account.accountID)) accountKey=\(render(account.accountKey))]"
    }

    static func describe(account: AccountSummary) -> String {
        "card[id=\(render(account.id)) label=\(renderLabel(account.label)) accountID=\(render(account.accountID)) current=\(account.isCurrent)]"
    }

    static func describe(accounts: [AccountSummary]) -> String {
        let currentCardIDs = accounts.filter(\.isCurrent).map(\.id)
        let items = accounts.map { account in
            "\(render(account.id)):\(account.isCurrent ? "current" : "idle"):\(render(account.accountID))"
        }.joined(separator: ",")
        return "accounts[count=\(accounts.count) current=\(renderJoined(currentCardIDs)) items=[\(items)]]"
    }

    static func describeAutoSwitch(accounts: [AccountSummary]) -> String {
        let current = accounts.first(where: \.isCurrent)
        let currentExhausted = current.map(AccountRanking.isQuotaExhausted) ?? false
        let ranked = AccountRanking.sortByRemaining(accounts).map(describeAutoSwitchCandidate).joined(separator: ",")
        return "autoSwitch[current=\(current.map(describeAutoSwitchCandidate) ?? "nil") currentExhausted=\(currentExhausted) ranked=[\(ranked)]]"
    }

    private static func renderJoined(_ values: [String]) -> String {
        guard !values.isEmpty else { return "nil" }
        return values.map(render).joined(separator: "|")
    }

    private static func describeAutoSwitchCandidate(_ account: AccountSummary) -> String {
        let score = String(format: "%.2f", AccountRanking.remainingScore(for: account))
        let fiveHourUsed = renderPercent(account.usage?.fiveHour?.usedPercent)
        let oneWeekUsed = renderPercent(account.usage?.oneWeek?.usedPercent)
        return "\(render(account.id)){current=\(account.isCurrent),score=\(score),fiveHourUsed=\(fiveHourUsed),oneWeekUsed=\(oneWeekUsed)}"
    }

    private static func renderLabel(_ value: String?) -> String {
        guard let value else { return "nil" }
        let trimmed = value.replacingOccurrences(of: "\n", with: " ")
        return trimmed.isEmpty ? "empty" : trimmed
    }

    private static func render(_ value: String?) -> String {
        guard let value else { return "nil" }
        guard !value.isEmpty else { return "empty" }
        guard value.count <= 24 else {
            return "\(value.prefix(10))...\(value.suffix(8))"
        }
        return value
    }

    private static func renderPercent(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.2f", value)
    }
}

enum UsageDebugLog {
    static func write(_ event: String, _ message: String) {
        AuthFlowDebugLog.write("Usage.\(event)", message)
    }
}
