import SwiftUI
import UniformTypeIdentifiers

struct AccountsPageView: View {
    @State private var areCardsPresented = false
    @State private var didRunInitialCardEntrance = false
    @State private var isImportingAuthFile = false
    @State private var isPresentingPasteImport = false
    @State private var pastedImportText = ""

    @ObservedObject var model: AccountsPageModel
    let currentLocale: AppLocale
    let onSelectLocale: (AppLocale) -> Void

    init(
        model: AccountsPageModel,
        currentLocale: AppLocale,
        onSelectLocale: @escaping (AppLocale) -> Void
    ) {
        self.model = model
        self.currentLocale = currentLocale
        self.onSelectLocale = onSelectLocale
        let hasResolvedInitialState = model.hasResolvedInitialState
        _areCardsPresented = State(initialValue: hasResolvedInitialState)
        _didRunInitialCardEntrance = State(initialValue: hasResolvedInitialState)
    }

    var body: some View {
        ZStack {
            AccountsPageShell(
                model: model,
                currentLocale: currentLocale,
                onSelectLocale: onSelectLocale,
                areCardsPresented: areCardsPresented,
                onTriggerAction: triggerAction,
                onToggleCollapse: toggleCollapse,
                onSwitchAccount: switchAccount,
                onRefreshAccountUsage: refreshUsage,
                onReauthenticateAccount: reauthenticateAccount,
                onAuthorizeWorkspace: authorizeWorkspace,
                onCancelAuthorizeWorkspace: cancelAuthorizeWorkspace,
                onDeletePendingWorkspace: deletePendingWorkspace,
                onDeleteAccount: deleteAccount
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            #if os(macOS)
            if isPresentingPasteImport {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()

                AccountsPasteImportSheet(
                    text: $pastedImportText,
                    isSubmitting: model.isAdding,
                    onCancel: dismissPasteImport,
                    onSubmit: submitPastedImport
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
                .zIndex(1)
            }
            #endif
        }
        .fileImporter(
            isPresented: $isImportingAuthFile,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleImportAuthFile(result)
        }
        #if os(iOS)
        .sheet(isPresented: $isPresentingPasteImport) {
            AccountsPasteImportSheet(
                text: $pastedImportText,
                isSubmitting: model.isAdding,
                onCancel: dismissPasteImport,
                onSubmit: submitPastedImport
            )
        }
        #endif
        .onAppear {
            triggerInitialCardEntranceIfNeeded(for: contentAccountCount)
        }
        .onChange(of: contentAccountCount) { _, newValue in
            triggerInitialCardEntranceIfNeeded(for: newValue)
        }
    }

    private var contentAccountCount: Int? {
        guard case .content(let cards) = model.makeContentPresentation().state else { return nil }
        return cards.count
    }

    private func triggerInitialCardEntranceIfNeeded(for count: Int?) {
        guard count != nil, !didRunInitialCardEntrance else { return }
        didRunInitialCardEntrance = true
        areCardsPresented = true
    }

    private func triggerAction(_ intent: AccountsPageActionIntent) {
        if intent == .pasteImport {
            isPresentingPasteImport = true
            return
        }
        #if os(iOS)
        if intent == .importAuthFile {
            isImportingAuthFile = true
            return
        }
        #endif
        Task { await model.handlePageAction(intent) }
    }

    private func handleImportAuthFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await model.importAuthDocument(from: url, setAsCurrent: false) }
        case .failure(let error):
            model.notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    private func submitPastedImport() {
        let text = pastedImportText
        dismissPasteImport()
        Task { await model.importPastedAccounts(text) }
    }

    private func dismissPasteImport() {
        pastedImportText = ""
        isPresentingPasteImport = false
    }

    private func toggleCollapse() {
        withAnimation(AccountsAnimationRules.collapseToggle) {
            model.toggleAllAccountsCollapsed()
        }
    }

    private func switchAccount(id: String) {
        Task { await model.switchAccount(id: id) }
    }

    private func refreshUsage(forAccountID id: String) {
        Task { await model.refreshUsage(forAccountID: id) }
    }

    private func reauthenticateAccount(id: String) {
        Task { await model.reauthenticateAccount(id: id) }
    }

    private func deleteAccount(id: String) {
        Task { await model.deleteAccount(id: id) }
    }

    private func authorizeWorkspace(id: String) {
        Task { await model.authorizePendingWorkspace(id: id) }
    }

    private func cancelAuthorizeWorkspace() {
        model.cancelPendingWorkspaceAuthorization()
    }

    private func deletePendingWorkspace(id: String) {
        Task { await model.deletePendingWorkspace(id: id) }
    }
}
