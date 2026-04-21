import Foundation
import OSLog

enum BackgroundNetworkSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()
}

final class DefaultUsageService: UsageService, @unchecked Sendable {
    private enum RequestPolicy {
        static let timeout: TimeInterval = 18
        static let scope = "usage"
    }

    private static let logger = Logger(subsystem: "Copool", category: "Usage")

    private let session: URLSession
    private let configPath: URL
    private let dateProvider: DateProviding
    private let endpointCoordinator: EndpointRequestCoordinator

    init(
        session: URLSession = BackgroundNetworkSession.shared,
        configPath: URL,
        dateProvider: DateProviding = SystemDateProvider(),
        endpointPreferenceStore: EndpointPreferenceStore = .shared
    ) {
        self.session = session
        self.configPath = configPath
        self.dateProvider = dateProvider
        self.endpointCoordinator = EndpointRequestCoordinator(
            session: session,
            preferenceStore: endpointPreferenceStore
        )
    }

    func fetchUsage(accessToken: String, accountID: String) async throws -> UsageSnapshot {
        let candidateURLs = resolveUsageURLs()
        let startedAt = Date()
        UsageDebugLog.write(
            "request.begin",
            "accountID=\(accountID) candidates=\(candidateURLs.joined(separator: " | "))"
        )
        // Self.logger.debug(
        //     "Usage request started for account \(accountID, privacy: .public). Candidates: \(candidateURLs.joined(separator: " | "), privacy: .public)"
        // )
        do {
            let resolved: ResolvedUsagePayload = try await endpointCoordinator.fetchFirstSuccessful(
                scope: RequestPolicy.scope,
                candidateURLs: candidateURLs
            ) { endpoint in
                var request = URLRequest(url: endpoint)
                request.timeoutInterval = RequestPolicy.timeout
                request.httpMethod = "GET"
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("codex-tools-swift/0.1", forHTTPHeaderField: "User-Agent")
                // Self.logger.debug(
                //     "Usage request: \(Self.requestLogSummary(for: request), privacy: .public)"
                // )
                return request
            } validate: { result in
                // Self.logger.debug(
                //     "Usage raw response from \(result.endpoint, privacy: .public) [status \(result.response.statusCode)] for account \(accountID, privacy: .public): \(Self.responseLogBody(for: result.data), privacy: .public)"
                // )
                UsageDebugLog.write(
                    "response.raw",
                    "accountID=\(accountID) endpoint=\(result.endpoint) status=\(result.response.statusCode) body=\(Self.responseLogBody(for: result.data))"
                )
                return ResolvedUsagePayload(
                    endpoint: result.endpoint,
                    payload: try JSONDecoder().decode(UsageAPIResponse.self, from: result.data)
                )
            }
            // Self.logger.debug(
            //     "Usage request succeeded via \(resolved.endpoint, privacy: .public) in \(elapsedMilliseconds) ms for account \(accountID, privacy: .public)"
            // )
            let snapshot = mapPayload(resolved.payload)
            let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
            UsageDebugLog.write(
                "request.success",
                "accountID=\(accountID) endpoint=\(resolved.endpoint) elapsedMs=\(elapsedMilliseconds) usage=\(Self.describeUsage(snapshot))"
            )
            return snapshot
        } catch EndpointRequestError.allRequestsFailed(let errors) {
            let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
            Self.logger.error(
                "Usage request failed after \(elapsedMilliseconds) ms for account \(accountID, privacy: .public). Candidates: \(candidateURLs.joined(separator: " | "), privacy: .public). Errors: \(errors.joined(separator: " | "), privacy: .public)"
            )
            UsageDebugLog.write(
                "request.failure",
                "accountID=\(accountID) elapsedMs=\(elapsedMilliseconds) candidates=\(candidateURLs.joined(separator: " | ")) errors=\(errors.joined(separator: " | "))"
            )
            if let message = Self.preferredUserFacingFailureMessage(from: errors) {
                throw AppError.network(message)
            }
            let preview = errors.prefix(2).joined(separator: " | ")
            if errors.count > 2 {
                throw AppError.network(L10n.tr("error.usage.request_failed_with_more_format", preview, String(errors.count - 2)))
            }
            throw AppError.network(L10n.tr("error.usage.request_failed_format", preview))
        }
    }

    private static func preferredUserFacingFailureMessage(from errors: [String]) -> String? {
        for error in errors {
            let detail = error.components(separatedBy: ": ").dropFirst().joined(separator: ": ")
            guard let detail = detail.nonEmptyTrimmed, !detail.hasPrefix("<") else {
                continue
            }
            return detail
        }
        return nil
    }

    private static func requestLogSummary(for request: URLRequest) -> String {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? ""
        let headers = (request.allHTTPHeaderFields ?? [:])
            .filter { $0.key.caseInsensitiveCompare("Authorization") != .orderedSame }
        let payload: [String: Any] = [
            "method": method,
            "url": url,
            "headers": headers
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "\(method) \(url)"
        }
        return text
    }

    private static func responseLogBody(for data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "<non-utf8 body: \(data.count) bytes>"
    }

    private func resolveUsageURLs() -> [String] {
        let baseOrigin = ChatGPTBaseOriginResolver.resolve(configPath: configPath)
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

    private static func describeUsage(_ usage: UsageSnapshot) -> String {
        "fetchedAt=\(usage.fetchedAt) fiveHourUsed=\(describePercent(usage.fiveHour?.usedPercent)) fiveHourReset=\(usage.fiveHour?.resetAt.map(String.init) ?? "nil") oneWeekUsed=\(describePercent(usage.oneWeek?.usedPercent)) oneWeekReset=\(usage.oneWeek?.resetAt.map(String.init) ?? "nil")"
    }

    private static func describePercent(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.2f", value)
    }
}

private struct ResolvedUsagePayload: Sendable {
    let endpoint: String
    let payload: UsageAPIResponse
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

    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#if DEBUG
extension DefaultUsageService {
    static func debugRequestLogSummary(for request: URLRequest) -> String {
        requestLogSummary(for: request)
    }

    static func debugResponseLogBody(for data: Data) -> String {
        responseLogBody(for: data)
    }
}
#endif
