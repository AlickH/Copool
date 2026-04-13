import Foundation
import SwiftUI

extension AccountsPageModel {
    func switchAccount(id: String) async {
        withAccountsSwitchAnimation {
            switchingAccountID = id
        }
        defer {
            withAccountsSwitchAnimation {
                switchingAccountID = nil
            }
        }

        do {
            let switchResult = try await coordinator.switchAccountAndReload(id: id)
            let accounts = switchResult.accounts
            let selectedAccount = switchResult.selectedAccount
            applyAccountsForAccountSwitch(accounts)
            await refreshPendingWorkspaceAuthorizations(from: accounts, preferredSourceAccountID: selectedAccount.id)
            publishAndSyncLocalAccountsMutation(accounts)
            syncCurrentAccountSelectionInBackground(accountID: selectedAccount.accountID)
            notice = buildSwitchNotice(execution: switchResult.execution)
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func smartSwitch() async {
        do {
            let accountsBefore = try await coordinator.listAccounts()
            let sorted = AccountRanking.sortByRemaining(accountsBefore)
            guard let best = sorted.first else {
                notice = NoticeMessage(style: .info, text: L10n.tr("accounts.notice.no_switch_target"))
                return
            }
            if best.isCurrent {
                notice = NoticeMessage(style: .info, text: L10n.tr("accounts.notice.already_best"))
                return
            }

            let switchResult = try await coordinator.switchAccountAndReload(id: best.id)
            let accounts = switchResult.accounts
            let selectedAccount = switchResult.selectedAccount
            applyAccountsForAccountSwitch(accounts)
            await refreshPendingWorkspaceAuthorizations(from: accounts, preferredSourceAccountID: selectedAccount.id)
            publishAndSyncLocalAccountsMutation(accounts)
            syncCurrentAccountSelectionInBackground(accountID: selectedAccount.accountID)
            var switchNotice = buildSwitchNotice(execution: switchResult.execution)
            switchNotice.text = L10n.tr("accounts.notice.smart_switched_prefix_format", selectedAccount.label, switchNotice.text)
            notice = switchNotice
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func toggleAllAccountsCollapsed() {
        guard case .content(let accounts) = state else { return }
        let ids = Set(accounts.filter { !$0.isWorkspaceDeactivated }.map(\.id))
        guard !ids.isEmpty else {
            collapsedAccountIDs = []
            return
        }
        collapsedAccountIDs = collapsedAccountIDs.isSuperset(of: ids) ? [] : ids
    }

    private func applyAccountsForAccountSwitch(_ accounts: [AccountSummary]) {
        withAccountsSwitchAnimation {
            applyAccounts(accounts)
        }
    }

    private func withAccountsSwitchAnimation(_ updates: () -> Void) {
        withAnimation(AccountsAnimationRules.contentReorder) {
            updates()
        }
    }
}
