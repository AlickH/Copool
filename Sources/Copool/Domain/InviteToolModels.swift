import Foundation

enum InviteToolOperation: String, CaseIterable, Identifiable {
    case redeem
    case warranty
    case status

    var id: String { rawValue }

    var title: String {
        switch self {
        case .redeem:
            return "批量兑换"
        case .warranty:
            return "质保激活"
        case .status:
            return "激活查询"
        }
    }

    var description: String {
        switch self {
        case .redeem:
            return "每行支持“卡密,邮箱”或“卡密 邮箱”。如果某行未提供邮箱，将使用默认邮箱。"
        case .warranty:
            return "每行支持“卡密,新邮箱”。如检测到需要重激活，会优先使用行内邮箱，其次默认邮箱，最后回退到原邮箱。"
        case .status:
            return "每行输入一条卡密即可，支持空行和以 # 开头的注释行。"
        }
    }

    var runButtonTitle: String {
        switch self {
        case .redeem:
            return "开始批量兑换"
        case .warranty:
            return "开始质保激活"
        case .status:
            return "开始批量查询"
        }
    }
}

struct InviteToolInputLine: Identifiable, Equatable {
    let lineNumber: Int
    let code: String
    let email: String?

    var id: String {
        "\(lineNumber)-\(code)"
    }
}

enum InviteToolResultTone: Equatable {
    case success
    case warning
    case error

    var title: String {
        switch self {
        case .success:
            return "成功"
        case .warning:
            return "需处理"
        case .error:
            return "失败"
        }
    }
}

enum InviteToolResultStep: Equatable {
    case validateInput
    case redeem
    case warrantyCheck
    case warrantyRedeem
    case status
}

struct InviteToolResponsePayload: Decodable, Equatable {
    var code: String?
    var email: String?
    var invitedAt: String?
    var codeTypeDisplay: String?
    var warrantyDuration: Int?
    var firstUsedAt: String?
    var warrantyExpiresAt: String?
    var isWarranty: Bool?
    var message: String?
    var level: String?
    var reason: String?
    var status: String?
    var statusLabel: String?
    var statusLevel: String?
    var lastUsedEmail: String?
    var usedByEmail: String?
    var usedAt: String?

    enum CodingKeys: String, CodingKey {
        case code
        case email
        case invitedAt = "invited_at"
        case codeTypeDisplay = "code_type_display"
        case warrantyDuration = "warranty_duration"
        case firstUsedAt = "first_used_at"
        case warrantyExpiresAt = "warranty_expires_at"
        case isWarranty = "is_warranty"
        case message
        case level
        case reason
        case status
        case statusLabel = "status_label"
        case statusLevel = "status_level"
        case lastUsedEmail = "last_used_email"
        case usedByEmail = "used_by_email"
        case usedAt = "used_at"
    }
}

struct InviteToolResultRow: Identifiable, Equatable {
    let lineNumber: Int
    let code: String
    let tone: InviteToolResultTone
    let step: InviteToolResultStep
    let message: String
    let requestEmail: String?
    let finalEmail: String?
    let payload: InviteToolResponsePayload?

    var id: String {
        "\(lineNumber)-\(code)-\(step)"
    }

    var detailItems: [(String, String)] {
        var items: [(String, String)] = []

        if let requestEmail, !requestEmail.isEmpty {
            items.append(("提交邮箱", requestEmail))
        }
        if let finalEmail, !finalEmail.isEmpty, finalEmail != requestEmail {
            items.append(("最终邮箱", finalEmail))
        }
        if let payload {
            if let email = payload.email, !email.isEmpty, email != finalEmail {
                items.append(("接口邮箱", email))
            }
            if let lastUsedEmail = payload.lastUsedEmail, !lastUsedEmail.isEmpty {
                items.append(("原邮箱", lastUsedEmail))
            }
            if let usedByEmail = payload.usedByEmail, !usedByEmail.isEmpty {
                items.append(("使用邮箱", usedByEmail))
            }
            if let invitedAt = payload.invitedAt, !invitedAt.isEmpty {
                items.append(("邀请时间", invitedAt))
            }
            if let usedAt = payload.usedAt, !usedAt.isEmpty {
                items.append(("使用时间", usedAt))
            }
            if let firstUsedAt = payload.firstUsedAt, !firstUsedAt.isEmpty {
                items.append(("首次使用", firstUsedAt))
            }
            if let warrantyExpiresAt = payload.warrantyExpiresAt, !warrantyExpiresAt.isEmpty {
                items.append(("质保截止", warrantyExpiresAt))
            }
        }

        return items
    }
}

struct InviteToolSummary: Equatable {
    var total: Int
    var successCount: Int
    var warningCount: Int
    var errorCount: Int
}

enum InviteToolBatchParser {
    static func parseLines(_ rawInput: String) -> [InviteToolInputLine] {
        rawInput
            .components(separatedBy: .newlines)
            .enumerated()
            .compactMap { index, rawLine in
                let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                    return nil
                }

                let parts = split(trimmed)
                guard let code = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !code.isEmpty else {
                    return nil
                }

                let email = parts.count > 1
                    ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil

                return InviteToolInputLine(
                    lineNumber: index + 1,
                    code: code,
                    email: email?.isEmpty == false ? email : nil
                )
            }
    }

    private static func split(_ line: String) -> [String] {
        if let comma = line.firstIndex(of: ",") {
            return [
                String(line[..<comma]),
                String(line[line.index(after: comma)...]),
            ]
        }

        if let tab = line.firstIndex(of: "\t") {
            return [
                String(line[..<tab]),
                String(line[line.index(after: tab)...]),
            ]
        }

        let whitespaceParts = line
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        if whitespaceParts.count >= 2 {
            return [whitespaceParts[0], whitespaceParts[1]]
        }
        return [line]
    }
}

extension Array where Element == InviteToolResultRow {
    var inviteToolSummary: InviteToolSummary {
        InviteToolSummary(
            total: count,
            successCount: filter { $0.tone == .success }.count,
            warningCount: filter { $0.tone == .warning }.count,
            errorCount: filter { $0.tone == .error }.count
        )
    }
}
