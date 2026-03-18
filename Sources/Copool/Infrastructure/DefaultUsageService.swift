import Foundation

final class DefaultUsageService: UsageService, @unchecked Sendable {
    private let session: URLSession
    private let configPath: URL
    private let dateProvider: DateProviding

    init(session: URLSession = .shared, configPath: URL, dateProvider: DateProviding = SystemDateProvider()) {
        self.session = session
        self.configPath = configPath
        self.dateProvider = dateProvider
    }

    func fetchUsage(accessToken: String, accountID: String) async throws -> UsageSnapshot {
        let urls = resolveUsageURLs()
        var errors: [String] = []

        for url in urls {
            guard let endpoint = URL(string: url) else { continue }
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 18
            request.httpMethod = "GET"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("codex-tools-swift/0.1", forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    errors.append("\(url) -> \(L10n.tr("error.usage.invalid_response"))")
                    continue
                }

                guard (200..<300).contains(httpResponse.statusCode) else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    let snippet = String(body.prefix(140))
                    errors.append("\(url) -> \(httpResponse.statusCode): \(snippet)")
                    continue
                }

                let decoder = JSONDecoder()
                let payload = try decoder.decode(UsageAPIResponse.self, from: data)
                return mapPayload(payload)
            } catch {
                errors.append("\(url) -> \(error.localizedDescription)")
            }
        }

        let preview = errors.prefix(2).joined(separator: " | ")
        if errors.count > 2 {
            throw AppError.network(L10n.tr("error.usage.request_failed_with_more_format", preview, String(errors.count - 2)))
        }
        throw AppError.network(L10n.tr("error.usage.request_failed_format", preview))
    }

    private func resolveUsageURLs() -> [String] {
        let baseOrigin = resolveChatGPTBaseOrigin()
        let backendPrefix = "/backend-api"
        let whamPath = "/wham/usage"
        let codexPath = "/api/codex/usage"

        var candidates: [String] = []
        if let originWithoutBackend = baseOrigin.removingSuffix(backendPrefix) {
            candidates.append("\(baseOrigin)\(whamPath)")
            candidates.append("\(originWithoutBackend)\(backendPrefix)\(whamPath)")
            candidates.append("\(originWithoutBackend)\(codexPath)")
        } else {
            candidates.append("\(baseOrigin)\(backendPrefix)\(whamPath)")
            candidates.append("\(baseOrigin)\(whamPath)")
            candidates.append("\(baseOrigin)\(codexPath)")
        }

        candidates.append("https://chatgpt.com/backend-api/wham/usage")
        candidates.append("https://chatgpt.com/api/codex/usage")

        var deduped: [String] = []
        for candidate in candidates where !deduped.contains(candidate) {
            deduped.append(candidate)
        }
        return deduped
    }

    private func resolveChatGPTBaseOrigin() -> String {
        guard let raw = try? String(contentsOf: configPath, encoding: .utf8), !raw.isEmpty else {
            return "https://chatgpt.com"
        }

        for line in raw.split(whereSeparator: { $0.isNewline }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("chatgpt_base_url") else { continue }
            guard let equalIndex = trimmed.firstIndex(of: "=") else { continue }
            let value = trimmed[trimmed.index(after: equalIndex)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty {
                return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
        }

        return "https://chatgpt.com"
    }

    private func mapPayload(_ payload: UsageAPIResponse) -> UsageSnapshot {
        var windows: [UsageWindowRaw] = []

        if let rateLimit = payload.rateLimit {
            if let primary = rateLimit.primaryWindow { windows.append(primary) }
            if let secondary = rateLimit.secondaryWindow { windows.append(secondary) }
        }

        if let additional = payload.additionalRateLimits {
            for item in additional {
                if let primary = item.rateLimit?.primaryWindow { windows.append(primary) }
                if let secondary = item.rateLimit?.secondaryWindow { windows.append(secondary) }
            }
        }

        let fiveHourRaw = UsageWindowSelector.pickNearestWindow(windows, targetSeconds: 5 * 60 * 60)
        let oneWeekRaw = UsageWindowSelector.pickNearestWindow(windows, targetSeconds: 7 * 24 * 60 * 60)

        return UsageSnapshot(
            fetchedAt: dateProvider.unixSecondsNow(),
            planType: payload.planType,
            fiveHour: fiveHourRaw.map(Self.toUsageWindow),
            oneWeek: oneWeekRaw.map(Self.toUsageWindow),
            credits: payload.credits.map {
                CreditSnapshot(hasCredits: $0.hasCredits, unlimited: $0.unlimited, balance: $0.balance)
            }
        )
    }

    private static func toUsageWindow(_ raw: UsageWindowRaw) -> UsageWindow {
        UsageWindow(
            usedPercent: raw.usedPercent,
            windowSeconds: raw.limitWindowSeconds,
            resetAt: raw.resetAt
        )
    }
}

private struct UsageAPIResponse: Decodable {
    var planType: String?
    var rateLimit: RateLimitDetails?
    var additionalRateLimits: [AdditionalRateLimitDetails]?
    var credits: CreditDetails?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case credits
    }
}

private struct RateLimitDetails: Decodable {
    var primaryWindow: UsageWindowRaw?
    var secondaryWindow: UsageWindowRaw?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct AdditionalRateLimitDetails: Decodable {
    var rateLimit: RateLimitDetails?

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }
}

struct UsageWindowRaw: Equatable {
    var usedPercent: Double
    var limitWindowSeconds: Int64
    var resetAt: Int64
}

extension UsageWindowRaw: Decodable {
    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }
}

private struct CreditDetails: Decodable {
    var hasCredits: Bool
    var unlimited: Bool
    var balance: String?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }
}

private extension String {
    func removingSuffix(_ suffix: String) -> String? {
        guard hasSuffix(suffix) else { return nil }
        return String(dropLast(suffix.count))
    }
}
