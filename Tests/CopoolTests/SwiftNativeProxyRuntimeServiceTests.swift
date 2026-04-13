import XCTest
@testable import Copool

final class SwiftNativeProxyRuntimeServiceTests: XCTestCase {
    func testLoadCandidatesPrefersCurrentSelectionWhenUsageIsUnavailable() async throws {
        let runtime = makeRuntime(
            store: AccountsStore(
                accounts: [
                    makeStoredAccount(id: "a", label: "Account A", accountID: "acct-a", addedAt: 1),
                    makeStoredAccount(id: "b", label: "Account B", accountID: "acct-b", addedAt: 2)
                ],
                currentSelection: CurrentAccountSelection(
                    accountID: "acct-b",
                    selectedAt: 2,
                    sourceDeviceID: "macos-local",
                    accountKey: "acct-b|acct-b"
                )
            )
        )

        let candidates = try await runtime.withIsolation { runtime in
            try runtime.loadCandidates()
        }

        XCTAssertEqual(candidates.map(\.accountID), ["acct-b", "acct-a"])
    }

    func testLoadCandidatesUsesAddedAtAsStableTieBreakerForEqualScores() async throws {
        let runtime = makeRuntime(
            store: AccountsStore(
                accounts: [
                    makeStoredAccount(id: "later", label: "Later", accountID: "acct-later", addedAt: 20),
                    makeStoredAccount(id: "earlier", label: "Earlier", accountID: "acct-earlier", addedAt: 10)
                ]
            )
        )

        let candidates = try await runtime.withIsolation { runtime in
            try runtime.loadCandidates()
        }

        XCTAssertEqual(candidates.map(\.accountID), ["acct-earlier", "acct-later"])
    }

    func testCurrentCandidatesPrefersStickyAccountAfterSuccessfulSelection() async throws {
        let runtime = makeRuntime(
            store: AccountsStore(
                accounts: [
                    makeStoredAccount(id: "a", label: "Account A", accountID: "acct-a", addedAt: 1),
                    makeStoredAccount(id: "b", label: "Account B", accountID: "acct-b", addedAt: 2)
                ]
            )
        )

        let candidates = try await runtime.withIsolation { runtime in
            try runtime.recordSuccessfulCandidate(
                ProxyCandidate(
                    id: "b",
                    label: "Account B",
                    accountID: "acct-b",
                    accountKey: "acct-b|acct-b",
                    accessToken: "token-acct-b",
                    authJSON: .object([:]),
                    addedAt: 2,
                    isPreferredCurrent: false,
                    oneWeekUsed: nil,
                    fiveHourUsed: nil
                )
            )
            return try runtime.currentCandidates()
        }

        XCTAssertEqual(candidates.map(\.accountID), ["acct-b", "acct-a"])
    }

    func testCurrentCandidatesSkipsAccountInCooldownWindow() async throws {
        let runtime = makeRuntime(
            store: AccountsStore(
                accounts: [
                    makeStoredAccount(id: "a", label: "Account A", accountID: "acct-a", addedAt: 1),
                    makeStoredAccount(id: "b", label: "Account B", accountID: "acct-b", addedAt: 2)
                ]
            ),
            dateProvider: FixedDateProvider(unixSeconds: 100, unixMilliseconds: 100_000)
        )

        let candidates = try await runtime.withIsolation { runtime in
            runtime.markCooldown(for: "acct-a", category: .rateLimited)
            return try runtime.currentCandidates()
        }

        XCTAssertEqual(candidates.map(\.accountID), ["acct-b"])
    }

    func testPersistCurrentSelectionUsesSuccessfulCandidateAsCurrentSelection() async throws {
        let repository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    makeStoredAccount(id: "a", label: "Account A", accountID: "acct-a", addedAt: 1),
                ]
            )
        )
        let runtime = makeRuntime(
            storeRepository: repository,
            dateProvider: FixedDateProvider(unixSeconds: 100, unixMilliseconds: 123_456)
        )

        try await runtime.withIsolation { runtime in
            try runtime.persistCurrentSelection(
                for: ProxyCandidate(
                    id: "a",
                    label: "Account A",
                    accountID: "acct-a",
                    accountKey: "acct-a|acct-a",
                    accessToken: "token-acct-a",
                    authJSON: .object([:]),
                    addedAt: 1,
                    isPreferredCurrent: false,
                    oneWeekUsed: nil,
                    fiveHourUsed: nil
                )
            )
        }

        XCTAssertEqual(repository.store.currentSelection?.accountID, "acct-a")
        XCTAssertEqual(repository.store.currentSelection?.accountKey, "acct-a|acct-a")
        XCTAssertEqual(repository.store.currentSelection?.selectedAt, 123_456)
    }

    func testRecordSuccessfulCandidateSyncsCurrentAuthWhenAllowed() async throws {
        let authRepository = RecordingAuthRepository()
        let runtime = makeRuntime(
            storeRepository: InMemoryAccountsStoreRepository(
                store: AccountsStore(
                    accounts: [
                        makeStoredAccount(id: "a", label: "Account A", accountID: "acct-a", addedAt: 1)
                    ]
                )
            ),
            authRepository: authRepository
        )
        let candidate = ProxyCandidate(
            id: "a",
            label: "Account A",
            accountID: "acct-a",
            accountKey: "acct-a|acct-a",
            accessToken: "token-acct-a",
            authJSON: .object([
                "tokens": .object([
                    "access_token": .string("token-acct-a"),
                    "account_id": .string("acct-a")
                ])
            ]),
            addedAt: 1,
            isPreferredCurrent: false,
            oneWeekUsed: nil,
            fiveHourUsed: nil
        )

        try await runtime.withIsolation { runtime in
            try runtime.recordSuccessfulCandidate(candidate)
        }

        XCTAssertEqual(authRepository.writeCurrentAuthCallCount, 1)
    }

    func testRecordSuccessfulCandidateCallsStoreChangeHandler() async throws {
        let callback = StoreChangeCallback()
        let runtime = makeRuntime(
            storeRepository: InMemoryAccountsStoreRepository(
                store: AccountsStore(
                    accounts: [
                        makeStoredAccount(id: "a", label: "Account A", accountID: "acct-a", addedAt: 1)
                    ]
                )
            ),
            onAccountsStoreChanged: {
                callback.markCalled()
            }
        )
        let candidate = ProxyCandidate(
            id: "a",
            label: "Account A",
            accountID: "acct-a",
            accountKey: "acct-a|acct-a",
            accessToken: "token-acct-a",
            authJSON: .object([
                "tokens": .object([
                    "access_token": .string("token-acct-a"),
                    "account_id": .string("acct-a")
                ])
            ]),
            addedAt: 1,
            isPreferredCurrent: false,
            oneWeekUsed: nil,
            fiveHourUsed: nil
        )

        try await runtime.withIsolation { runtime in
            try runtime.recordSuccessfulCandidate(candidate)
        }

        let callbackCount = callback.readCallCount()
        XCTAssertEqual(callbackCount, 1)
    }

    func testRecordSuccessfulCandidatePropagatesAuthWriteFailure() async throws {
        let runtime = makeRuntime(
            storeRepository: InMemoryAccountsStoreRepository(
                store: AccountsStore(
                    accounts: [
                        makeStoredAccount(id: "a", label: "Account A", accountID: "acct-a", addedAt: 1)
                    ]
                )
            ),
            authRepository: FailingWriteAuthRepository()
        )
        let candidate = ProxyCandidate(
            id: "a",
            label: "Account A",
            accountID: "acct-a",
            accountKey: "acct-a|acct-a",
            accessToken: "token-acct-a",
            authJSON: .object([
                "tokens": .object([
                    "access_token": .string("token-acct-a"),
                    "account_id": .string("acct-a")
                ])
            ]),
            addedAt: 1,
            isPreferredCurrent: false,
            oneWeekUsed: nil,
            fiveHourUsed: nil
        )

        do {
            try await runtime.withIsolation { runtime in
                try runtime.recordSuccessfulCandidate(candidate)
            }
            XCTFail("Expected auth write failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "write failed")
        }
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

    func testHostAPIOnlyDisablesCurrentAuthSyncAfterSuccessfulProxyResponse() {
        XCTAssertFalse(
            SwiftNativeProxyRuntimeService.shouldSyncCurrentAuthOnSuccessfulProxyResponse(
                localProxyHostAPIOnly: true
            )
        )
        XCTAssertTrue(
            SwiftNativeProxyRuntimeService.shouldSyncCurrentAuthOnSuccessfulProxyResponse(
                localProxyHostAPIOnly: false
            )
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

    func testMapsDisplayModelNamesToUpstream() async throws {
        let runtime = SwiftNativeProxyRuntimeService(
            paths: FileSystemPaths(
                applicationSupportDirectory: URL(fileURLWithPath: "/tmp"),
                accountStorePath: URL(fileURLWithPath: "/tmp/accounts.json"),
                settingsStorePath: URL(fileURLWithPath: "/tmp/settings.json"),
                codexAuthPath: URL(fileURLWithPath: "/tmp/auth.json"),
                codexConfigPath: URL(fileURLWithPath: "/tmp/config.toml"),
                proxyDaemonDataDirectory: URL(fileURLWithPath: "/tmp/proxyd", isDirectory: true),
                proxyDaemonKeyPath: URL(fileURLWithPath: "/tmp/proxyd/api-proxy.key"),
                cloudflaredLogDirectory: URL(fileURLWithPath: "/tmp/cloudflared-logs", isDirectory: true)
            ),
            storeRepository: MockStoreRepository(),
            settingsRepository: MockSettingsRepository(),
            authRepository: MockAuthRepository()
        )

        let mapped = try await runtime.withIsolation { runtime in
            (
                try runtime.mapClientModelToUpstream("GPT-5.4"),
                try runtime.mapClientModelToUpstream("GPT-5.4-Mini"),
                try runtime.mapClientModelToUpstream("GPT-5.3-Codex")
            )
        }

        XCTAssertEqual(mapped.0, "gpt-5.4")
        XCTAssertEqual(mapped.1, "gpt-5.4-mini")
        XCTAssertEqual(mapped.2, "gpt-5.3-codex")
    }

    func testMapsDisplayModelAliasNamesToUpstream() async throws {
        let runtime = SwiftNativeProxyRuntimeService(
            paths: FileSystemPaths(
                applicationSupportDirectory: URL(fileURLWithPath: "/tmp"),
                accountStorePath: URL(fileURLWithPath: "/tmp/accounts.json"),
                settingsStorePath: URL(fileURLWithPath: "/tmp/settings.json"),
                codexAuthPath: URL(fileURLWithPath: "/tmp/auth.json"),
                codexConfigPath: URL(fileURLWithPath: "/tmp/config.toml"),
                proxyDaemonDataDirectory: URL(fileURLWithPath: "/tmp/proxyd", isDirectory: true),
                proxyDaemonKeyPath: URL(fileURLWithPath: "/tmp/proxyd/api-proxy.key"),
                cloudflaredLogDirectory: URL(fileURLWithPath: "/tmp/cloudflared-logs", isDirectory: true)
            ),
            storeRepository: MockStoreRepository(),
            settingsRepository: MockSettingsRepository(),
            authRepository: MockAuthRepository()
        )

        let mapped = try await runtime.withIsolation { runtime in
            (
                try runtime.mapClientModelToUpstream("GPT-5.4-Low"),
                try runtime.mapClientModelToUpstream("GPT-5.4-High"),
                try runtime.mapClientModelToUpstream("GPT-5.4-Mini-High"),
                try runtime.mapClientModelToUpstream("GPT-5.4-Mini-xHigh"),
                try runtime.mapClientModelToUpstream("GPT-5.3-Codex-Medium")
            )
        }

        XCTAssertEqual(mapped.0, "gpt-5.4")
        XCTAssertEqual(mapped.1, "gpt-5.4")
        XCTAssertEqual(mapped.2, "gpt-5.4-mini")
        XCTAssertEqual(mapped.3, "gpt-5.4-mini")
        XCTAssertEqual(mapped.4, "gpt-5.3-codex")
    }

    func testNormalizesUpstreamModelsForClientDisplay() async {
        let runtime = SwiftNativeProxyRuntimeService(
            paths: FileSystemPaths(
                applicationSupportDirectory: URL(fileURLWithPath: "/tmp"),
                accountStorePath: URL(fileURLWithPath: "/tmp/accounts.json"),
                settingsStorePath: URL(fileURLWithPath: "/tmp/settings.json"),
                codexAuthPath: URL(fileURLWithPath: "/tmp/auth.json"),
                codexConfigPath: URL(fileURLWithPath: "/tmp/config.toml"),
                proxyDaemonDataDirectory: URL(fileURLWithPath: "/tmp/proxyd", isDirectory: true),
                proxyDaemonKeyPath: URL(fileURLWithPath: "/tmp/proxyd/api-proxy.key"),
                cloudflaredLogDirectory: URL(fileURLWithPath: "/tmp/cloudflared-logs", isDirectory: true)
            ),
            storeRepository: MockStoreRepository(),
            settingsRepository: MockSettingsRepository(),
            authRepository: MockAuthRepository()
        )

        let normalized = await runtime.withIsolation { runtime in
            (
                runtime.normalizeModelForClient("gpt-5"),
                runtime.normalizeModelForClient("gpt-5.3-codex"),
                runtime.normalizeModelForClient("gpt-5-4"),
                runtime.normalizeModelForClient("gpt-5-4-mini"),
                runtime.normalizeModelForClient("gpt-5-4-xhigh"),
                runtime.normalizeModelForClient("gpt5.4-2026-03-09")
            )
        }

        XCTAssertEqual(normalized.0, "GPT-5")
        XCTAssertEqual(normalized.1, "GPT-5.3-Codex")
        XCTAssertEqual(normalized.2, "GPT-5.4")
        XCTAssertEqual(normalized.3, "GPT-5.4-Mini")
        XCTAssertEqual(normalized.4, "GPT-5.4-xHigh")
        XCTAssertEqual(normalized.5, "GPT-5.4-2026-03-09")
    }

    func testClientVisibleModelsIncludeReasoningAliasNames() {
        XCTAssertTrue(SwiftNativeProxyRuntimeService.clientVisibleModels.contains("GPT-5.4-Low"))
        XCTAssertTrue(SwiftNativeProxyRuntimeService.clientVisibleModels.contains("GPT-5.4-High"))
        XCTAssertTrue(SwiftNativeProxyRuntimeService.clientVisibleModels.contains("GPT-5.4-Mini-High"))
        XCTAssertTrue(SwiftNativeProxyRuntimeService.clientVisibleModels.contains("GPT-5.4-Mini-xHigh"))
        XCTAssertTrue(SwiftNativeProxyRuntimeService.clientVisibleModels.contains("GPT-5.3-Codex-xHigh"))
        XCTAssertTrue(SwiftNativeProxyRuntimeService.clientVisibleModels.contains("GPT-5.3-Codex-Medium"))
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
            settingsStorePath: tempDir.appendingPathComponent("settings.json"),
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
            settingsRepository: MockSettingsRepository(),
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
        XCTAssertEqual(ids, SwiftNativeProxyRuntimeService.clientVisibleModels)

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
            settingsStorePath: tempDir.appendingPathComponent("settings.json"),
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

        let account = StoredAccount(
            id: "acct-1",
            label: "Primary",
            email: nil,
            accountID: "account-1",
            planType: nil,
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([
                "tokens": .object([
                    "access_token": .string("token"),
                    "id_token": .string("id-token"),
                    "account_id": .string("account-1")
                ])
            ]),
            addedAt: 1,
            updatedAt: 1,
            usage: nil,
            usageError: nil
        )
        let storeRepository = CountingStoreRepository(store: AccountsStore(accounts: [account]))
        let authRepository = CountingAuthRepository()
        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: storeRepository,
            settingsRepository: MockSettingsRepository(),
            authRepository: authRepository
        )

        let port = Int.random(in: 21000...29000)
        let started = try await runtime.start(preferredPort: port)
        defer {
            Task { _ = await runtime.stop() }
        }

        XCTAssertEqual(started.apiKey, legacyKey)

        let firstStatus = await runtime.status()
        let secondStatus = await runtime.status()

        XCTAssertEqual(firstStatus.availableAccounts, 1)
        XCTAssertEqual(secondStatus.availableAccounts, 1)
        XCTAssertEqual(storeRepository.loadStoreCallCount, 1)
        XCTAssertEqual(authRepository.extractAuthCallCount, 1)
    }

    func testResponsesRejectsMissingModel() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            settingsStorePath: tempDir.appendingPathComponent("settings.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key"),
            cloudflaredLogDirectory: tempDir.appendingPathComponent("cloudflared-logs", isDirectory: true)
        )

        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: MockStoreRepository(),
            settingsRepository: MockSettingsRepository(),
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

    func testResponsesNormalizesStringInputToMessageArray() async throws {
        let runtime = SwiftNativeProxyRuntimeService(
            paths: FileSystemPaths(
                applicationSupportDirectory: URL(fileURLWithPath: "/tmp"),
                accountStorePath: URL(fileURLWithPath: "/tmp/accounts.json"),
                settingsStorePath: URL(fileURLWithPath: "/tmp/settings.json"),
                codexAuthPath: URL(fileURLWithPath: "/tmp/auth.json"),
                codexConfigPath: URL(fileURLWithPath: "/tmp/config.toml"),
                proxyDaemonDataDirectory: URL(fileURLWithPath: "/tmp/proxyd", isDirectory: true),
                proxyDaemonKeyPath: URL(fileURLWithPath: "/tmp/proxyd/api-proxy.key"),
                cloudflaredLogDirectory: URL(fileURLWithPath: "/tmp/cloudflared-logs", isDirectory: true)
            ),
            storeRepository: MockStoreRepository(),
            settingsRepository: MockSettingsRepository(),
            authRepository: MockAuthRepository()
        )

        let normalized = try await runtime.withIsolation { runtime in
            snapshot(
                from: try runtime.normalizeResponsesRequest([
                "model": "gpt-5.4",
                "input": "reply with exactly OK",
                "stream": false
                ])
            )
        }

        XCTAssertEqual(normalized.downstreamStream, false)
        XCTAssertEqual(normalized.model, "gpt-5.4")
        XCTAssertEqual(normalized.stream, true)
        XCTAssertEqual(normalized.input.count, 1)
        XCTAssertEqual(normalized.input[0].type, "message")
        XCTAssertEqual(normalized.input[0].role, "user")
        XCTAssertEqual(normalized.input[0].content.count, 1)
        XCTAssertEqual(normalized.input[0].content[0].type, "input_text")
        XCTAssertEqual(normalized.input[0].content[0].text, "reply with exactly OK")
    }

    func testResponsesNormalizationDropsUnsupportedForwardingFields() async throws {
        let runtime = SwiftNativeProxyRuntimeService(
            paths: FileSystemPaths(
                applicationSupportDirectory: URL(fileURLWithPath: "/tmp"),
                accountStorePath: URL(fileURLWithPath: "/tmp/accounts.json"),
                settingsStorePath: URL(fileURLWithPath: "/tmp/settings.json"),
                codexAuthPath: URL(fileURLWithPath: "/tmp/auth.json"),
                codexConfigPath: URL(fileURLWithPath: "/tmp/config.toml"),
                proxyDaemonDataDirectory: URL(fileURLWithPath: "/tmp/proxyd", isDirectory: true),
                proxyDaemonKeyPath: URL(fileURLWithPath: "/tmp/proxyd/api-proxy.key"),
                cloudflaredLogDirectory: URL(fileURLWithPath: "/tmp/cloudflared-logs", isDirectory: true)
            ),
            storeRepository: MockStoreRepository(),
            settingsRepository: MockSettingsRepository(),
            authRepository: MockAuthRepository()
        )

        let retainedUnsupportedKeys = try await runtime.withIsolation { runtime in
            let normalized = try runtime.normalizeResponsesRequest([
                "model": "gpt-5.4",
                "input": [[
                    "role": "user",
                    "content": [[
                        "type": "input_text",
                        "text": "hello"
                    ]]
                ]],
                "prompt_cache_key": "factory-droid",
                "prompt_cache_retention": "24h",
                "safety_identifier": "user-123",
                "service_tier": "auto"
            ])
            return [
                "prompt_cache_key",
                "prompt_cache_retention",
                "safety_identifier",
                "service_tier"
            ].filter { normalized.payload[$0] != nil }
        }

        XCTAssertEqual(retainedUnsupportedKeys, [])
    }

    func testResponsesNormalizationInjectsReasoningEffortFromModelAlias() async throws {
        let runtime = SwiftNativeProxyRuntimeService(
            paths: FileSystemPaths(
                applicationSupportDirectory: URL(fileURLWithPath: "/tmp"),
                accountStorePath: URL(fileURLWithPath: "/tmp/accounts.json"),
                settingsStorePath: URL(fileURLWithPath: "/tmp/settings.json"),
                codexAuthPath: URL(fileURLWithPath: "/tmp/auth.json"),
                codexConfigPath: URL(fileURLWithPath: "/tmp/config.toml"),
                proxyDaemonDataDirectory: URL(fileURLWithPath: "/tmp/proxyd", isDirectory: true),
                proxyDaemonKeyPath: URL(fileURLWithPath: "/tmp/proxyd/api-proxy.key"),
                cloudflaredLogDirectory: URL(fileURLWithPath: "/tmp/cloudflared-logs", isDirectory: true)
            ),
            storeRepository: MockStoreRepository(),
            settingsRepository: MockSettingsRepository(),
            authRepository: MockAuthRepository()
        )

        let normalizedReasoningEffort = try await runtime.withIsolation { runtime in
            let normalized = try runtime.normalizeResponsesRequest([
                "model": "GPT-5.4-High",
                "input": "hello"
            ])
            return (normalized.payload["reasoning"] as? [String: Any])?["effort"] as? String
        }

        let normalizedReasoningSummary = try await runtime.withIsolation { runtime in
            let normalized = try runtime.normalizeResponsesRequest([
                "model": "GPT-5.4-High",
                "input": "hello"
            ])
            return (normalized.payload["reasoning"] as? [String: Any])?["summary"] as? String
        }

        XCTAssertEqual(normalizedReasoningEffort, "high")
        XCTAssertEqual(normalizedReasoningSummary, "auto")
    }

    func testResponsesNormalizationKeepsExplicitReasoningEffortOverAliasDefault() async throws {
        let runtime = SwiftNativeProxyRuntimeService(
            paths: FileSystemPaths(
                applicationSupportDirectory: URL(fileURLWithPath: "/tmp"),
                accountStorePath: URL(fileURLWithPath: "/tmp/accounts.json"),
                settingsStorePath: URL(fileURLWithPath: "/tmp/settings.json"),
                codexAuthPath: URL(fileURLWithPath: "/tmp/auth.json"),
                codexConfigPath: URL(fileURLWithPath: "/tmp/config.toml"),
                proxyDaemonDataDirectory: URL(fileURLWithPath: "/tmp/proxyd", isDirectory: true),
                proxyDaemonKeyPath: URL(fileURLWithPath: "/tmp/proxyd/api-proxy.key"),
                cloudflaredLogDirectory: URL(fileURLWithPath: "/tmp/cloudflared-logs", isDirectory: true)
            ),
            storeRepository: MockStoreRepository(),
            settingsRepository: MockSettingsRepository(),
            authRepository: MockAuthRepository()
        )

        let normalizedReasoningEffort = try await runtime.withIsolation { runtime in
            let normalized = try runtime.normalizeResponsesRequest([
                "model": "GPT-5.4-High",
                "input": "hello",
                "reasoning": [
                    "effort": "low"
                ]
            ])
            return (normalized.payload["reasoning"] as? [String: Any])?["effort"] as? String
        }

        XCTAssertEqual(normalizedReasoningEffort, "low")
    }

    func testChatConversionInjectsReasoningEffortFromModelAlias() async throws {
        let runtime = SwiftNativeProxyRuntimeService(
            paths: FileSystemPaths(
                applicationSupportDirectory: URL(fileURLWithPath: "/tmp"),
                accountStorePath: URL(fileURLWithPath: "/tmp/accounts.json"),
                settingsStorePath: URL(fileURLWithPath: "/tmp/settings.json"),
                codexAuthPath: URL(fileURLWithPath: "/tmp/auth.json"),
                codexConfigPath: URL(fileURLWithPath: "/tmp/config.toml"),
                proxyDaemonDataDirectory: URL(fileURLWithPath: "/tmp/proxyd", isDirectory: true),
                proxyDaemonKeyPath: URL(fileURLWithPath: "/tmp/proxyd/api-proxy.key"),
                cloudflaredLogDirectory: URL(fileURLWithPath: "/tmp/cloudflared-logs", isDirectory: true)
            ),
            storeRepository: MockStoreRepository(),
            settingsRepository: MockSettingsRepository(),
            authRepository: MockAuthRepository()
        )

        let normalizedReasoningEffort = try await runtime.withIsolation { runtime in
            let normalized = try runtime.convertChatRequestToResponses([
                "model": "GPT-5.3-Codex-High",
                "messages": [
                    [
                        "role": "user",
                        "content": "hello"
                    ]
                ]
            ])
            return (normalized.payload["reasoning"] as? [String: Any])?["effort"] as? String
        }

        XCTAssertEqual(normalizedReasoningEffort, "high")
    }

    func testStreamingChatTranslatorEmitsChunksIncrementally() async throws {
        let runtime = makeRuntime(store: AccountsStore())
        let decoder = await runtime.withIsolation { runtime in
            runtime.makeChatCompletionsSSEStreamDecoder(fallbackModel: "gpt-5")
        }

        let firstChunkCount = try await runtime.withIsolation { runtime in
            let chunks = try runtime.consumeChatCompletionsSSEStreamChunk(
                decoder,
                data: Data("""
                event: response.created
                data: {"type":"response.created","response":{"id":"resp_123","created_at":1,"model":"gpt-5"}}

                event: response.output_text.delta
                data: {"type":"response.output_text.delta","delta":"Hel
                """.utf8),
                isFinal: false
            )
            return chunks.count
        }
        XCTAssertEqual(firstChunkCount, 0)

        let secondSnapshot = try await runtime.withIsolation { runtime in
            let chunks = try runtime.consumeChatCompletionsSSEStreamChunk(
                decoder,
                data: Data("""
                lo"}

                event: response.completed
                data: {"type":"response.completed","response":{"id":"resp_123","created_at":1,"model":"gpt-5","status":"completed"}}

                """.utf8),
                isFinal: true
            )
            let firstContent = ((chunks[0]["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])?["content"] as? String
            let finishReason = ((chunks[1]["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String)
            return StreamedChatChunkSnapshot(
                chunkCount: chunks.count,
                firstContent: firstContent,
                finishReason: finishReason
            )
        }

        XCTAssertEqual(secondSnapshot.chunkCount, 2)
        XCTAssertEqual(secondSnapshot.firstContent, "Hello")
        XCTAssertEqual(secondSnapshot.finishReason, "stop")
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

    private func makeRuntime(
        store: AccountsStore,
        dateProvider: DateProviding = SystemDateProvider()
    ) -> SwiftNativeProxyRuntimeService {
        makeRuntime(
            storeRepository: CountingStoreRepository(store: store),
            authRepository: ExtractingAuthRepository(),
            onAccountsStoreChanged: nil,
            dateProvider: dateProvider
        )
    }

    private func makeRuntime(
        storeRepository: AccountsStoreRepository,
        authRepository: AuthRepository = ExtractingAuthRepository(),
        onAccountsStoreChanged: (@Sendable () -> Void)? = nil,
        dateProvider: DateProviding = SystemDateProvider()
    ) -> SwiftNativeProxyRuntimeService {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return SwiftNativeProxyRuntimeService(
            paths: FileSystemPaths(
                applicationSupportDirectory: tempDir,
                accountStorePath: tempDir.appendingPathComponent("accounts.json"),
                settingsStorePath: tempDir.appendingPathComponent("settings.json"),
                codexAuthPath: tempDir.appendingPathComponent("auth.json"),
                codexConfigPath: tempDir.appendingPathComponent("config.toml"),
                proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
                proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key"),
                cloudflaredLogDirectory: tempDir.appendingPathComponent("cloudflared-logs", isDirectory: true)
            ),
            storeRepository: storeRepository,
            settingsRepository: MockSettingsRepository(),
            authRepository: authRepository,
            onAccountsStoreChanged: onAccountsStoreChanged,
            dateProvider: dateProvider
        )
    }

    private func makeStoredAccount(
        id: String,
        label: String,
        accountID: String,
        addedAt: Int64
    ) -> StoredAccount {
        StoredAccount(
            id: id,
            label: label,
            email: nil,
            accountID: accountID,
            planType: nil,
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([
                "tokens": .object([
                    "access_token": .string("token-\(accountID)"),
                    "account_id": .string(accountID)
                ])
            ]),
            addedAt: addedAt,
            updatedAt: addedAt,
            usage: nil,
            usageError: nil
        )
    }
}

private struct FixedDateProvider: DateProviding {
    let unixSeconds: Int64
    let unixMilliseconds: Int64

    func unixSecondsNow() -> Int64 { unixSeconds }
    func unixMillisecondsNow() -> Int64 { unixMilliseconds }
}

private final class InMemoryAccountsStoreRepository: AccountsStoreRepository, @unchecked Sendable {
    var store: AccountsStore

    init(store: AccountsStore) {
        self.store = store
    }

    func loadStore() throws -> AccountsStore {
        store
    }

    func saveStore(_ store: AccountsStore) throws {
        self.store = store
    }
}

private final class MockStoreRepository: AccountsStoreRepository, @unchecked Sendable {
    func loadStore() throws -> AccountsStore {
        AccountsStore()
    }

    func saveStore(_ store: AccountsStore) throws {
    }
}

private final class CountingStoreRepository: AccountsStoreRepository, @unchecked Sendable {
    private let store: AccountsStore
    private(set) var loadStoreCallCount = 0

    init(store: AccountsStore) {
        self.store = store
    }

    func loadStore() throws -> AccountsStore {
        loadStoreCallCount += 1
        return store
    }

    func saveStore(_ store: AccountsStore) throws {
        _ = store
    }
}

private final class MockSettingsRepository: SettingsRepository, @unchecked Sendable {
    func loadSettings() throws -> AppSettings {
        .defaultValue
    }

    func saveSettings(_ settings: AppSettings) throws {
        _ = settings
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
}

private final class CountingAuthRepository: AuthRepository, @unchecked Sendable {
    private(set) var extractAuthCallCount = 0

    func readCurrentAuth() throws -> JSONValue { .null }
    func readCurrentAuthOptional() throws -> JSONValue? { nil }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return .null
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {
        _ = auth
    }
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return .null
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        _ = auth
        extractAuthCallCount += 1
        return ExtractedAuth(accountID: "acct", accessToken: "token", email: nil, planType: nil, teamName: nil)
    }
}

private final class RecordingAuthRepository: AuthRepository, @unchecked Sendable {
    private(set) var writeCurrentAuthCallCount = 0

    func readCurrentAuth() throws -> JSONValue { .null }
    func readCurrentAuthOptional() throws -> JSONValue? { nil }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return .null
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {
        _ = auth
        writeCurrentAuthCallCount += 1
    }
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return .null
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        guard case .object(let root) = auth,
              case .object(let tokens)? = root["tokens"],
              case .string(let accountID)? = tokens["account_id"],
              case .string(let accessToken)? = tokens["access_token"] else {
            throw AppError.invalidData("Missing test auth payload")
        }

        return ExtractedAuth(
            accountID: accountID,
            accessToken: accessToken,
            email: nil,
            planType: nil,
            teamName: nil
        )
    }
}

private final class FailingWriteAuthRepository: AuthRepository, @unchecked Sendable {
    func readCurrentAuth() throws -> JSONValue { .null }
    func readCurrentAuthOptional() throws -> JSONValue? { nil }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return .null
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {
        _ = auth
        throw AppError.io("write failed")
    }
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return .null
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        guard case .object(let root) = auth,
              case .object(let tokens)? = root["tokens"],
              case .string(let accountID)? = tokens["account_id"],
              case .string(let accessToken)? = tokens["access_token"] else {
            throw AppError.invalidData("Missing test auth payload")
        }

        return ExtractedAuth(
            accountID: accountID,
            accessToken: accessToken,
            email: nil,
            planType: nil,
            teamName: nil
        )
    }
}

private final class StoreChangeCallback: @unchecked Sendable {
    private var callCount = 0

    func markCalled() {
        callCount += 1
    }

    func readCallCount() -> Int {
        callCount
    }
}

private final class ExtractingAuthRepository: AuthRepository, @unchecked Sendable {
    func readCurrentAuth() throws -> JSONValue { .null }
    func readCurrentAuthOptional() throws -> JSONValue? { nil }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return .null
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {
        _ = auth
    }
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return .null
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        guard case .object(let root) = auth,
              case .object(let tokens)? = root["tokens"],
              case .string(let accountID)? = tokens["account_id"],
              case .string(let accessToken)? = tokens["access_token"] else {
            throw AppError.invalidData("Missing test auth payload")
        }

        return ExtractedAuth(
            accountID: accountID,
            accessToken: accessToken,
            email: nil,
            planType: nil,
            teamName: nil
        )
    }
}

private struct NormalizedResponsesSnapshot: Sendable {
    let downstreamStream: Bool
    let model: String?
    let stream: Bool?
    let input: [NormalizedInputMessage]
}

private struct StreamedChatChunkSnapshot: Sendable {
    let chunkCount: Int
    let firstContent: String?
    let finishReason: String?
}

private struct NormalizedInputMessage: Sendable {
    let type: String?
    let role: String?
    let content: [NormalizedInputContent]
}

private struct NormalizedInputContent: Sendable {
    let type: String?
    let text: String?
}

private extension SwiftNativeProxyRuntimeService {
    func withIsolation<T: Sendable>(
        _ body: @Sendable (isolated SwiftNativeProxyRuntimeService) throws -> T
    ) async rethrows -> T {
        try body(self)
    }
}

private func snapshot(
    from normalized: (payload: [String: Any], downstreamStream: Bool)
) -> NormalizedResponsesSnapshot {
    let input = (normalized.payload["input"] as? [[String: Any]] ?? []).map { message in
        NormalizedInputMessage(
            type: message["type"] as? String,
            role: message["role"] as? String,
            content: (message["content"] as? [[String: Any]] ?? []).map { item in
                NormalizedInputContent(
                    type: item["type"] as? String,
                    text: item["text"] as? String
                )
            }
        )
    }

    return NormalizedResponsesSnapshot(
        downstreamStream: normalized.downstreamStream,
        model: normalized.payload["model"] as? String,
        stream: normalized.payload["stream"] as? Bool,
        input: input
    )
}
