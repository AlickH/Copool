import XCTest
@testable import Copool

final class SwiftNativeProxyRuntimeServiceTests: XCTestCase {
    func testDetectsUnsupportedReasoningSummaryNoneAsRetriable() {
        let body = """
        {"error":{"message":"Unsupported value: 'none' is not supported with the 'gpt-5.1-codex-max' model."}}
        """
        XCTAssertTrue(
            SwiftNativeProxyRuntimeService.shouldRetryWithAutoReasoningSummary(
                statusCode: 400,
                bodyText: body
            )
        )
        XCTAssertFalse(
            SwiftNativeProxyRuntimeService.shouldRetryWithAutoReasoningSummary(
                statusCode: 404,
                bodyText: body
            )
        )

        let quotedBody = """
        {"error":{"message":"Unsupported value: \\\"none\\\" for reasoning.summary"}}
        """
        XCTAssertTrue(
            SwiftNativeProxyRuntimeService.shouldRetryWithAutoReasoningSummary(
                statusCode: 400,
                bodyText: quotedBody
            )
        )
    }

    func testPromotesReasoningSummaryNoneToAuto() {
        let payload: [String: Any] = [
            "model": "gpt-5.1-codex-max",
            "reasoning": [
                "effort": "medium",
                "summary": "none"
            ]
        ]
        let adjusted = SwiftNativeProxyRuntimeService.payloadWithAutoReasoningSummaryIfNeeded(payload: payload)
        let reasoning = adjusted?["reasoning"] as? [String: Any]
        XCTAssertEqual(reasoning?["summary"] as? String, "auto")

        let payloadAuto: [String: Any] = [
            "model": "gpt-5.1-codex-max",
            "reasoning": [
                "summary": "auto"
            ]
        ]
        XCTAssertNil(
            SwiftNativeProxyRuntimeService.payloadWithAutoReasoningSummaryIfNeeded(payload: payloadAuto)
        )

        let payloadEffortNone: [String: Any] = [
            "model": "gpt-5.1-codex-max",
            "reasoning": [
                "effort": "none",
                "summary": "auto"
            ]
        ]
        let adjustedEffort = SwiftNativeProxyRuntimeService.payloadWithAutoReasoningSummaryIfNeeded(payload: payloadEffortNone)
        let adjustedReasoning = adjustedEffort?["reasoning"] as? [String: Any]
        XCTAssertEqual(adjustedReasoning?["effort"] as? String, "medium")
    }

    func testNormalizesReasoningSummaryForUpstream() {
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.normalizedReasoningSummaryForUpstream("none"),
            "auto"
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.normalizedReasoningSummaryForUpstream("  NONE "),
            "auto"
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.normalizedReasoningSummaryForUpstream(nil),
            "auto"
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.normalizedReasoningSummaryForUpstream("concise"),
            "concise"
        )
    }

    func testNormalizesReasoningEffortForUpstream() {
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.normalizedReasoningEffortForUpstream(
                "none",
                upstreamModel: "gpt-5.1-codex-max"
            ),
            "medium"
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.normalizedReasoningEffortForUpstream("HIGH"),
            "high"
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.normalizedReasoningEffortForUpstream(
                "xhigh",
                upstreamModel: "gpt-5.3-codex"
            ),
            "xhigh"
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.normalizedReasoningEffortForUpstream(
                "minimal",
                upstreamModel: "gpt-5.3-codex"
            ),
            "medium"
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.normalizedReasoningEffortForUpstream(
                "none",
                upstreamModel: "gpt-4.1"
            ),
            "none"
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.normalizedReasoningEffortForUpstream("unexpected"),
            "none"
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.normalizedReasoningEffortForUpstream(nil),
            "none"
        )
    }

    func testResolvesUpstreamRouteFamilyByModel() {
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.resolveUpstreamRouteFamily(forUpstreamModel: "gpt-5.4"),
            .codex
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.resolveUpstreamRouteFamily(forUpstreamModel: "gpt-5-4"),
            .codex
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.resolveUpstreamRouteFamily(forUpstreamModel: "gpt-5-codex-mini"),
            .codex
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.resolveUpstreamRouteFamily(forUpstreamModel: "gpt-5"),
            .codex
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.resolveUpstreamRouteFamily(forUpstreamModel: "gpt-5-mini"),
            .codex
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.resolveUpstreamRouteFamily(forUpstreamModel: "gpt-5.2"),
            .codex
        )
    }

    func testResolvesUpstreamBaseURLForBothRouteFamilies() {
        let codexFromOrigin = SwiftNativeProxyRuntimeService.resolveUpstreamBaseURL(
            configuredBaseURL: "https://chatgpt.com",
            routeFamily: .codex
        )
        XCTAssertEqual(codexFromOrigin, "https://chatgpt.com/backend-api/codex")

        let generalFromOrigin = SwiftNativeProxyRuntimeService.resolveUpstreamBaseURL(
            configuredBaseURL: "https://chatgpt.com",
            routeFamily: .general
        )
        XCTAssertEqual(generalFromOrigin, "https://chatgpt.com/backend-api")

        let codexFromResponses = SwiftNativeProxyRuntimeService.resolveUpstreamBaseURL(
            configuredBaseURL: "https://chatgpt.com/backend-api/codex/responses",
            routeFamily: .codex
        )
        XCTAssertEqual(codexFromResponses, "https://chatgpt.com/backend-api/codex")

        let generalFromResponses = SwiftNativeProxyRuntimeService.resolveUpstreamBaseURL(
            configuredBaseURL: "https://chatgpt.com/backend-api/responses",
            routeFamily: .general
        )
        XCTAssertEqual(generalFromResponses, "https://chatgpt.com/backend-api")
    }

    func testHealthAndModelsEndpoints() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key"),
            cloudflaredLogDirectory: tempDir.appendingPathComponent("cloudflared-logs", isDirectory: true)
        )

        let storeRepo = MockStoreRepository()
        let authRepo = MockAuthRepository()
        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: storeRepo,
            authRepository: authRepo
        )

        let port = Int.random(in: 21000...29000)
        let started = try await runtime.start(preferredPort: port)
        defer {
            Task { _ = await runtime.stop() }
        }

        XCTAssertTrue(started.running)
        XCTAssertEqual(started.port, port)
        XCTAssertNotNil(started.apiKey)
        XCTAssertTrue(started.apiKey?.hasPrefix("sk-") == true)

        let healthURL = URL(string: "http://127.0.0.1:\(port)/health")!
        let (healthData, healthResponse) = try await URLSession.shared.data(from: healthURL)
        XCTAssertEqual((healthResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try parseJSON(healthData)["ok"] as? Bool, true)

        let modelsURL = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        var modelsRequest = URLRequest(url: modelsURL)
        modelsRequest.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")
        let (modelsData, modelsResponse) = try await URLSession.shared.data(for: modelsRequest)
        XCTAssertEqual((modelsResponse as? HTTPURLResponse)?.statusCode, 200)

        let modelsJSON = try parseJSON(modelsData)
        let modelItems = modelsJSON["data"] as? [[String: Any]]
        XCTAssertNotNil(modelItems)
        XCTAssertTrue((modelItems?.count ?? 0) > 0)
        let ids = (modelItems ?? []).compactMap { $0["id"] as? String }
        XCTAssertTrue(ids.contains("gpt-5-4"))
        XCTAssertTrue(ids.contains("gpt-5.4"))
        XCTAssertTrue(ids.contains("gpt-5.3-codex"))
        XCTAssertTrue(ids.contains("gpt-5.2"))

        var modelsByAPIKeyHeader = URLRequest(url: modelsURL)
        modelsByAPIKeyHeader.setValue(started.apiKey ?? "", forHTTPHeaderField: "x-api-key")
        let (_, modelsByAPIKeyHeaderResponse) = try await URLSession.shared.data(for: modelsByAPIKeyHeader)
        XCTAssertEqual((modelsByAPIKeyHeaderResponse as? HTTPURLResponse)?.statusCode, 200)
    }

    func testStartKeepsLegacyPersistedAPIKey() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key"),
            cloudflaredLogDirectory: tempDir.appendingPathComponent("cloudflared-logs", isDirectory: true)
        )

        try FileManager.default.createDirectory(
            at: paths.proxyDaemonDataDirectory,
            withIntermediateDirectories: true
        )
        let legacyKey = "legacy-proxy-key"
        try legacyKey.write(to: paths.proxyDaemonKeyPath, atomically: true, encoding: .utf8)

        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: MockStoreRepository(),
            authRepository: MockAuthRepository()
        )

        let port = Int.random(in: 21000...29000)
        let started = try await runtime.start(preferredPort: port)
        defer {
            Task { _ = await runtime.stop() }
        }

        XCTAssertEqual(started.apiKey, legacyKey)
    }

    func testResponsesRejectsMissingModel() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key"),
            cloudflaredLogDirectory: tempDir.appendingPathComponent("cloudflared-logs", isDirectory: true)
        )

        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: MockStoreRepository(),
            authRepository: MockAuthRepository()
        )

        let port = Int.random(in: 30000...36000)
        let started = try await runtime.start(preferredPort: port)
        defer {
            Task { _ = await runtime.stop() }
        }

        let url = URL(string: "http://127.0.0.1:\(port)/v1/responses")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["input": "hello"])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)

        let json = try parseJSON(data)
        let error = json["error"] as? [String: Any]
        XCTAssertNotNil(error)
    }

    func testPayloadOversizeDetectionFromContentLengthHeader() {
        let oversized = ProxyRuntimeLimits.maxInboundRequestBytes + 1
        let raw = """
        POST /v1/responses HTTP/1.1\r
        Host: 127.0.0.1\r
        Content-Length: \(oversized)\r
        Content-Type: application/json\r
        \r
        {}
        """
        let buffer = Data(raw.utf8)
        XCTAssertTrue(SimpleHTTPServer.isPayloadOversized(buffer: buffer))
    }

    func testPayloadOversizeDetectionFromBufferedBytes() {
        let buffer = Data(repeating: 65, count: ProxyRuntimeLimits.maxInboundRequestBytes + 1)
        XCTAssertTrue(SimpleHTTPServer.isPayloadOversized(buffer: buffer))
    }

    func testPayloadOversizeDoesNotTriggerUnderLimit() {
        let allowed = ProxyRuntimeLimits.maxInboundRequestBytes - 128
        let raw = """
        POST /v1/responses HTTP/1.1\r
        Host: 127.0.0.1\r
        Content-Length: \(allowed)\r
        Content-Type: application/json\r
        \r
        {}
        """
        let buffer = Data(raw.utf8)
        XCTAssertFalse(SimpleHTTPServer.isPayloadOversized(buffer: buffer))
    }

    private func parseJSON(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }
}

private final class MockStoreRepository: AccountsStoreRepository, @unchecked Sendable {
    func loadStore() throws -> AccountsStore {
        AccountsStore()
    }

    func saveStore(_ store: AccountsStore) throws {
    }
}

private final class MockAuthRepository: AuthRepository, @unchecked Sendable {
    func readCurrentAuth() throws -> JSONValue { .null }
    func readCurrentAuthOptional() throws -> JSONValue? { nil }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return .null
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {}
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return .null
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        ExtractedAuth(accountID: "acct", accessToken: "token", email: nil, planType: nil, teamName: nil)
    }
    func currentAuthAccountID() -> String? { nil }
}
