import XCTest
@testable import Copool

final class AuthFileRepositoryTests: XCTestCase {
    func testExtractAuthReadsAccountAndClaims() throws {
        let fixture = try makeRepositoryFixture()
        defer { fixture.cleanup() }

        let repository = fixture.repository
        let token = makeJWT(payload: [
            "email": "dev@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_12345",
                "chatgpt_plan_type": "pro",
                "chatgpt_team_name": "Alpha Team"
            ]
        ])

        let auth = JSONValue.object([
            "auth_mode": .string("chatgpt"),
            "tokens": .object([
                "access_token": .string("access-token"),
                "id_token": .string(token)
            ])
        ])

        let extracted = try repository.extractAuth(from: auth)

        XCTAssertEqual(extracted.accountID, "acct_12345")
        XCTAssertEqual(extracted.email, "dev@example.com")
        XCTAssertEqual(extracted.planType, "pro")
        XCTAssertEqual(extracted.teamName, "Alpha Team")
        XCTAssertEqual(extracted.accessToken, "access-token")
    }

    func testExtractAuthPrefersNonPersonalWorkspaceSlug() throws {
        let fixture = try makeRepositoryFixture()
        defer { fixture.cleanup() }

        let repository = fixture.repository
        let token = makeJWT(payload: [
            "email": "dev@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_12345",
                "chatgpt_plan_type": "team",
                "active_organization_id": "org-team",
                "organizations": [
                    [
                        "id": "org-personal",
                        "is_default": true,
                        "title": "Personal",
                        "slug": "personal"
                    ],
                    [
                        "id": "org-team",
                        "is_active": true,
                        "title": "Team Workspace",
                        "slug": "kqikiy"
                    ]
                ]
            ]
        ])

        let auth = JSONValue.object([
            "auth_mode": .string("chatgpt"),
            "tokens": .object([
                "access_token": .string("access-token"),
                "id_token": .string(token)
            ])
        ])

        let extracted = try repository.extractAuth(from: auth)

        XCTAssertEqual(extracted.accountID, "acct_12345")
        XCTAssertEqual(extracted.planType, "team")
        XCTAssertEqual(extracted.teamName, "kqikiy")
    }

    func testExtractAuthResolvesPrincipalIDFromJWTSubject() throws {
        let fixture = try makeRepositoryFixture()
        defer { fixture.cleanup() }

        let repository = fixture.repository
        let token = makeJWT(payload: [
            "sub": "user_123",
            "email": "dev@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_12345"
            ]
        ])

        let auth = JSONValue.object([
            "auth_mode": .string("chatgpt"),
            "tokens": .object([
                "access_token": .string("access-token"),
                "id_token": .string(token)
            ])
        ])

        let extracted = try repository.extractAuth(from: auth)

        XCTAssertEqual(extracted.principalID, "user_123")
        XCTAssertEqual(extracted.accountKey, "user_123|acct_12345")
    }

    func testExtractAuthIgnoresWorkspaceContainersInUnrelatedNestedObjects() throws {
        let fixture = try makeRepositoryFixture()
        defer { fixture.cleanup() }

        let repository = fixture.repository
        let token = makeJWT(payload: [
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_12345",
                "chatgpt_plan_type": "team"
            ]
        ])

        let auth = JSONValue.object([
            "auth_mode": .string("chatgpt"),
            "tokens": .object([
                "access_token": .string("access-token"),
                "id_token": .string(token)
            ]),
            "analytics": .object([
                "organizations": .array([
                    .object([
                        "id": .string("org-shadow"),
                        "is_active": .bool(true),
                        "slug": .string("shadow-workspace"),
                        "title": .string("Shadow Workspace")
                    ])
                ])
            ])
        ])

        let extracted = try repository.extractAuth(from: auth)

        XCTAssertEqual(extracted.accountID, "acct_12345")
        XCTAssertEqual(extracted.planType, "team")
        XCTAssertNil(extracted.teamName)
    }

    func testMakeChatGPTAuthBuildsCodexCompatibleShape() throws {
        let fixture = try makeRepositoryFixture()
        defer { fixture.cleanup() }

        let repository = fixture.repository
        let idToken = makeJWT(payload: [
            "email": "dev@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_67890",
                "chatgpt_plan_type": "plus"
            ]
        ])

        let auth = try repository.makeChatGPTAuth(from: ChatGPTOAuthTokens(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: idToken,
            apiKey: "sk-proj-test"
        ))

        XCTAssertEqual(auth["auth_mode"]?.stringValue, "chatgpt")
        XCTAssertEqual(auth["OPENAI_API_KEY"]?.stringValue, "sk-proj-test")
        XCTAssertEqual(auth["tokens"]?["access_token"]?.stringValue, "access-token")
        XCTAssertEqual(auth["tokens"]?["refresh_token"]?.stringValue, "refresh-token")
        XCTAssertEqual(auth["tokens"]?["id_token"]?.stringValue, idToken)
        XCTAssertEqual(auth["tokens"]?["account_id"]?.stringValue, "acct_67890")
        XCTAssertNotNil(auth["last_refresh"]?.stringValue)
    }

    func testExchangeAuthFromRefreshTokenBuildsCodexCompatibleShape() async throws {
        let idToken = makeJWT(payload: [
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_refresh_123",
                "chatgpt_plan_type": "plus"
            ]
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthFileRepositoryMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        await AuthFileRepositoryMockURLProtocol.store.setHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://auth.openai.com/oauth/token")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = Self.requestBodyString(from: request)
            XCTAssertTrue(body?.contains("grant_type=refresh_token") == true)
            XCTAssertTrue(body?.contains("refresh_token=rt_source_123") == true)

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = try JSONSerialization.data(withJSONObject: [
                "access_token": "access-refresh-123",
                "id_token": idToken,
                "refresh_token": "rt_rotated_456"
            ])
            return (response, data)
        }

        let fixture = try makeRepositoryFixture(session: session)
        defer { fixture.cleanup() }

        let auth = try await fixture.repository.exchangeAuth(email: "refresh@example.com", refreshToken: "rt_source_123")

        XCTAssertEqual(auth["auth_mode"]?.stringValue, "chatgpt")
        XCTAssertEqual(auth["email"]?.stringValue, "refresh@example.com")
        XCTAssertEqual(auth["tokens"]?["access_token"]?.stringValue, "access-refresh-123")
        XCTAssertEqual(auth["tokens"]?["id_token"]?.stringValue, idToken)
        XCTAssertEqual(auth["tokens"]?["refresh_token"]?.stringValue, "rt_rotated_456")
        XCTAssertEqual(auth["tokens"]?["account_id"]?.stringValue, "acct_refresh_123")
        XCTAssertNotNil(auth["last_refresh"]?.stringValue)
    }

    func testExtractAuthFallsBackToTopLevelEmail() throws {
        let fixture = try makeRepositoryFixture()
        defer { fixture.cleanup() }

        let repository = fixture.repository
        let token = makeJWT(payload: [
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_12345"
            ]
        ])

        let auth = JSONValue.object([
            "auth_mode": .string("chatgpt"),
            "email": .string("fallback@example.com"),
            "tokens": .object([
                "access_token": .string("access-token"),
                "id_token": .string(token)
            ])
        ])

        let extracted = try repository.extractAuth(from: auth)

        XCTAssertEqual(extracted.email, "fallback@example.com")
    }

    func testWriteCurrentAuthNormalizesFlatTokenShapeAndTimestamp() throws {
        let fixture = try makeRepositoryFixture()
        defer { fixture.cleanup() }

        let repository = fixture.repository
        let idToken = makeJWT(payload: [
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_98765"
            ]
        ])
        let auth = JSONValue.object([
            "access_token": .string("access-token"),
            "refresh_token": .string("refresh-token"),
            "id_token": .string(idToken),
            "account_id": .string("acct_98765"),
            "last_refresh": .string("2026-03-19T12:57:06.735503"),
            "organization": .object([
                "name": .string("workspace-alpha")
            ]),
            "OPENAI_API_KEY": .string("sk-proj-test")
        ])

        try repository.writeCurrentAuth(auth)
        let written = try repository.readCurrentAuth()

        XCTAssertNil(written["access_token"])
        XCTAssertNil(written["refresh_token"])
        XCTAssertNil(written["id_token"])
        XCTAssertEqual(written["auth_mode"]?.stringValue, "chatgpt")
        XCTAssertEqual(written["tokens"]?["access_token"]?.stringValue, "access-token")
        XCTAssertEqual(written["tokens"]?["refresh_token"]?.stringValue, "refresh-token")
        XCTAssertEqual(written["tokens"]?["id_token"]?.stringValue, idToken)
        XCTAssertEqual(written["tokens"]?["account_id"]?.stringValue, "acct_98765")
        XCTAssertEqual(written["organization"]?["name"]?.stringValue, "workspace-alpha")
        XCTAssertEqual(written["OPENAI_API_KEY"]?.stringValue, "sk-proj-test")
        assertRFC3339Timestamp(written["last_refresh"]?.stringValue)
    }

    func testWriteCurrentAuthReplacesInvalidLastRefreshWithCompatibleTimestamp() throws {
        let fixture = try makeRepositoryFixture()
        defer { fixture.cleanup() }

        let repository = fixture.repository
        let idToken = makeJWT(payload: [
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_54321"
            ]
        ])
        let auth = JSONValue.object([
            "auth_mode": .string("chatgpt"),
            "last_refresh": .string("not-a-date"),
            "tokens": .object([
                "access_token": .string("access-token"),
                "id_token": .string(idToken)
            ])
        ])

        try repository.writeCurrentAuth(auth)
        let written = try repository.readCurrentAuth()

        XCTAssertNotEqual(written["last_refresh"]?.stringValue, "not-a-date")
        assertRFC3339Timestamp(written["last_refresh"]?.stringValue)
    }

    func testWriteCurrentAuthRejectsPayloadWithoutIDToken() throws {
        let fixture = try makeRepositoryFixture()
        defer { fixture.cleanup() }

        let repository = fixture.repository
        let auth = JSONValue.object([
            "tokens": .object([
                "access_token": .string("access-token")
            ])
        ])

        XCTAssertThrowsError(try repository.writeCurrentAuth(auth)) { error in
            XCTAssertEqual(error.localizedDescription, "auth.json missing id_token")
        }
    }

    private func makeJWT(payload: [String: Any]) -> String {
        let headerData = try! JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"])
        let payloadData = try! JSONSerialization.data(withJSONObject: payload)

        let header = base64URL(headerData)
        let body = base64URL(payloadData)
        return "\(header).\(body)."
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func requestBodyString(from request: URLRequest) -> String? {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8)
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var data = Data()
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(buffer, maxLength: bufferSize)
            guard bytesRead > 0 else { break }
            data.append(buffer, count: bytesRead)
        }
        return String(data: data, encoding: .utf8)
    }

    private func makeRepositoryFixture(session: URLSession = .shared) throws -> RepositoryFixture {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let authPath = tempDir.appendingPathComponent("auth.json")
        let configPath = tempDir.appendingPathComponent("config.toml")
        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            settingsStorePath: tempDir.appendingPathComponent("settings.json"),
            codexAuthPath: authPath,
            codexConfigPath: configPath,
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key", isDirectory: false),
            cloudflaredLogDirectory: tempDir.appendingPathComponent("cloudflared-logs", isDirectory: true)
        )

        return RepositoryFixture(
            repository: AuthFileRepository(paths: paths, session: session),
            cleanup: { try? FileManager.default.removeItem(at: tempDir) }
        )
    }

    private func assertRFC3339Timestamp(_ value: String?, file: StaticString = #filePath, line: UInt = #line) {
        guard let value else {
            XCTFail("Expected timestamp", file: file, line: line)
            return
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]

        XCTAssertTrue(
            fractionalFormatter.date(from: value) != nil || plainFormatter.date(from: value) != nil,
            "Expected RFC3339 timestamp but received \(value)",
            file: file,
            line: line
        )
    }
}

private struct RepositoryFixture {
    let repository: AuthFileRepository
    let cleanup: () -> Void
}

private final class AuthFileRepositoryMockURLProtocol: URLProtocol, @unchecked Sendable {
    static let store = AuthFileRepositoryMockURLProtocolStore()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Task {
            do {
                let (response, data) = try await Self.store.response(for: request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}

private actor AuthFileRepositoryMockURLProtocolStore {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private var handler: Handler?

    func setHandler(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        guard let handler else {
            throw URLError(.badServerResponse)
        }
        return try handler(request)
    }
}
