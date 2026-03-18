import XCTest
@testable import Copool

final class AuthFileRepositoryTests: XCTestCase {
    func testExtractAuthReadsAccountAndClaims() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let authPath = tempDir.appendingPathComponent("auth.json")
        let configPath = tempDir.appendingPathComponent("config.toml")
        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: authPath,
            codexConfigPath: configPath,
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key", isDirectory: false),
            cloudflaredLogDirectory: tempDir.appendingPathComponent("cloudflared-logs", isDirectory: true)
        )

        let repository = AuthFileRepository(paths: paths)
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
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let authPath = tempDir.appendingPathComponent("auth.json")
        let configPath = tempDir.appendingPathComponent("config.toml")
        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: authPath,
            codexConfigPath: configPath,
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key", isDirectory: false),
            cloudflaredLogDirectory: tempDir.appendingPathComponent("cloudflared-logs", isDirectory: true)
        )

        let repository = AuthFileRepository(paths: paths)
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

    func testMakeChatGPTAuthBuildsCodexCompatibleShape() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let authPath = tempDir.appendingPathComponent("auth.json")
        let configPath = tempDir.appendingPathComponent("config.toml")
        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: authPath,
            codexConfigPath: configPath,
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key", isDirectory: false),
            cloudflaredLogDirectory: tempDir.appendingPathComponent("cloudflared-logs", isDirectory: true)
        )

        let repository = AuthFileRepository(paths: paths)
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
}
