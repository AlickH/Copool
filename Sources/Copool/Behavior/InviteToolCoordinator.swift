import Foundation

struct InviteToolCoordinator: Sendable {
    private let service: InviteToolServiceProtocol
    private let requestDelay: Duration

    init(
        service: InviteToolServiceProtocol,
        requestDelay: Duration = .milliseconds(250)
    ) {
        self.service = service
        self.requestDelay = requestDelay
    }

    func run(
        operation: InviteToolOperation,
        entries: [InviteToolInputLine],
        defaultEmail: String?
    ) async -> [InviteToolResultRow] {
        var rows: [InviteToolResultRow] = []

        for (index, entry) in entries.enumerated() {
            if index > 0 {
                try? await Task.sleep(for: requestDelay)
            }

            switch operation {
            case .redeem:
                rows.append(await redeem(entry: entry, defaultEmail: defaultEmail))
            case .warranty:
                rows.append(await warranty(entry: entry, defaultEmail: defaultEmail))
            case .status:
                rows.append(await status(entry: entry))
            }
        }

        return rows
    }

    private func redeem(entry: InviteToolInputLine, defaultEmail: String?) async -> InviteToolResultRow {
        guard let targetEmail = resolvedEmail(entry: entry, defaultEmail: defaultEmail) else {
            return InviteToolResultRow(
                lineNumber: entry.lineNumber,
                code: entry.code,
                tone: .error,
                step: .validateInput,
                message: "兑换需要邮箱。请在该行补充邮箱，或填写默认邮箱。",
                requestEmail: entry.email,
                finalEmail: nil,
                payload: nil
            )
        }

        do {
            let payload = try await service.redeem(code: entry.code, email: targetEmail)
            return InviteToolResultRow(
                lineNumber: entry.lineNumber,
                code: entry.code,
                tone: tone(for: payload),
                step: .redeem,
                message: payload.message ?? "兑换完成。",
                requestEmail: entry.email,
                finalEmail: targetEmail,
                payload: payload
            )
        } catch {
            return InviteToolResultRow(
                lineNumber: entry.lineNumber,
                code: entry.code,
                tone: .error,
                step: .redeem,
                message: error.localizedDescription,
                requestEmail: entry.email,
                finalEmail: targetEmail,
                payload: nil
            )
        }
    }

    private func warranty(entry: InviteToolInputLine, defaultEmail: String?) async -> InviteToolResultRow {
        do {
            let payload = try await service.checkWarranty(code: entry.code)

            if payload.reason == "reactivation_required",
               let lastUsedEmail = payload.lastUsedEmail,
               !lastUsedEmail.isEmpty {
                let targetEmail = resolvedEmail(entry: entry, defaultEmail: defaultEmail) ?? lastUsedEmail
                let redeemPayload = try await service.redeemWarranty(
                    code: entry.code,
                    email: targetEmail,
                    lastUsedEmail: lastUsedEmail
                )

                return InviteToolResultRow(
                    lineNumber: entry.lineNumber,
                    code: entry.code,
                    tone: tone(for: redeemPayload),
                    step: .warrantyRedeem,
                    message: redeemPayload.message ?? "已完成重新激活。",
                    requestEmail: entry.email,
                    finalEmail: targetEmail,
                    payload: redeemPayload
                )
            }

            return InviteToolResultRow(
                lineNumber: entry.lineNumber,
                code: entry.code,
                tone: tone(for: payload),
                step: .warrantyCheck,
                message: payload.message ?? "质保检查完成。",
                requestEmail: entry.email,
                finalEmail: nil,
                payload: payload
            )
        } catch {
            return InviteToolResultRow(
                lineNumber: entry.lineNumber,
                code: entry.code,
                tone: .error,
                step: .warrantyCheck,
                message: error.localizedDescription,
                requestEmail: entry.email,
                finalEmail: nil,
                payload: nil
            )
        }
    }

    private func status(entry: InviteToolInputLine) async -> InviteToolResultRow {
        do {
            let payload = try await service.queryStatus(code: entry.code)
            return InviteToolResultRow(
                lineNumber: entry.lineNumber,
                code: entry.code,
                tone: tone(for: payload),
                step: .status,
                message: payload.statusLabel.map { "当前状态：\($0)" } ?? (payload.message ?? "查询完成。"),
                requestEmail: entry.email,
                finalEmail: nil,
                payload: payload
            )
        } catch {
            return InviteToolResultRow(
                lineNumber: entry.lineNumber,
                code: entry.code,
                tone: .error,
                step: .status,
                message: error.localizedDescription,
                requestEmail: entry.email,
                finalEmail: nil,
                payload: nil
            )
        }
    }

    private func resolvedEmail(entry: InviteToolInputLine, defaultEmail: String?) -> String? {
        if let email = sanitizedEmail(entry.email) {
            return email
        }
        return sanitizedEmail(defaultEmail)
    }

    private func sanitizedEmail(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func tone(for payload: InviteToolResponsePayload) -> InviteToolResultTone {
        let marker = payload.level ?? payload.statusLevel ?? ""
        switch marker {
        case "success":
            return .success
        case "warning":
            return .warning
        default:
            if payload.reason == "reactivation_required" {
                return .warning
            }
            return marker == "error" ? .error : .warning
        }
    }
}
