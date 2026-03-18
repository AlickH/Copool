import Foundation

actor SwiftNativeProxyRuntimeService: ProxyRuntimeService {
    enum UpstreamRouteFamily: Equatable {
        case codex
        case general
    }

    private static let stableClientModels = [
        "gpt-5",
        "gpt-5-4",
        "gpt-5.4",
        "gpt-5-mini",
        "gpt-5.1",
        "gpt-5.2",
        "gpt-5.3"
    ]

    private static let compatibilityCodexModels = [
        "gpt-5-codex",
        "gpt-5-codex-mini",
        "gpt-5.1-codex",
        "gpt-5.1-codex-mini",
        "gpt-5.1-codex-max",
        "gpt-5.2-codex",
        "gpt-5.3-codex",
        "gpt-5.3-codex-spark"
    ]

    private static let clientVisibleModels = stableClientModels + compatibilityCodexModels
    private static let defaultCodexClientVersion = "0.101.0"
    private static let defaultCodexUserAgent = "codex_cli_rs/0.101.0 (Mac OS 26.0.1; arm64) Apple_Terminal/464"

    private let paths: FileSystemPaths
    private let storeRepository: AccountsStoreRepository
    private let authRepository: AuthRepository
    private let dateProvider: DateProviding

    private var server: SimpleHTTPServer?
    private var runningPort: Int?
    private var activeAccountID: String?
    private var activeAccountLabel: String?
    private var lastError: String?

    private let models = SwiftNativeProxyRuntimeService.clientVisibleModels

    init(
        paths: FileSystemPaths,
        storeRepository: AccountsStoreRepository,
        authRepository: AuthRepository,
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.paths = paths
        self.storeRepository = storeRepository
        self.authRepository = authRepository
        self.dateProvider = dateProvider
    }

    func status() async -> ApiProxyStatus {
        let running = server != nil
        let apiKey = (try? ensurePersistedAPIKey()) ?? nil
        let availableAccounts = (try? loadCandidates().count) ?? 0

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
            boundServer.start()
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
        do {
            upstream = try await sendOverCandidates(payload: payload, downstreamHeaders: downstreamHeaders)
        } catch {
            return jsonError(statusCode: 502, message: error.localizedDescription)
        }

        if downstreamStream {
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream; charset=utf-8"],
                body: upstream.body
            )
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
        do {
            upstream = try await sendOverCandidates(payload: payload, downstreamHeaders: downstreamHeaders)
        } catch {
            return jsonError(statusCode: 502, message: error.localizedDescription)
        }

        if downstreamStream {
            do {
                let sse = try convertResponsesSSEToChatCompletionsSSE(upstream.body, fallbackModel: requestedModel)
                return HTTPResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream; charset=utf-8"],
                    body: sse
                )
            } catch {
                return jsonError(statusCode: 502, message: error.localizedDescription)
            }
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
        let candidates = try loadCandidates()
        guard !candidates.isEmpty else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.no_accounts_available"))
        }

        var failureDetails: [String] = []
        var retryFailures: [RetryFailureInfo] = []
        for candidate in candidates {
            do {
                let response = try await sendUpstream(payload: payload, candidate: candidate, downstreamHeaders: downstreamHeaders)
                if response.statusCode >= 200 && response.statusCode < 300 {
                    activeAccountID = candidate.accountID
                    activeAccountLabel = candidate.label
                    lastError = nil
                    return response
                }

                let bodyText = String(data: response.body, encoding: .utf8) ?? ""
                let detail = "\(candidate.label): \(response.statusCode) \(truncateForError(bodyText, maxLength: 120))"
                failureDetails.append(detail)

                if let retryFailure = classifyRetryFailure(statusCode: response.statusCode, bodyText: bodyText) {
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

    private func sendUpstream(payload: [String: Any], candidate: ProxyCandidate, downstreamHeaders: [String: String]) async throws -> UpstreamResponse {
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.invalid_upstream_payload"))
        }

        let firstResponse = try await performUpstreamRequest(payload: payload, candidate: candidate, downstreamHeaders: downstreamHeaders)
        let firstBodyText = String(data: firstResponse.body, encoding: .utf8) ?? ""
        if Self.shouldRetryWithAutoReasoningSummary(statusCode: firstResponse.statusCode, bodyText: firstBodyText),
           let adjustedPayload = Self.payloadWithAutoReasoningSummaryIfNeeded(payload: payload) {
            return try await performUpstreamRequest(payload: adjustedPayload, candidate: candidate, downstreamHeaders: downstreamHeaders)
        }

        return firstResponse
    }

    private func performUpstreamRequest(payload: [String: Any], candidate: ProxyCandidate, downstreamHeaders: [String: String]) async throws -> UpstreamResponse {
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

        if statusCode == 200 {
            try? authRepository.writeCurrentAuth(candidate.authJSON)
        }
        return UpstreamResponse(statusCode: statusCode, body: responseBody)
    }

    static func shouldRetryWithAutoReasoningSummary(statusCode: Int, bodyText: String) -> Bool {
        guard statusCode == 400 else { return false }
        let normalized = bodyText.lowercased()
        return normalized.contains("unsupported value")
            && normalized.contains("none")
            && (normalized.contains("model")
                || normalized.contains("reasoning.summary")
                || normalized.contains("reasoning.effort"))
    }

    static func payloadWithAutoReasoningSummaryIfNeeded(payload: [String: Any]) -> [String: Any]? {
        guard var reasoning = payload["reasoning"] as? [String: Any] else {
            return nil
        }

        let summaryRaw = (reasoning["summary"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let effortRaw = (reasoning["effort"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let shouldFixSummary = summaryRaw == "none"
        let shouldFixEffort = effortRaw == "none"

        guard shouldFixSummary || shouldFixEffort else {
            return nil
        }

        var updated = payload
        if shouldFixSummary {
            reasoning["summary"] = "auto"
        }
        if shouldFixEffort {
            reasoning["effort"] = "medium"
        }
        updated["reasoning"] = reasoning
        return updated
    }

    static func normalizedReasoningSummaryForUpstream(_ summary: String?) -> String {
        let raw = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lowered = raw.lowercased()
        if lowered.isEmpty || lowered == "none" {
            return "auto"
        }
        return raw
    }

    static func normalizedReasoningForUpstream(_ reasoning: [String: Any], upstreamModel: String? = nil) -> [String: Any] {
        var result = reasoning
        let effort = normalizedReasoningEffortForUpstream(result["effort"] as? String, upstreamModel: upstreamModel)
        result["effort"] = effort
        let summary = result["summary"] as? String
        result["summary"] = normalizedReasoningSummaryForUpstream(summary)
        return result
    }

    static func normalizedReasoningEffortForUpstream(_ effort: String?, upstreamModel: String? = nil) -> String {
        let raw = effort?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let routeFamily = upstreamModel.map(resolveUpstreamRouteFamily(forUpstreamModel:)) ?? .general
        let defaultEffort = defaultReasoningEffortForUpstream(upstreamModel)

        if raw.isEmpty {
            return defaultEffort
        }

        if routeFamily == .codex {
            switch raw {
            case "low", "medium", "high", "xhigh":
                return raw
            case "none", "minimal":
                return defaultEffort
            default:
                return defaultEffort
            }
        }

        switch raw {
        case "none", "minimal", "low", "medium", "high", "xhigh":
            return raw
        default:
            return defaultEffort
        }
    }

    static func defaultReasoningEffortForUpstream(_ upstreamModel: String?) -> String {
        let routeFamily = upstreamModel.map(resolveUpstreamRouteFamily(forUpstreamModel:)) ?? .general
        return routeFamily == .codex ? "medium" : "none"
    }

    static func normalizedForwardHeader(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func loadCandidates() throws -> [ProxyCandidate] {
        let store = try storeRepository.loadStore()

        let candidates = try store.accounts.compactMap { account -> ProxyCandidate? in
            let extracted = try authRepository.extractAuth(from: account.authJSON)
            return ProxyCandidate(
                id: account.id,
                label: account.label,
                accountID: extracted.accountID,
                accessToken: extracted.accessToken,
                authJSON: account.authJSON,
                oneWeekUsed: account.usage?.oneWeek?.usedPercent,
                fiveHourUsed: account.usage?.fiveHour?.usedPercent
            )
        }

        return candidates.sorted { lhs, rhs in
            lhs.remainingScore > rhs.remainingScore
        }
    }

    private func parseJSONObject(from data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.request_body_must_be_object"))
        }
        return dict
    }

    private func normalizeResponsesRequest(_ request: [String: Any]) throws -> (payload: [String: Any], downstreamStream: Bool) {
        guard let rawModel = request["model"] as? String, !rawModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.missing_model"))
        }
        let model = try mapClientModelToUpstream(rawModel)

        var payload = request
        let downstreamStream = (request["stream"] as? Bool) ?? false

        payload["model"] = model
        payload["stream"] = true
        payload["store"] = false
        if payload["instructions"] == nil {
            payload["instructions"] = ""
        }
        if payload["parallel_tool_calls"] == nil {
            payload["parallel_tool_calls"] = true
        }

        let currentReasoning = payload["reasoning"] as? [String: Any] ?? [:]
        payload["reasoning"] = Self.normalizedReasoningForUpstream(currentReasoning, upstreamModel: model)

        var include = payload["include"] as? [Any] ?? []
        if !include.contains(where: { ($0 as? String) == "reasoning.encrypted_content" }) {
            include.append("reasoning.encrypted_content")
        }
        payload["include"] = include

        return (payload, downstreamStream)
    }

    private func convertChatRequestToResponses(_ request: [String: Any]) throws -> (payload: [String: Any], downstreamStream: Bool) {
        if request["messages"] == nil, request["input"] != nil {
            return try normalizeResponsesRequest(request)
        }

        guard let rawModel = request["model"] as? String, !rawModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.missing_model"))
        }
        let model = try mapClientModelToUpstream(rawModel)

        guard let messages = request["messages"] as? [Any] else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.chat_missing_messages"))
        }

        let downstreamStream = (request["stream"] as? Bool) ?? false

        var input: [[String: Any]] = []
        for raw in messages {
            guard let message = raw as? [String: Any] else {
                throw AppError.invalidData(L10n.tr("error.proxy_runtime.messages_item_must_be_object"))
            }

            guard let role = message["role"] as? String, !role.isEmpty else {
                throw AppError.invalidData(L10n.tr("error.proxy_runtime.message_missing_role"))
            }

            if role == "tool" {
                let callID = (message["tool_call_id"] as? String) ?? ""
                let output = stringifyMessageContent(message["content"])
                input.append([
                    "type": "function_call_output",
                    "call_id": callID,
                    "output": output
                ])
                continue
            }

            let mappedRole: String
            switch role {
            case "system", "developer": mappedRole = "developer"
            case "assistant": mappedRole = "assistant"
            default: mappedRole = "user"
            }

            let contentParts = convertMessageContentToCodexParts(role: role, content: message["content"])
            input.append([
                "type": "message",
                "role": mappedRole,
                "content": contentParts
            ])

            if role == "assistant",
               let toolCalls = message["tool_calls"] as? [Any] {
                for rawToolCall in toolCalls {
                    guard let toolCall = rawToolCall as? [String: Any] else { continue }
                    let toolType = (toolCall["type"] as? String) ?? "function"
                    if toolType != "function" { continue }
                    guard let function = toolCall["function"] as? [String: Any] else { continue }

                    let name = (function["name"] as? String) ?? ""
                    let arguments = stringifyJSONField(function["arguments"])
                    let callID = (toolCall["id"] as? String) ?? ""
                    input.append([
                        "type": "function_call",
                        "call_id": callID,
                        "name": name,
                        "arguments": arguments
                    ])
                }
            }
        }

        let reasoningEffort = (request["reasoning_effort"] as? String)
            ?? (((request["reasoning"] as? [String: Any])?["effort"] as? String) ?? "medium")
        let reasoningSummary = ((request["reasoning"] as? [String: Any])?["summary"] as? String) ?? "auto"
        let reasoning = Self.normalizedReasoningForUpstream([
            "effort": reasoningEffort,
            "summary": reasoningSummary
        ], upstreamModel: model)

        var payload: [String: Any] = [
            "model": model,
            "stream": true,
            "store": false,
            "instructions": "",
            "parallel_tool_calls": (request["parallel_tool_calls"] as? Bool) ?? true,
            "include": ["reasoning.encrypted_content"],
            "reasoning": reasoning,
            "input": input
        ]

        if let tools = request["tools"] as? [Any] {
            var convertedTools: [[String: Any]] = []
            for rawTool in tools {
                guard let tool = rawTool as? [String: Any] else { continue }
                let type = (tool["type"] as? String) ?? ""
                if type == "function",
                   let function = tool["function"] as? [String: Any] {
                    var converted: [String: Any] = ["type": "function"]
                    if let name = function["name"] { converted["name"] = name }
                    if let description = function["description"] { converted["description"] = description }
                    if let parameters = function["parameters"] { converted["parameters"] = parameters }
                    if let strict = function["strict"] { converted["strict"] = strict }
                    convertedTools.append(converted)
                } else {
                    convertedTools.append(tool)
                }
            }
            if !convertedTools.isEmpty {
                payload["tools"] = convertedTools
            }
        }
        if let toolChoice = request["tool_choice"] {
            payload["tool_choice"] = toolChoice
        }

        if let responseFormat = request["response_format"] {
            mapResponseFormat(into: &payload, responseFormat: responseFormat)
        }
        if let text = request["text"] {
            mapTextSettings(into: &payload, text: text)
        }

        return (payload, downstreamStream)
    }

    private func convertMessageContentToCodexParts(role: String, content: Any?) -> [[String: Any]] {
        let textType = role == "assistant" ? "output_text" : "input_text"

        guard let content else { return [] }

        if let text = content as? String {
            guard !text.isEmpty else { return [] }
            return [["type": textType, "text": text]]
        }

        guard let items = content as? [Any] else { return [] }
        var parts: [[String: Any]] = []

        for raw in items {
            guard let item = raw as? [String: Any],
                  let type = item["type"] as? String else { continue }

            if type == "text", let text = item["text"] as? String {
                parts.append(["type": textType, "text": text])
                continue
            }

            if type == "image_url",
               let image = item["image_url"] as? [String: Any],
               let url = image["url"] as? String,
               ["user", "developer", "system"].contains(role) {
                parts.append(["type": "input_image", "image_url": url])
                continue
            }
        }

        return parts
    }

    private func stringifyContent(_ value: Any?) -> String {
        guard let value else { return "" }

        if let text = value as? String {
            return text
        }

        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return text
        }

        return String(describing: value)
    }

    private func stringifyMessageContent(_ content: Any?) -> String {
        guard let content else { return "" }

        if let text = content as? String {
            return text
        }

        if let items = content as? [Any] {
            let texts = items.compactMap { item -> String? in
                guard let object = item as? [String: Any] else { return nil }
                return object["text"] as? String
            }
            return texts.joined(separator: "\n")
        }

        if let null = content as? NSNull, null == NSNull() {
            return ""
        }

        if JSONSerialization.isValidJSONObject(content),
           let data = try? JSONSerialization.data(withJSONObject: content),
           let text = String(data: data, encoding: .utf8) {
            return text
        }

        return ""
    }

    private func stringifyJSONField(_ value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String {
            return text
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return ""
    }

    private func mapResponseFormat(into root: inout [String: Any], responseFormat: Any) {
        guard let formatObject = responseFormat as? [String: Any],
              let formatType = formatObject["type"] as? String else {
            return
        }

        var text = root["text"] as? [String: Any] ?? [:]
        var format = text["format"] as? [String: Any] ?? [:]

        switch formatType {
        case "text":
            format["type"] = "text"
        case "json_schema":
            format["type"] = "json_schema"
            if let schemaObject = formatObject["json_schema"] as? [String: Any] {
                if let name = schemaObject["name"] { format["name"] = name }
                if let strict = schemaObject["strict"] { format["strict"] = strict }
                if let schema = schemaObject["schema"] { format["schema"] = schema }
            }
        default:
            break
        }

        text["format"] = format
        root["text"] = text
    }

    private func mapTextSettings(into root: inout [String: Any], text value: Any) {
        guard let textObject = value as? [String: Any],
              let verbosity = textObject["verbosity"] else {
            return
        }

        var target = root["text"] as? [String: Any] ?? [:]
        target["verbosity"] = verbosity
        root["text"] = target
    }

    private func convertCompletedResponseToChatCompletion(_ response: [String: Any], fallbackModel: String) -> [String: Any] {
        let id = (response["id"] as? String) ?? "chatcmpl_\(UUID().uuidString)"
        let created = (response["created_at"] as? Int) ?? Int(dateProvider.unixSecondsNow())
        let model = normalizeModelForClient((response["model"] as? String) ?? fallbackModel)

        var message: [String: Any] = ["role": "assistant"]
        var reasoningContent: String?
        var textContent: String?
        var toolCalls: [[String: Any]] = []

        if let output = response["output"] as? [Any] {
            for rawItem in output {
                guard let item = rawItem as? [String: Any],
                      let type = item["type"] as? String else { continue }

                switch type {
                case "reasoning":
                    if let summary = item["summary"] as? [Any] {
                        for rawSummary in summary {
                            guard let summaryObject = rawSummary as? [String: Any] else { continue }
                            if (summaryObject["type"] as? String) == "summary_text",
                               let text = summaryObject["text"] as? String,
                               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                reasoningContent = text
                                break
                            }
                        }
                    }
                case "message":
                    if let content = item["content"] as? [Any] {
                        var chunks: [String] = []
                        for rawContent in content {
                            guard let contentObject = rawContent as? [String: Any] else { continue }
                            if (contentObject["type"] as? String) == "output_text",
                               let text = contentObject["text"] as? String,
                               !text.isEmpty {
                                chunks.append(text)
                            }
                        }
                        if !chunks.isEmpty {
                            textContent = chunks.joined()
                        }
                    }
                case "function_call":
                    let callID = (item["call_id"] as? String) ?? ""
                    let name = (item["name"] as? String) ?? ""
                    let arguments = (item["arguments"] as? String) ?? ""
                    toolCalls.append([
                        "id": callID,
                        "type": "function",
                        "function": [
                            "name": name,
                            "arguments": arguments
                        ]
                    ])
                default:
                    break
                }
            }
        }

        if textContent == nil {
            textContent = extractAssistantText(fromCompletedResponse: response)
        }

        message["content"] = textContent ?? NSNull()
        if let reasoningContent {
            message["reasoning_content"] = reasoningContent
        }
        if !toolCalls.isEmpty {
            message["tool_calls"] = toolCalls
        }

        let finishReason = toolCalls.isEmpty ? "stop" : "tool_calls"

        var root: [String: Any] = [
            "id": id,
            "object": "chat.completion",
            "created": created,
            "model": model,
            "choices": [[
                "index": 0,
                "message": message,
                "finish_reason": finishReason,
                "native_finish_reason": finishReason
            ]]
        ]

        if let usage = response["usage"] as? [String: Any] {
            root["usage"] = buildOpenAIUsage(from: usage)
        }

        return root
    }

    private func convertResponsesSSEToChatCompletionsSSE(_ sseData: Data, fallbackModel: String) throws -> Data {
        let events = parseSSEEvents(from: sseData)
        var state = ChatStreamState(
            responseID: "chatcmpl_\(UUID().uuidString)",
            createdAt: Int(dateProvider.unixSecondsNow()),
            model: normalizeModelForClient(fallbackModel),
            functionCallIndex: -1,
            hasReceivedArgumentsDelta: false,
            hasToolCallAnnounced: false
        )

        var lines = ""
        for event in events {
            let chunks = translateSSEEventToChatChunks(event, state: &state)
            for chunk in chunks {
                lines += "data: \(jsonString(chunk))\n\n"
            }
        }

        lines += "data: [DONE]\n\n"
        return Data(lines.utf8)
    }

    private func translateSSEEventToChatChunks(_ event: SSEEvent, state: inout ChatStreamState) -> [[String: Any]] {
        guard event.data != "[DONE]",
              let payloadData = event.data.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let kind = parsed["type"] as? String else {
            return []
        }

        switch kind {
        case "response.created":
            if let response = parsed["response"] as? [String: Any] {
                state.responseID = (response["id"] as? String) ?? state.responseID
                state.createdAt = (response["created_at"] as? Int) ?? state.createdAt
                state.model = normalizeModelForClient((response["model"] as? String) ?? state.model)
            }
            return []

        case "response.reasoning_summary_text.delta":
            let delta = (parsed["delta"] as? String) ?? ""
            guard !delta.isEmpty else { return [] }
            return [
                buildChatChunk(
                    state: state,
                    delta: ["role": "assistant", "reasoning_content": delta],
                    finishReason: nil,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        case "response.reasoning_summary_text.done":
            return [
                buildChatChunk(
                    state: state,
                    delta: ["role": "assistant", "reasoning_content": "\n\n"],
                    finishReason: nil,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        case "response.output_text.delta":
            let delta = (parsed["delta"] as? String) ?? ""
            guard !delta.isEmpty else { return [] }
            return [
                buildChatChunk(
                    state: state,
                    delta: ["role": "assistant", "content": delta],
                    finishReason: nil,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        case "response.output_item.added":
            guard let item = parsed["item"] as? [String: Any],
                  (item["type"] as? String) == "function_call" else {
                return []
            }
            state.functionCallIndex += 1
            state.hasReceivedArgumentsDelta = false
            state.hasToolCallAnnounced = true
            return [
                buildChatChunk(
                    state: state,
                    delta: [
                        "role": "assistant",
                        "tool_calls": [[
                            "index": state.functionCallIndex,
                            "id": (item["call_id"] as? String) ?? "",
                            "type": "function",
                            "function": [
                                "name": (item["name"] as? String) ?? "",
                                "arguments": ""
                            ]
                        ]]
                    ],
                    finishReason: nil,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        case "response.function_call_arguments.delta":
            state.hasReceivedArgumentsDelta = true
            return [
                buildChatChunk(
                    state: state,
                    delta: [
                        "tool_calls": [[
                            "index": state.functionCallIndex,
                            "function": [
                                "arguments": (parsed["delta"] as? String) ?? ""
                            ]
                        ]]
                    ],
                    finishReason: nil,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        case "response.function_call_arguments.done":
            if state.hasReceivedArgumentsDelta {
                return []
            }
            return [
                buildChatChunk(
                    state: state,
                    delta: [
                        "tool_calls": [[
                            "index": state.functionCallIndex,
                            "function": [
                                "arguments": (parsed["arguments"] as? String) ?? ""
                            ]
                        ]]
                    ],
                    finishReason: nil,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        case "response.output_item.done":
            guard let item = parsed["item"] as? [String: Any],
                  (item["type"] as? String) == "function_call" else {
                return []
            }

            if state.hasToolCallAnnounced {
                state.hasToolCallAnnounced = false
                return []
            }

            state.functionCallIndex += 1
            return [
                buildChatChunk(
                    state: state,
                    delta: [
                        "role": "assistant",
                        "tool_calls": [[
                            "index": state.functionCallIndex,
                            "id": (item["call_id"] as? String) ?? "",
                            "type": "function",
                            "function": [
                                "name": (item["name"] as? String) ?? "",
                                "arguments": (item["arguments"] as? String) ?? ""
                            ]
                        ]]
                    ],
                    finishReason: nil,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        case "response.completed":
            let finishReason = state.functionCallIndex >= 0 ? "tool_calls" : "stop"
            return [
                buildChatChunk(
                    state: state,
                    delta: [:],
                    finishReason: finishReason,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        default:
            return []
        }
    }

    private func buildChatChunk(
        state: ChatStreamState,
        delta: [String: Any],
        finishReason: String?,
        usage: [String: Any]?
    ) -> [String: Any] {
        let finishValue: Any = finishReason ?? NSNull()
        var chunk: [String: Any] = [
            "id": state.responseID,
            "object": "chat.completion.chunk",
            "created": max(0, state.createdAt),
            "model": state.model,
            "choices": [[
                "index": 0,
                "delta": delta,
                "finish_reason": finishValue,
                "native_finish_reason": finishValue
            ]]
        ]

        if let usage {
            chunk["usage"] = buildOpenAIUsage(from: usage)
        }

        return chunk
    }

    private func extractAssistantText(fromCompletedResponse response: [String: Any]) -> String {
        var segments: [String] = []

        if let outputs = response["output"] as? [Any] {
            for item in outputs {
                guard let object = item as? [String: Any] else { continue }

                if let type = object["type"] as? String, type == "output_text", let text = object["text"] as? String {
                    segments.append(text)
                    continue
                }

                if let messageType = object["type"] as? String, messageType == "message",
                   let content = object["content"] as? [Any] {
                    for part in content {
                        guard let partObj = part as? [String: Any] else { continue }
                        if let text = partObj["text"] as? String {
                            segments.append(text)
                        }
                    }
                }
            }
        }

        if segments.isEmpty, let text = response["output_text"] as? String {
            segments.append(text)
        }

        return segments.joined(separator: "")
    }

    private func buildOpenAIUsage(from usage: [String: Any]) -> [String: Any] {
        var root: [String: Any] = [:]
        if let inputTokens = usage["input_tokens"] {
            root["prompt_tokens"] = inputTokens
        }
        if let outputTokens = usage["output_tokens"] {
            root["completion_tokens"] = outputTokens
        }
        if let totalTokens = usage["total_tokens"] {
            root["total_tokens"] = totalTokens
        }
        if let inputDetails = usage["input_tokens_details"] as? [String: Any],
           let cached = inputDetails["cached_tokens"] {
            root["prompt_tokens_details"] = ["cached_tokens": cached]
        }
        if let outputDetails = usage["output_tokens_details"] as? [String: Any],
           let reasoning = outputDetails["reasoning_tokens"] {
            root["completion_tokens_details"] = ["reasoning_tokens": reasoning]
        }
        return root
    }

    private func extractCompletedResponse(fromSSE data: Data) throws -> [String: Any] {
        let events = parseSSEEvents(from: data)
        var lastJSON: [String: Any]?

        for event in events {
            guard event.data != "[DONE]" else { continue }
            guard let payloadData = event.data.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                continue
            }

            lastJSON = object

            if (object["type"] as? String) == "response.completed",
               let response = object["response"] as? [String: Any] {
                return response
            }

            if object["id"] != nil, object["output"] != nil {
                return object
            }

            if (object["type"] as? String) == "response.error" {
                let message = (object["error"] as? [String: Any])?["message"] as? String ?? L10n.tr("error.proxy_runtime.upstream_response_error")
                throw AppError.network(message)
            }
        }

        if let lastJSON {
            return lastJSON
        }

        throw AppError.network(L10n.tr("error.proxy_runtime.sse_extract_completed_failed"))
    }

    private func parseSSEEvents(from data: Data) -> [SSEEvent] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")

        return normalized
            .components(separatedBy: "\n\n")
            .compactMap { block in
                if block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return nil
                }

                var eventName: String?
                var dataLines: [String] = []
                for line in block.components(separatedBy: "\n") {
                    if line.hasPrefix("event:") {
                        eventName = line.replacingOccurrences(of: "event:", with: "").trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("data:") {
                        dataLines.append(line.replacingOccurrences(of: "data:", with: "").trimmingCharacters(in: .whitespaces))
                    }
                }

                let joinedData = dataLines.joined(separator: "\n")
                return joinedData.isEmpty ? nil : SSEEvent(event: eventName, data: joinedData)
            }
    }

    private func rewriteResponseModelFields(_ value: [String: Any]) -> [String: Any] {
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

    private func mapClientModelToUpstream(_ model: String) throws -> String {
        let normalized = normalizedClientModelToken(model)
        if normalized == "gpt-5-4" || normalized == "gpt-5.4" || normalized == "gpt5.4" {
            return "gpt-5.4"
        }
        return normalizedNumericModelRevisionIfNeeded(normalized)
    }

    private func normalizeModelForClient(_ model: String) -> String {
        let normalized = model.lowercased()
        if normalized == "gpt5.4" || normalized == "gpt-5.4" {
            return "gpt-5-4"
        }
        return model
    }

    private func classifyRetryFailure(statusCode: Int, bodyText: String) -> RetryFailureInfo? {
        let signals = extractErrorSignals(rawText: bodyText)
        let status = statusCode

        if status == 402 || containsQuotaSignal(signals.normalized) {
            return RetryFailureInfo(category: .quotaExceeded, detail: L10n.tr("error.proxy_runtime.retry.quota_exceeded_format", signals.brief))
        }
        if containsModelRestrictionSignal(signals.normalized) {
            return RetryFailureInfo(category: .modelRestricted, detail: L10n.tr("error.proxy_runtime.retry.model_restricted_format", signals.brief))
        }
        if status == 429 || containsRateLimitSignal(signals.normalized) {
            return RetryFailureInfo(category: .rateLimited, detail: L10n.tr("error.proxy_runtime.retry.rate_limited_format", signals.brief))
        }
        if status == 401 || containsAuthSignal(signals.normalized) {
            return RetryFailureInfo(category: .authentication, detail: L10n.tr("error.proxy_runtime.retry.auth_failed_format", signals.brief))
        }
        if status == 403 || containsPermissionSignal(signals.normalized) {
            return RetryFailureInfo(category: .permission, detail: L10n.tr("error.proxy_runtime.retry.permission_denied_format", signals.brief))
        }
        return nil
    }

    private func extractErrorSignals(rawText: String) -> ErrorSignals {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []

        if let data = trimmed.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            collectErrorParts(value, into: &parts)
        }

        if parts.isEmpty, !trimmed.isEmpty {
            parts.append(trimmed)
        }

        let deduped = parts.reduce(into: [String]()) { acc, item in
            guard !item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if !acc.contains(item) {
                acc.append(item)
            }
        }

        let joined = deduped.joined(separator: " | ")
        let brief = joined.isEmpty ? L10n.tr("error.proxy_runtime.no_error_detail") : truncateForError(joined, maxLength: 120)

        return ErrorSignals(
            normalized: "\(joined) \(trimmed)".lowercased(),
            brief: brief
        )
    }

    private func collectErrorParts(_ value: [String: Any], into parts: inout [String]) {
        if let error = value["error"] as? [String: Any] {
            if let message = error["message"] as? String { parts.append(message.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if let code = error["code"] as? String { parts.append(code.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if let type = error["type"] as? String { parts.append(type.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        if let message = value["message"] as? String {
            parts.append(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func containsQuotaSignal(_ text: String) -> Bool {
        text.contains("insufficient_quota")
            || text.contains("quota exceeded")
            || text.contains("usage_limit")
            || text.contains("usage limit")
            || text.contains("credit balance")
            || text.contains("billing hard limit")
            || text.contains("exceeded your current quota")
            || text.contains("usage_limit_reached")
    }

    private func containsRateLimitSignal(_ text: String) -> Bool {
        text.contains("rate limit")
            || text.contains("rate_limit")
            || text.contains("too many requests")
            || text.contains("requests per min")
            || text.contains("tokens per min")
            || text.contains("retry after")
            || text.contains("requests too quickly")
    }

    private func containsModelRestrictionSignal(_ text: String) -> Bool {
        text.contains("model_not_found")
            || text.contains("does not have access to model")
            || text.contains("do not have access to model")
            || text.contains("access to model")
            || text.contains("unsupported model")
            || text.contains("model is not supported")
            || text.contains("not available on your account")
            || text.contains("model access")
    }

    private func containsAuthSignal(_ text: String) -> Bool {
        text.contains("invalid_api_key")
            || text.contains("invalid api key")
            || text.contains("authentication")
            || text.contains("unauthorized")
            || text.contains("token expired")
            || text.contains("account deactivated")
            || text.contains("invalid token")
    }

    private func containsPermissionSignal(_ text: String) -> Bool {
        text.contains("permission")
            || text.contains("forbidden")
            || text.contains("not allowed")
            || text.contains("organization")
            || text.contains("access denied")
    }

    private func buildRetriableFailureSummary(_ failures: [RetryFailureInfo]) -> String {
        var quota = 0
        var rate = 0
        var model = 0
        var auth = 0
        var permission = 0

        for failure in failures {
            switch failure.category {
            case .quotaExceeded:
                quota += 1
            case .rateLimited:
                rate += 1
            case .modelRestricted:
                model += 1
            case .authentication:
                auth += 1
            case .permission:
                permission += 1
            }
        }

        var parts: [String] = []
        if quota > 0 { parts.append(L10n.tr("error.proxy_runtime.summary.quota_format", String(quota))) }
        if rate > 0 { parts.append(L10n.tr("error.proxy_runtime.summary.rate_format", String(rate))) }
        if model > 0 { parts.append(L10n.tr("error.proxy_runtime.summary.model_format", String(model))) }
        if auth > 0 { parts.append(L10n.tr("error.proxy_runtime.summary.auth_format", String(auth))) }
        if permission > 0 { parts.append(L10n.tr("error.proxy_runtime.summary.permission_format", String(permission))) }

        return parts.joined(separator: "，")
    }

    private func truncateForError(_ value: String, maxLength: Int) -> String {
        if value.count <= maxLength { return value }
        let index = value.index(value.startIndex, offsetBy: maxLength)
        return "\(value[..<index])..."
    }

    private func jsonString(_ object: Any) -> String {
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

    private func responsesEndpoint(forUpstreamModel model: String) -> URL {
        let routeFamily = Self.resolveUpstreamRouteFamily(forUpstreamModel: model)
        let base = resolveUpstreamBaseURL(routeFamily: routeFamily)
        return URL(string: "\(base)/responses")!
    }

    private func resolveUpstreamBaseURL(routeFamily: UpstreamRouteFamily) -> String {
        let defaultOrigin = "https://chatgpt.com"
        let configured = readChatGPTBaseURLFromConfig() ?? defaultOrigin
        return Self.resolveUpstreamBaseURL(configuredBaseURL: configured, routeFamily: routeFamily)
    }

    static func resolveUpstreamRouteFamily(forUpstreamModel model: String) -> UpstreamRouteFamily {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("codex")
            || normalized.hasPrefix("gpt-5")
            || normalized.hasPrefix("gpt-5.4")
            || normalized.hasPrefix("gpt5.4")
            || normalized.hasPrefix("gpt-5-4") {
            return .codex
        }
        return .general
    }

    static func resolveUpstreamBaseURL(configuredBaseURL: String, routeFamily: UpstreamRouteFamily) -> String {
        let normalized = normalizeConfiguredBaseURL(configuredBaseURL)
        let backendSuffix = "/backend-api"
        let codexSuffix = "/backend-api/codex"

        switch routeFamily {
        case .codex:
            if normalized.hasSuffix(codexSuffix) {
                return normalized
            }
            if normalized.hasSuffix(backendSuffix) {
                return "\(normalized)/codex"
            }
            return "\(normalized)\(codexSuffix)"
        case .general:
            if normalized.hasSuffix(codexSuffix) {
                return String(normalized.dropLast("/codex".count))
            }
            if normalized.hasSuffix(backendSuffix) {
                return normalized
            }
            return "\(normalized)\(backendSuffix)"
        }
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

    private func readChatGPTBaseURLFromConfig() -> String? {
        guard let raw = try? String(contentsOf: paths.codexConfigPath, encoding: .utf8), !raw.isEmpty else {
            return nil
        }

        for line in raw.split(whereSeparator: { $0.isNewline }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("chatgpt_base_url") else { continue }
            guard let equalIndex = trimmed.firstIndex(of: "=") else { continue }
            let value = trimmed[trimmed.index(after: equalIndex)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty {
                return value
            }
        }

        return nil
    }

    private func isAuthorized(_ headers: [String: String]) -> Bool {
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

    private func ensurePersistedAPIKey() throws -> String {
        if let key = try readPersistedAPIKey(), !key.isEmpty {
            return key
        }

        let generated = randomAPIKey()
        try persistAPIKey(generated)
        return generated
    }

    private func normalizedClientModelToken(_ model: String) -> String {
        model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func normalizedNumericModelRevisionIfNeeded(_ normalizedModel: String) -> String {
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

    private func readPersistedAPIKey() throws -> String? {
        guard FileManager.default.fileExists(atPath: paths.proxyDaemonKeyPath.path) else {
            return nil
        }

        let text = try String(contentsOf: paths.proxyDaemonKeyPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func persistAPIKey(_ value: String) throws {
        try FileManager.default.createDirectory(at: paths.proxyDaemonDataDirectory, withIntermediateDirectories: true)
        try value.write(to: paths.proxyDaemonKeyPath, atomically: true, encoding: .utf8)
        #if canImport(Darwin)
        _ = chmod(paths.proxyDaemonKeyPath.path, S_IRUSR | S_IWUSR)
        #endif
    }

    private func randomAPIKey() -> String {
        "sk-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    }

    private func waitForHealth(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        let deadline = Date().addingTimeInterval(6)

        while Date() < deadline {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    return true
                }
            } catch {
                // retry until timeout
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        return false
    }
}

private struct ProxyCandidate {
    var id: String
    var label: String
    var accountID: String
    var accessToken: String
    var authJSON: JSONValue
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

private struct UpstreamResponse {
    var statusCode: Int
    var body: Data
}

private struct SSEEvent {
    var event: String?
    var data: String
}

private enum RetryFailureCategory {
    case quotaExceeded
    case rateLimited
    case modelRestricted
    case authentication
    case permission
}

private struct RetryFailureInfo {
    var category: RetryFailureCategory
    var detail: String
}

private struct ErrorSignals {
    var normalized: String
    var brief: String
}

private struct ChatStreamState {
    var responseID: String
    var createdAt: Int
    var model: String
    var functionCallIndex: Int
    var hasReceivedArgumentsDelta: Bool
    var hasToolCallAnnounced: Bool
}
