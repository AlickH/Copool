import Foundation

actor SwiftNativeProxyRuntimeService: ProxyRuntimeService {
    enum UpstreamRouteFamily: Equatable {
        case codex
        case general
    }

    static let defaultCodexClientVersion = "0.101.0"
    static let defaultCodexUserAgent = "codex_cli_rs/0.101.0 (Mac OS 26.0.1; arm64) Apple_Terminal/464"

    let paths: FileSystemPaths
    let storeRepository: AccountsStoreRepository
    let settingsRepository: SettingsRepository
    let authRepository: AuthRepository
    let onAccountsStoreChanged: (@Sendable () -> Void)?
    let switchAccount: (@Sendable (String) async throws -> Void)?
    let dateProvider: DateProviding

    private var server: SimpleHTTPServer?
    private var runningPort: Int?
    private var activeAccountID: String?
    private var activeAccountLabel: String?
    private var lastError: String?
    var cachedCandidates: [ProxyCandidate]?
    var cachedCandidatesStoreModificationDate: Date?
    var stickyAccountID: String?
    var cooldownUntilByAccountID: [String: Int64] = [:]

    private let models = SwiftNativeProxyRuntimeService.clientVisibleModels

    init(
        paths: FileSystemPaths,
        storeRepository: AccountsStoreRepository,
        settingsRepository: SettingsRepository,
        authRepository: AuthRepository,
        onAccountsStoreChanged: (@Sendable () -> Void)? = nil,
        switchAccount: (@Sendable (String) async throws -> Void)? = nil,
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.paths = paths
        self.storeRepository = storeRepository
        self.settingsRepository = settingsRepository
        self.authRepository = authRepository
        self.onAccountsStoreChanged = onAccountsStoreChanged
        self.switchAccount = switchAccount
        self.dateProvider = dateProvider
    }

    func status() async -> ApiProxyStatus {
        let running = server != nil
        let apiKey = try? ensurePersistedAPIKey()
        let availableAccounts = (try? currentCandidates().count) ?? -1

        return ApiProxyStatus(
            running: running,
            port: running ? runningPort : nil,
            apiKey: apiKey,
            baseURL: runningPort.map { "http://127.0.0.1:\($0)/v1" },
            availableAccounts: availableAccounts,
            activeAccountID: activeAccountID,
            activeAccountLabel: activeAccountLabel,
            lastError: lastError
        )
    }

    func start(preferredPort: Int?) async throws -> ApiProxyStatus {
        if server != nil {
            return await status()
        }

        let desiredPort = preferredPort ?? 8787
        guard desiredPort > 0 && desiredPort < 65536 else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.invalid_port_format", String(desiredPort)))
        }

        _ = try ensurePersistedAPIKey()

        let boundServer: SimpleHTTPServer
        do {
            boundServer = try SimpleHTTPServer(port: UInt16(desiredPort)) { [weak self] request in
                guard let self else {
                    return HTTPResponse.json(statusCode: 500, object: ["error": ["message": "Proxy runtime unavailable"]])
                }
                return await self.handle(request: request)
            }
            try await boundServer.start()
        } catch {
            lastError = L10n.tr("error.proxy_runtime.start_swift_proxy_failed_format", error.localizedDescription)
            throw AppError.io(lastError ?? L10n.tr("error.proxy_runtime.start_failed"))
        }

        server = boundServer
        runningPort = desiredPort
        lastError = nil

        let healthy = await waitForHealth(port: desiredPort)
        if !healthy {
            _ = await stop()
            lastError = L10n.tr("error.proxy_runtime.health_check_failed")
            throw AppError.io(lastError ?? L10n.tr("error.proxy_runtime.start_failed"))
        }

        return await status()
    }

    func stop() async -> ApiProxyStatus {
        server?.stop()
        server = nil
        runningPort = nil
        activeAccountID = nil
        activeAccountLabel = nil
        stickyAccountID = nil
        cooldownUntilByAccountID = [:]
        return await status()
    }

    func refreshAPIKey() async throws -> ApiProxyStatus {
        let key = randomAPIKey()
        try persistAPIKey(key)
        return await status()
    }

    func syncAccountsStore() async throws {
        // Swift native runtime reads the same app store source directly.
    }

    private func handle(request: HTTPRequest) async -> HTTPResponse {
        if request.path == "/health" && request.method == "GET" {
            return HTTPResponse.json(statusCode: 200, object: ["ok": true])
        }

        guard isAuthorized(request.headers) else {
            return jsonError(statusCode: 401, message: "Invalid proxy api key.")
        }

        if request.path == "/v1/models" && request.method == "GET" {
            let list = models.map { model in
                [
                    "id": model,
                    "object": "model",
                    "created": 0,
                    "owned_by": "openai"
                ] as [String: Any]
            }
            return HTTPResponse.json(statusCode: 200, object: ["object": "list", "data": list])
        }

        if request.path == "/v1/responses" && request.method == "POST" {
            return await handleResponsesRequest(body: request.body, downstreamHeaders: request.headers)
        }

        if request.path == "/v1/chat/completions" && request.method == "POST" {
            return await handleChatCompletionsRequest(body: request.body, downstreamHeaders: request.headers)
        }

        return jsonError(
            statusCode: 404,
            message: L10n.tr("error.proxy_runtime.unsupported_route")
        )
    }

    private func handleResponsesRequest(body: Data, downstreamHeaders: [String: String]) async -> HTTPResponse {
        let object: [String: Any]
        do {
            object = try parseJSONObject(from: body)
        } catch {
            return jsonError(statusCode: 400, message: error.localizedDescription)
        }

        let payload: [String: Any]
        let downstreamStream: Bool
        do {
            let normalized = try normalizeResponsesRequest(object)
            payload = normalized.payload
            downstreamStream = normalized.downstreamStream
        } catch {
            return jsonError(statusCode: 400, message: error.localizedDescription)
        }

        let upstream: UpstreamResponse
        if downstreamStream {
            do {
                return try await makeResponsesStreamingHTTPResponse(
                    payload: payload,
                    downstreamHeaders: downstreamHeaders
                )
            } catch {
                return jsonError(statusCode: 502, message: error.localizedDescription)
            }
        }

        do {
            upstream = try await sendOverCandidates(payload: payload, downstreamHeaders: downstreamHeaders)
        } catch {
            return jsonError(statusCode: 502, message: error.localizedDescription)
        }

        do {
            let completed = try extractCompletedResponse(fromSSE: upstream.body)
            let rewritten = rewriteResponseModelFields(completed)
            return HTTPResponse.json(statusCode: 200, object: rewritten)
        } catch {
            return jsonError(statusCode: 502, message: error.localizedDescription)
        }
    }

    private func handleChatCompletionsRequest(body: Data, downstreamHeaders: [String: String]) async -> HTTPResponse {
        let object: [String: Any]
        do {
            object = try parseJSONObject(from: body)
        } catch {
            return jsonError(statusCode: 400, message: error.localizedDescription)
        }

        let payload: [String: Any]
        let downstreamStream: Bool
        let requestedModel: String

        do {
            requestedModel = (object["model"] as? String) ?? "gpt-5"
            let normalized = try convertChatRequestToResponses(object)
            payload = normalized.payload
            downstreamStream = normalized.downstreamStream
        } catch {
            return jsonError(statusCode: 400, message: error.localizedDescription)
        }

        let upstream: UpstreamResponse
        if downstreamStream {
            do {
                return try await makeChatCompletionsStreamingHTTPResponse(
                    payload: payload,
                    downstreamHeaders: downstreamHeaders,
                    requestedModel: requestedModel
                )
            } catch {
                return jsonError(statusCode: 502, message: error.localizedDescription)
            }
        }

        do {
            upstream = try await sendOverCandidates(payload: payload, downstreamHeaders: downstreamHeaders)
        } catch {
            return jsonError(statusCode: 502, message: error.localizedDescription)
        }

        do {
            let completed = try extractCompletedResponse(fromSSE: upstream.body)
            let completion = convertCompletedResponseToChatCompletion(completed, fallbackModel: requestedModel)
            return HTTPResponse.json(statusCode: 200, object: completion)
        } catch {
            return jsonError(statusCode: 502, message: error.localizedDescription)
        }
    }

    private func sendOverCandidates(payload: [String: Any], downstreamHeaders: [String: String]) async throws -> UpstreamResponse {
        let candidates = try currentCandidates()
        guard !candidates.isEmpty else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.no_accounts_available"))
        }

        var failureDetails: [String] = []
        var retryFailures: [RetryFailureInfo] = []
        for candidate in candidates {
            do {
                let response = try await sendUpstream(payload: payload, candidate: candidate, downstreamHeaders: downstreamHeaders)
                if response.statusCode >= 200 && response.statusCode < 300 {
                    try await recordSuccessfulCandidate(candidate)
                    return response
                }

                let bodyText = String(data: response.body, encoding: .utf8) ?? ""
                let detail = "\(candidate.label): \(response.statusCode) \(truncateForError(bodyText, maxLength: 120))"
                failureDetails.append(detail)

                if let retryFailure = classifyRetryFailure(statusCode: response.statusCode, bodyText: bodyText) {
                    markCooldown(for: candidate.accountID, category: retryFailure.category)
                    retryFailures.append(retryFailure)
                    continue
                } else {
                    lastError = detail
                    break
                }
            } catch {
                let detail = "\(candidate.label): \(error.localizedDescription)"
                failureDetails.append(detail)
            }
        }

        if !retryFailures.isEmpty && retryFailures.count == candidates.count {
            let summary = buildRetriableFailureSummary(retryFailures)
            let message = summary.isEmpty
                ? L10n.tr("error.proxy_runtime.all_accounts_unavailable")
                : L10n.tr("error.proxy_runtime.all_accounts_unavailable_with_summary_format", summary)
            lastError = message
            throw AppError.network(message)
        }

        let preview = failureDetails.prefix(2).joined(separator: " | ")
        let message = failureDetails.count > 2
            ? L10n.tr("error.proxy_runtime.upstream_failed_with_more_format", preview, String(failureDetails.count - 2))
            : L10n.tr("error.proxy_runtime.upstream_failed_format", preview)
        lastError = message
        throw AppError.network(message)
    }

    private func sendStreamingOverCandidates(
        payload: [String: Any],
        downstreamHeaders: [String: String]
    ) async throws -> UpstreamStreamingResponse {
        let candidates = try currentCandidates()
        guard !candidates.isEmpty else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.no_accounts_available"))
        }

        var failureDetails: [String] = []
        var retryFailures: [RetryFailureInfo] = []
        for candidate in candidates {
            do {
                let response = try await openStreamingUpstreamRequest(
                    payload: payload,
                    candidate: candidate,
                    downstreamHeaders: downstreamHeaders
                )

                if response.statusCode >= 200 && response.statusCode < 300 {
                    try await recordSuccessfulCandidate(candidate)
                    return response
                }

                var buffered = Data()
                for try await byte in response.bytes {
                    buffered.append(byte)
                    if buffered.count > ProxyRuntimeLimits.maxUpstreamResponseBytes {
                        break
                    }
                }
                let bodyText = String(data: buffered, encoding: .utf8) ?? ""
                let detail = "\(candidate.label): \(response.statusCode) \(truncateForError(bodyText, maxLength: 120))"
                failureDetails.append(detail)

                if let retryFailure = classifyRetryFailure(statusCode: response.statusCode, bodyText: bodyText) {
                    markCooldown(for: candidate.accountID, category: retryFailure.category)
                    retryFailures.append(retryFailure)
                    continue
                } else {
                    lastError = detail
                    break
                }
            } catch {
                let detail = "\(candidate.label): \(error.localizedDescription)"
                failureDetails.append(detail)
            }
        }

        if !retryFailures.isEmpty && retryFailures.count == candidates.count {
            let summary = buildRetriableFailureSummary(retryFailures)
            let message = summary.isEmpty
                ? L10n.tr("error.proxy_runtime.all_accounts_unavailable")
                : L10n.tr("error.proxy_runtime.all_accounts_unavailable_with_summary_format", summary)
            lastError = message
            throw AppError.network(message)
        }

        let preview = failureDetails.prefix(2).joined(separator: " | ")
        let message = failureDetails.count > 2
            ? L10n.tr("error.proxy_runtime.upstream_failed_with_more_format", preview, String(failureDetails.count - 2))
            : L10n.tr("error.proxy_runtime.upstream_failed_format", preview)
        lastError = message
        throw AppError.network(message)
    }

    private func makeResponsesStreamingHTTPResponse(
        payload: [String: Any],
        downstreamHeaders: [String: String]
    ) async throws -> HTTPResponse {
        let upstream = try await sendStreamingOverCandidates(
            payload: payload,
            downstreamHeaders: downstreamHeaders
        )
        let decoder = makeResponsesPassthroughSSEStreamDecoder()

        let stream = AsyncThrowingStream<Data, Error> { continuation in
            Task {
                do {
                    var iterator = upstream.bytes.makeAsyncIterator()
                    var buffer = Data()
                    var totalBytes = 0

                    while let byte = try await iterator.next() {
                        buffer.append(byte)
                        totalBytes += 1
                        if totalBytes > ProxyRuntimeLimits.maxUpstreamResponseBytes {
                            throw AppError.network(
                                L10n.tr(
                                    "error.proxy_runtime.upstream_response_too_large_format",
                                    ProxyRuntimeLimits.limitDescription(for: ProxyRuntimeLimits.maxUpstreamResponseBytes)
                                )
                            )
                        }

                        if byte == 0x0A {
                            for eventData in consumeResponsesPassthroughSSEChunk(decoder, data: buffer, isFinal: false) {
                                continuation.yield(eventData)
                            }
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }

                    for eventData in consumeResponsesPassthroughSSEChunk(decoder, data: buffer, isFinal: true) {
                        continuation.yield(eventData)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }

        return HTTPResponse(
            statusCode: 200,
            headers: [
                "Content-Type": "text/event-stream; charset=utf-8",
                "Cache-Control": "no-cache"
            ],
            body: stream
        )
    }

    private func makeChatCompletionsStreamingHTTPResponse(
        payload: [String: Any],
        downstreamHeaders: [String: String],
        requestedModel: String
    ) async throws -> HTTPResponse {
        let upstream = try await sendStreamingOverCandidates(
            payload: payload,
            downstreamHeaders: downstreamHeaders
        )
        let decoder = makeChatCompletionsSSEStreamDecoder(fallbackModel: requestedModel)

        let stream = AsyncThrowingStream<Data, Error> { continuation in
            Task {
                do {
                    var iterator = upstream.bytes.makeAsyncIterator()
                    var buffer = Data()
                    var totalBytes = 0

                    while let byte = try await iterator.next() {
                        buffer.append(byte)
                        totalBytes += 1
                        if totalBytes > ProxyRuntimeLimits.maxUpstreamResponseBytes {
                            throw AppError.network(
                                L10n.tr(
                                    "error.proxy_runtime.upstream_response_too_large_format",
                                    ProxyRuntimeLimits.limitDescription(for: ProxyRuntimeLimits.maxUpstreamResponseBytes)
                                )
                            )
                        }

                        if byte == 0x0A {
                            let chunks = try consumeChatCompletionsSSEStreamChunk(
                                decoder,
                                data: buffer,
                                isFinal: false
                            )
                            for chunk in chunks {
                                continuation.yield(Data("data: \(jsonString(chunk))\n\n".utf8))
                            }
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }

                    let finalChunks = try consumeChatCompletionsSSEStreamChunk(
                        decoder,
                        data: buffer,
                        isFinal: true
                    )
                    for chunk in finalChunks {
                        continuation.yield(Data("data: \(jsonString(chunk))\n\n".utf8))
                    }
                    continuation.yield(Data("data: [DONE]\n\n".utf8))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }

        return HTTPResponse(
            statusCode: 200,
            headers: [
                "Content-Type": "text/event-stream; charset=utf-8",
                "Cache-Control": "no-cache"
            ],
            body: stream
        )
    }

    private func parseJSONObject(from data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.request_body_must_be_object"))
        }
        return dict
    }

    func rewriteResponseModelFields(_ value: [String: Any]) -> [String: Any] {
        var output: Any = value
        recurseNormalizeModels(&output)
        return output as? [String: Any] ?? value
    }

    private func recurseNormalizeModels(_ any: inout Any) {
        if var dict = any as? [String: Any] {
            for key in dict.keys {
                if key == "model", let model = dict[key] as? String {
                    dict[key] = normalizeModelForClient(model)
                } else if var child = dict[key] {
                    recurseNormalizeModels(&child)
                    dict[key] = child
                }
            }
            any = dict
            return
        }

        if var array = any as? [Any] {
            for index in array.indices {
                var child = array[index]
                recurseNormalizeModels(&child)
                array[index] = child
            }
            any = array
        }
    }

    func truncateForError(_ value: String, maxLength: Int) -> String {
        if value.count <= maxLength { return value }
        let index = value.index(value.startIndex, offsetBy: maxLength)
        return "\(value[..<index])..."
    }

    func jsonString(_ object: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: object),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "{}"
    }

    private func jsonError(statusCode: Int, message: String) -> HTTPResponse {
        HTTPResponse.json(statusCode: statusCode, object: [
            "error": [
                "message": message,
                "type": statusCode == 400 ? "invalid_request_error" : "server_error"
            ]
        ])
    }

    func normalizedClientModelToken(_ model: String) -> String {
        model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    func normalizedNumericModelRevisionIfNeeded(_ normalizedModel: String) -> String {
        guard normalizedModel.hasPrefix("gpt-5-") else {
            return normalizedModel
        }

        let suffix = String(normalizedModel.dropFirst("gpt-5-".count))
        guard let firstSegment = suffix.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first,
              !firstSegment.isEmpty,
              firstSegment.allSatisfy(\.isNumber) else {
            return normalizedModel
        }

        let afterRevision = String(suffix.dropFirst(firstSegment.count))
        return "gpt-5.\(firstSegment)\(afterRevision)"
    }

    func currentUnixSeconds() -> Int64 {
        dateProvider.unixSecondsNow()
    }

    func currentUnixMilliseconds() -> Int64 {
        dateProvider.unixMillisecondsNow()
    }

    func cooldownDuration(for category: RetryFailureCategory) -> Int64 {
        switch category {
        case .rateLimited:
            return 60
        case .quotaExceeded, .modelRestricted, .authentication, .permission:
            return 300
        }
    }

    func markCooldown(for accountID: String, category: RetryFailureCategory) {
        cooldownUntilByAccountID[accountID] = currentUnixSeconds() + cooldownDuration(for: category)
        if stickyAccountID == accountID {
            stickyAccountID = nil
        }
    }

    func recordSuccessfulCandidate(_ candidate: ProxyCandidate) async throws {
        let storeBefore = try storeRepository.loadStore()
        AccountSwitchDebugLog.write(
            "proxy.recordSuccessfulCandidate.begin",
            "candidateCardID=\(candidate.id) accountID=\(candidate.accountID) accountKey=\(candidate.accountKey) before=\(AccountSwitchDebugLog.describe(store: storeBefore, currentAuthAccountKey: authRepository.currentAuthAccountKey()))"
        )
        activeAccountID = candidate.accountID
        activeAccountLabel = candidate.label
        stickyAccountID = candidate.accountID
        cooldownUntilByAccountID.removeValue(forKey: candidate.accountID)
        guard storeBefore.accounts.contains(where: { $0.id == candidate.id }) else {
            throw AppError.invalidData(L10n.tr("error.accounts.account_not_found_for_switch"))
        }
        guard let switchAccount else {
            throw AppError.invalidData("Proxy runtime is missing the account switch handler.")
        }
        try await switchAccount(candidate.id)
        let storeAfter = try storeRepository.loadStore()
        cachedCandidatesStoreModificationDate = nil
        onAccountsStoreChanged?()
        lastError = nil
        AccountSwitchDebugLog.write(
            "proxy.recordSuccessfulCandidate.end",
            "candidateCardID=\(candidate.id) after=\(AccountSwitchDebugLog.describe(store: storeAfter, currentAuthAccountKey: authRepository.currentAuthAccountKey()))"
        )
    }

}
