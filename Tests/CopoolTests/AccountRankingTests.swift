import XCTest
@testable import Copool

final class AccountRankingTests: XCTestCase {
    func testPickBestAccountChoosesMostRemainingQuota() {
        let best = makeAccount(id: "a", weekUsed: 15, hourUsed: 30)
        let medium = makeAccount(id: "b", weekUsed: 40, hourUsed: 30)
        let worst = makeAccount(id: "c", weekUsed: 80, hourUsed: 90)

        let picked = AccountRanking.pickBestAccount([worst, medium, best])

        XCTAssertEqual(picked?.id, best.id)
    }

    func testSortForDisplayPinsCurrentAccountFirst() {
        let current = makeAccount(id: "current", weekUsed: 95, hourUsed: 95, isCurrent: true)
        let best = makeAccount(id: "best", weekUsed: 10, hourUsed: 10)
        let medium = makeAccount(id: "medium", weekUsed: 40, hourUsed: 40)

        let sorted = AccountRanking.sortForDisplay([medium, best, current])

        XCTAssertEqual(sorted.map(\.id), ["current", "best", "medium"])
    }

    func testSortForDisplayKeepsBestRemainingOrderForNonCurrentAccounts() {
        let current = makeAccount(id: "current", weekUsed: 20, hourUsed: 20, isCurrent: true)
        let best = makeAccount(id: "best", weekUsed: 10, hourUsed: 10)
        let worst = makeAccount(id: "worst", weekUsed: 90, hourUsed: 90)

        let sorted = AccountRanking.sortForDisplay([worst, current, best])

        XCTAssertEqual(sorted.map(\.id), ["current", "best", "worst"])
    }

    func testAutoSwitchTargetIsNilWhenCurrentAccountNotExhausted() {
        let current = makeAccount(id: "current", weekUsed: 60, hourUsed: 70, isCurrent: true)
        let better = makeAccount(id: "better", weekUsed: 10, hourUsed: 15)

        let target = AccountRanking.pickAutoSwitchTarget([current, better])

        XCTAssertNil(target)
    }

    func testAutoSwitchTargetChoosesBestAlternativeWhenCurrentIsExhausted() {
        let exhaustedCurrent = makeAccount(id: "current", weekUsed: 100, hourUsed: 95, isCurrent: true)
        let bestAlternative = makeAccount(id: "best", weekUsed: 20, hourUsed: 15)
        let otherAlternative = makeAccount(id: "other", weekUsed: 40, hourUsed: 25)

        let target = AccountRanking.pickAutoSwitchTarget([exhaustedCurrent, otherAlternative, bestAlternative])

        XCTAssertEqual(target?.id, bestAlternative.id)
    }

    func testAutoSwitchTargetChoosesBestAlternativeWhenCurrentHasOnePercentRemaining() {
        let nearlyExhaustedCurrent = makeAccount(id: "current", weekUsed: 99, hourUsed: 95, isCurrent: true)
        let bestAlternative = makeAccount(id: "best", weekUsed: 20, hourUsed: 15)
        let otherAlternative = makeAccount(id: "other", weekUsed: 40, hourUsed: 25)

        let target = AccountRanking.pickAutoSwitchTarget([nearlyExhaustedCurrent, otherAlternative, bestAlternative])

        XCTAssertEqual(target?.id, bestAlternative.id)
    }

    func testAutoSwitchTargetIsNilWhenCurrentHasOnePercentRemainingButAlternativesAreWorse() {
        let nearlyExhaustedCurrent = makeAccount(id: "current", weekUsed: 99, hourUsed: 100, isCurrent: true)
        let exhaustedAlternative = makeAccount(id: "exhausted", weekUsed: 100, hourUsed: 100)

        let target = AccountRanking.pickAutoSwitchTarget([nearlyExhaustedCurrent, exhaustedAlternative])

        XCTAssertNil(target)
    }

    func testAutoSwitchTargetIsNilWhenNoCurrentAccount() {
        let accountA = makeAccount(id: "a", weekUsed: 100, hourUsed: 100)
        let accountB = makeAccount(id: "b", weekUsed: 5, hourUsed: 5)

        let target = AccountRanking.pickAutoSwitchTarget([accountA, accountB])

        XCTAssertNil(target)
    }

    func testAutoSwitchTargetIsNilWhenCurrentExhaustedButNoAlternative() {
        let current = makeAccount(id: "current", weekUsed: 100, hourUsed: 100, isCurrent: true)

        let target = AccountRanking.pickAutoSwitchTarget([current])

        XCTAssertNil(target)
    }

    private func makeAccount(id: String, weekUsed: Double, hourUsed: Double, isCurrent: Bool = false) -> AccountSummary {
        AccountSummary(
            id: id,
            label: id,
            email: nil,
            accountID: id,
            planType: nil,
            teamName: nil,
            teamAlias: nil,
            addedAt: 0,
            updatedAt: 0,
            usage: UsageSnapshot(
                fetchedAt: 0,
                planType: nil,
                fiveHour: UsageWindow(usedPercent: hourUsed, windowSeconds: 5 * 60 * 60, resetAt: nil),
                oneWeek: UsageWindow(usedPercent: weekUsed, windowSeconds: 7 * 24 * 60 * 60, resetAt: nil),
                credits: nil
            ),
            usageError: nil,
            isCurrent: isCurrent
        )
    }
}
