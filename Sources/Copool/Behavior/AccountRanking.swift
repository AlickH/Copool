import Foundation

enum AccountRanking {
    private static let autoSwitchUsedThreshold = 100.0

    static func remainingScore(for account: AccountSummary) -> Double {
        let oneWeekUsed = account.usage?.oneWeek?.usedPercent ?? 100
        let fiveHourUsed = account.usage?.fiveHour?.usedPercent ?? 100

        let oneWeekRemaining = max(0, 100 - oneWeekUsed)
        let fiveHourRemaining = max(0, 100 - fiveHourUsed)

        return oneWeekRemaining * 0.7 + fiveHourRemaining * 0.3
    }

    static func sortByRemaining(_ accounts: [AccountSummary]) -> [AccountSummary] {
        accounts.sorted { left, right in
            remainingScore(for: left) > remainingScore(for: right)
        }
    }

    static func sortForDisplay(_ accounts: [AccountSummary]) -> [AccountSummary] {
        accounts.sorted { left, right in
            if left.isCurrent != right.isCurrent {
                return left.isCurrent
            }

            let leftScore = remainingScore(for: left)
            let rightScore = remainingScore(for: right)
            if leftScore != rightScore {
                return leftScore > rightScore
            }

            return left.addedAt < right.addedAt
        }
    }

    static func pickBestAccount(_ accounts: [AccountSummary]) -> AccountSummary? {
        sortByRemaining(accounts).first
    }

    static func isQuotaExhausted(_ account: AccountSummary) -> Bool {
        isWindowExhausted(account.usage?.fiveHour) || isWindowExhausted(account.usage?.oneWeek)
    }

    static func pickAutoSwitchTarget(_ accounts: [AccountSummary]) -> AccountSummary? {
        guard let current = accounts.first(where: \.isCurrent), isQuotaExhausted(current) else {
            return nil
        }

        let alternatives = accounts.filter { $0.id != current.id }
        guard let bestAlternative = pickBestAccount(alternatives),
              remainingScore(for: bestAlternative) > remainingScore(for: current) else {
            return nil
        }
        return bestAlternative
    }

    private static func isWindowExhausted(_ window: UsageWindow?) -> Bool {
        guard let window else { return false }
        return window.usedPercent >= autoSwitchUsedThreshold
    }
}
