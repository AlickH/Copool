import Foundation

extension SwiftNativeProxyRuntimeService {
    func makeUpstreamRequest(
        payload: [String: Any],
        candidate: ProxyCandidate,
        downstreamHeaders: [String: String]
    ) throws -> URLRequest {
        let body = try JSONSerialization.data(withJSONObject: payload)
        let upstreamModel = (payload["model"] as? String) ?? "gpt-5.4"
        let version = Self.normalizedForwardHeader(downstreamHeaders["version"]) ?? Self.defaultCodexClientVersion
        let sessionID = Self.normalizedForwardHeader(downstreamHeaders["session_id"])
            ?? Self.normalizedForwardHeader(downstreamHeaders["session-id"])
            ?? UUID().uuidString
        let userAgent = Self.normalizedForwardHeader(downstreamHeaders["user-agent"]) ?? Self.defaultCodexUserAgent
        var request = URLRequest(url: responsesEndpoint(forUpstreamModel: upstreamModel))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.httpBody = body
        request.setValue("Bearer \(candidate.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(candidate.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "Originator")
        request.setValue(version, forHTTPHeaderField: "Version")
        request.setValue(sessionID, forHTTPHeaderField: "Session_id")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Keep-Alive", forHTTPHeaderField: "Connection")
        return request
    }

    func currentCandidates() throws -> [ProxyCandidate] {
        let modificationDate = accountsStoreModificationDate()
        if let cachedCandidates,
           cachedCandidatesStoreModificationDate == modificationDate {
            return applyRuntimeCandidateOrdering(to: cachedCandidates)
        }

        let candidates = try loadCandidates()
        cachedCandidates = candidates
        cachedCandidatesStoreModificationDate = modificationDate
        return applyRuntimeCandidateOrdering(to: candidates)
    }

    func loadCandidates() throws -> [ProxyCandidate] {
        let store = try storeRepository.loadStore()
        let currentAccountID = store.currentAccountID

        let candidates = try store.accounts.compactMap { account -> ProxyCandidate? in
            let extracted = try authRepository.extractAuth(from: account.authJSON)
            return ProxyCandidate(
                id: account.id,
                label: account.label,
                accountID: extracted.accountID,
                accountKey: account.accountKey,
                accessToken: extracted.accessToken,
                authJSON: account.authJSON,
                addedAt: account.addedAt,
                isPreferredCurrent: account.id == currentAccountID,
                oneWeekUsed: account.usage?.oneWeek?.usedPercent,
                fiveHourUsed: account.usage?.fiveHour?.usedPercent
            )
        }

        return candidates.sorted { lhs, rhs in
            if lhs.isPreferredCurrent != rhs.isPreferredCurrent {
                return lhs.isPreferredCurrent
            }
            if lhs.remainingScore != rhs.remainingScore {
                return lhs.remainingScore > rhs.remainingScore
            }
            if lhs.addedAt != rhs.addedAt {
                return lhs.addedAt < rhs.addedAt
            }
            return lhs.id < rhs.id
        }
    }

    func applyRuntimeCandidateOrdering(to candidates: [ProxyCandidate]) -> [ProxyCandidate] {
        let now = currentUnixSeconds()
        cooldownUntilByAccountID = cooldownUntilByAccountID.filter { $0.value > now }

        var available: [ProxyCandidate] = []
        available.reserveCapacity(candidates.count)
        for candidate in candidates {
            if let cooldownUntil = cooldownUntilByAccountID[candidate.accountID],
               cooldownUntil > now {
                continue
            }
            available.append(candidate)
        }

        return available.sorted { lhs, rhs in
            if lhs.isPreferredCurrent != rhs.isPreferredCurrent {
                return lhs.isPreferredCurrent
            }
            let lhsSticky = lhs.accountID == stickyAccountID
            let rhsSticky = rhs.accountID == stickyAccountID
            if lhsSticky != rhsSticky {
                return lhsSticky
            }
            if lhs.remainingScore != rhs.remainingScore {
                return lhs.remainingScore > rhs.remainingScore
            }
            if lhs.addedAt != rhs.addedAt {
                return lhs.addedAt < rhs.addedAt
            }
            return lhs.id < rhs.id
        }
    }

    func accountsStoreModificationDate() -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: paths.accountStorePath.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }

    func isAuthorized(_ headers: [String: String]) -> Bool {
        guard let expected = try? ensurePersistedAPIKey() else { return false }
        if let apiKeyHeader = headers["x-api-key"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !apiKeyHeader.isEmpty,
           apiKeyHeader == expected {
            return true
        }

        guard let authorization = headers["authorization"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !authorization.isEmpty else {
            return false
        }

        let lower = authorization.lowercased()
        if lower.hasPrefix("bearer ") {
            let provided = String(authorization.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return provided == expected
        }

        return authorization == expected
    }

    func ensurePersistedAPIKey() throws -> String {
        if let key = try readPersistedAPIKey(), !key.isEmpty {
            return key
        }

        let generated = randomAPIKey()
        try persistAPIKey(generated)
        return generated
    }

    func readPersistedAPIKey() throws -> String? {
        guard FileManager.default.fileExists(atPath: paths.proxyDaemonKeyPath.path) else {
            return nil
        }

        let text = try String(contentsOf: paths.proxyDaemonKeyPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    func persistAPIKey(_ value: String) throws {
        try FileManager.default.createDirectory(at: paths.proxyDaemonDataDirectory, withIntermediateDirectories: true)
        try value.write(to: paths.proxyDaemonKeyPath, atomically: true, encoding: .utf8)
        #if canImport(Darwin)
        _ = chmod(paths.proxyDaemonKeyPath.path, S_IRUSR | S_IWUSR)
        #endif
    }

    func randomAPIKey() -> String {
        "sk-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    }

    func sendUpstream(
        payload: [String: Any],
        candidate: ProxyCandidate,
        downstreamHeaders: [String: String]
    ) async throws -> UpstreamResponse {
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.invalid_upstream_payload"))
        }

        return try await performUpstreamRequest(
            payload: payload,
            candidate: candidate,
            downstreamHeaders: downstreamHeaders
        )
    }

    func performUpstreamRequest(
        payload: [String: Any],
        candidate: ProxyCandidate,
        downstreamHeaders: [String: String]
    ) async throws -> UpstreamResponse {
        let request = try makeUpstreamRequest(
            payload: payload,
            candidate: candidate,
            downstreamHeaders: downstreamHeaders
        )
        let (responseBytes, response) = try await URLSession.shared.bytes(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500
        var responseBody = Data()
        responseBody.reserveCapacity(64 * 1024)

        for try await byte in responseBytes {
            responseBody.append(byte)
            if responseBody.count > ProxyRuntimeLimits.maxUpstreamResponseBytes {
                throw AppError.network(
                    L10n.tr(
                        "error.proxy_runtime.upstream_response_too_large_format",
                        ProxyRuntimeLimits.limitDescription(for: ProxyRuntimeLimits.maxUpstreamResponseBytes)
                    )
                )
            }
        }

        return UpstreamResponse(statusCode: statusCode, body: responseBody)
    }

    func openStreamingUpstreamRequest(
        payload: [String: Any],
        candidate: ProxyCandidate,
        downstreamHeaders: [String: String]
    ) async throws -> UpstreamStreamingResponse {
        let request = try makeUpstreamRequest(
            payload: payload,
            candidate: candidate,
            downstreamHeaders: downstreamHeaders
        )
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500
        return UpstreamStreamingResponse(statusCode: statusCode, bytes: bytes, candidate: candidate)
    }

    static func shouldSyncCurrentAuthOnSuccessfulProxyResponse(localProxyHostAPIOnly: Bool) -> Bool {
        !localProxyHostAPIOnly
    }

    static func normalizedForwardHeader(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func shouldSyncCurrentAuthOnSuccessfulProxyResponse() -> Bool {
        let localProxyHostAPIOnly = (try? settingsRepository.loadSettings().localProxyHostAPIOnly)
            ?? AppSettings.defaultValue.localProxyHostAPIOnly
        return Self.shouldSyncCurrentAuthOnSuccessfulProxyResponse(
            localProxyHostAPIOnly: localProxyHostAPIOnly
        )
    }

    static func normalizeConfiguredBaseURL(_ configuredBaseURL: String) -> String {
        var trimmed = configuredBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if trimmed.hasSuffix("/backend-api/codex/responses") {
            trimmed = String(trimmed.dropLast("/responses".count))
        } else if trimmed.hasSuffix("/backend-api/responses") {
            trimmed = String(trimmed.dropLast("/responses".count))
        }

        return trimmed
    }

    func readChatGPTBaseURLFromConfig() -> String? {
        guard let raw = try? String(contentsOf: paths.codexConfigPath, encoding: .utf8), !raw.isEmpty else {
            return nil
        }

        for line in raw.split(whereSeparator: { $0.isNewline }) {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("chatgpt_base_url") else { continue }
            guard let equalIndex = trimmed.firstIndex(of: "=") else { continue }
            let value = trimmed[trimmed.index(after: equalIndex)...]
                .trimmingCharacters(in: CharacterSet.whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty {
                return value
            }
        }

        return nil
    }

    func waitForHealth(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        let deadline = Date().addingTimeInterval(6)

        while Date() < deadline {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    return true
                }
            } catch {
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        return false
    }
}

struct UpstreamResponse {
    var statusCode: Int
    var body: Data
}

struct UpstreamStreamingResponse {
    var statusCode: Int
    var bytes: URLSession.AsyncBytes
    var candidate: ProxyCandidate
}

struct ProxyCandidate {
    var id: String
    var label: String
    var accountID: String
    var accountKey: String
    var accessToken: String
    var authJSON: JSONValue
    var addedAt: Int64
    var isPreferredCurrent: Bool
    var oneWeekUsed: Double?
    var fiveHourUsed: Double?

    var remainingScore: Double {
        let weekUsed = oneWeekUsed ?? 100
        let fiveUsed = fiveHourUsed ?? 100
        let weekRemaining = max(0, 100 - weekUsed)
        let fiveRemaining = max(0, 100 - fiveUsed)
        return weekRemaining * 0.7 + fiveRemaining * 0.3
    }
}
