import Foundation
import Combine

@MainActor
final class InviteToolPageModel: ObservableObject {
    private let coordinator: InviteToolCoordinator
    private let noticeScheduler = NoticeAutoDismissScheduler()

    @Published var selectedOperation: InviteToolOperation = .redeem
    @Published var redeemInput = ""
    @Published var redeemDefaultEmail = ""
    @Published var warrantyInput = ""
    @Published var warrantyDefaultEmail = ""
    @Published var statusInput = ""
    @Published var loading = false
    @Published var resultsState: ViewState<[InviteToolResultRow]> = .empty(message: "输入卡密后即可开始批量处理。")
    @Published var notice: NoticeMessage? {
        didSet {
            noticeScheduler.schedule(notice) { [weak self] in
                self?.notice = nil
            }
        }
    }

    init(coordinator: InviteToolCoordinator) {
        self.coordinator = coordinator
    }

    var currentOperationDescription: String {
        selectedOperation.description
    }

    var currentInputText: String {
        switch selectedOperation {
        case .redeem:
            return redeemInput
        case .warranty:
            return warrantyInput
        case .status:
            return statusInput
        }
    }

    var currentDefaultEmailTitle: String {
        switch selectedOperation {
        case .redeem:
            return "默认兑换邮箱"
        case .warranty:
            return "默认重激活邮箱"
        case .status:
            return ""
        }
    }

    var showsDefaultEmailField: Bool {
        selectedOperation != .status
    }

    var currentDefaultEmail: String {
        switch selectedOperation {
        case .redeem:
            return redeemDefaultEmail
        case .warranty:
            return warrantyDefaultEmail
        case .status:
            return ""
        }
    }

    var currentSummary: InviteToolSummary? {
        guard case let .content(rows) = resultsState else {
            return nil
        }
        return rows.inviteToolSummary
    }

    func setCurrentInput(_ value: String) {
        switch selectedOperation {
        case .redeem:
            redeemInput = value
        case .warranty:
            warrantyInput = value
        case .status:
            statusInput = value
        }
    }

    func setCurrentDefaultEmail(_ value: String) {
        switch selectedOperation {
        case .redeem:
            redeemDefaultEmail = value
        case .warranty:
            warrantyDefaultEmail = value
        case .status:
            break
        }
    }

    func clearCurrentInput() {
        setCurrentInput("")
    }

    func fillSampleInput() {
        switch selectedOperation {
        case .redeem:
            redeemInput = """
            Z-EXAMPLE001,user1@example.com
            Z-EXAMPLE002 user2@example.com
            Z-EXAMPLE003
            """
        case .warranty:
            warrantyInput = """
            Z-EXAMPLE001
            Z-EXAMPLE002,new-mail@example.com
            """
        case .status:
            statusInput = """
            Z-EXAMPLE001
            Z-EXAMPLE002
            """
        }
    }

    func runSelectedOperation() {
        Task {
            await run()
        }
    }

    private func run() async {
        let entries = InviteToolBatchParser.parseLines(currentInputText)
        guard !entries.isEmpty else {
            notice = NoticeMessage(style: .error, text: "请先输入至少一条卡密。")
            resultsState = .empty(message: "输入卡密后即可开始批量处理。")
            return
        }

        loading = true
        resultsState = .loading

        let rows = await coordinator.run(
            operation: selectedOperation,
            entries: entries,
            defaultEmail: showsDefaultEmailField ? currentDefaultEmail : nil
        )

        loading = false
        resultsState = .content(rows)

        let summary = rows.inviteToolSummary
        let style: NoticeStyle = summary.errorCount == 0 ? .success : .info
        notice = NoticeMessage(
            style: style,
            text: "完成 \(summary.total) 条，成功 \(summary.successCount) 条，需处理 \(summary.warningCount) 条，失败 \(summary.errorCount) 条。"
        )
    }
}
