import Foundation
import OSLog

#if os(macOS)
actor RemoteProxyService: RemoteProxyServiceProtocol {
    private let logger = Logger(subsystem: "Copool", category: "RemoteProxyService")
    private let repoRoot: URL?
    private let sourceAccountStorePath: URL
    private let sourceAuthPath: URL
    private let fileManager: FileManager

    init(repoRoot: URL?, sourceAccountStorePath: URL, sourceAuthPath: URL, fileManager: FileManager = .default) {
        self.repoRoot = repoRoot
        self.sourceAccountStorePath = sourceAccountStorePath
        self.sourceAuthPath = sourceAuthPath
        self.fileManager = fileManager
    }

    func status(server: RemoteServerConfig) async -> RemoteProxyStatus {
        do {
            let normalized = try validate(server)
            let serviceName = systemdServiceName(for: normalized)
            let command = """
            DIR=\(shellQuote(normalized.remoteDir)); BIN="$DIR/codex-tools-proxyd"; KEYFILE="$DIR/api-proxy.key"; UNIT=\(shellQuote(serviceName)); \
            INSTALLED=0; SERVICE_INSTALLED=0; RUNNING=0; ENABLED=0; PID=""; API_KEY=""; \
            if [ -x "$BIN" ]; then INSTALLED=1; fi; \
            if command -v systemctl >/dev/null 2>&1; then \
              if [ -f "/etc/systemd/system/$UNIT" ] || [ -f "/lib/systemd/system/$UNIT" ]; then SERVICE_INSTALLED=1; fi; \
              ENABLED_STATE=$(systemctl is-enabled "$UNIT" 2>/dev/null || true); \
              if [ "$ENABLED_STATE" = "enabled" ]; then ENABLED=1; fi; \
              ACTIVE_STATE=$(systemctl is-active "$UNIT" 2>/dev/null || true); \
              if [ "$ACTIVE_STATE" = "active" ]; then RUNNING=1; fi; \
              PID=$(systemctl show -p MainPID --value "$UNIT" 2>/dev/null || true); \
              if [ "$PID" = "0" ]; then PID=""; fi; \
            fi; \
            if [ -f "$KEYFILE" ]; then API_KEY=$(cat "$KEYFILE" 2>/dev/null || true); fi; \
            printf 'installed=%s\\nservice_installed=%s\\nrunning=%s\\nenabled=%s\\npid=%s\\napi_key=%s\\n' "$INSTALLED" "$SERVICE_INSTALLED" "$RUNNING" "$ENABLED" "$PID" "$API_KEY"
            """

            let output = try runSSH(server: normalized, command: command)
            return parseStatusOutput(output, serviceName: serviceName, host: normalized.host, listenPort: normalized.listenPort)
        } catch {
            return RemoteProxyStatus(
                installed: false,
                serviceInstalled: false,
                running: false,
                enabled: false,
                serviceName: systemdServiceName(for: server),
                pid: nil,
                baseURL: "http://\(server.host):\(server.listenPort)/v1",
                apiKey: nil,
                lastError: error.localizedDescription
            )
        }
    }

    func deploy(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        let server = try validate(server)
        try ensureSSHToolsAvailable(for: server)

        let binaryPath = try ensureDaemonBinary(for: server)
        let serviceName = systemdServiceName(for: server)
        let serviceContent = renderSystemdUnit(server: server, serviceName: serviceName)

        let temp = fileManager.temporaryDirectory.appendingPathComponent("codex-tools-remote-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temp) }

        let localBinary = temp.appendingPathComponent("codex-tools-proxyd", isDirectory: false)
        let localAccounts = temp.appendingPathComponent("accounts.json", isDirectory: false)
        let localService = temp.appendingPathComponent(serviceName, isDirectory: false)

        try fileManager.copyItem(at: binaryPath, to: localBinary)
        let accountsData = try buildRemoteAccountsStoreData()
        try accountsData.write(to: localAccounts, options: .atomic)
        try serviceContent.write(to: localService, atomically: true, encoding: .utf8)

        let stageDir = "/tmp/codex-tools-remote-\(safeFragment(server.id))-\(Int(Date().timeIntervalSince1970))"
        _ = try runSSH(server: server, command: "mkdir -p \(shellQuote(stageDir))")

        try runSCP(server: server, localPath: localBinary.path, remotePath: "\(stageDir)/codex-tools-proxyd")
        try runSCP(server: server, localPath: localAccounts.path, remotePath: "\(stageDir)/accounts.json")
        try runSCP(server: server, localPath: localService.path, remotePath: "\(stageDir)/\(serviceName)")

        let installCommand = """
        mkdir -p \(shellQuote(server.remoteDir)); \
        mv \(shellQuote("\(stageDir)/codex-tools-proxyd")) \(shellQuote("\(server.remoteDir)/codex-tools-proxyd")); chmod 700 \(shellQuote("\(server.remoteDir)/codex-tools-proxyd")); \
        mv \(shellQuote("\(stageDir)/accounts.json")) \(shellQuote("\(server.remoteDir)/accounts.json")); chmod 600 \(shellQuote("\(server.remoteDir)/accounts.json")); \
        mv \(shellQuote("\(stageDir)/\(serviceName)")) \(shellQuote("/etc/systemd/system/\(serviceName)")); chmod 644 \(shellQuote("/etc/systemd/system/\(serviceName)")); \
        rm -rf \(shellQuote(stageDir)); \
        systemctl daemon-reload; \
        systemctl enable \(shellQuote(serviceName)) >/dev/null 2>&1 || true; \
        if systemctl is-active --quiet \(shellQuote(serviceName)); then systemctl restart \(shellQuote(serviceName)); else systemctl start \(shellQuote(serviceName)); fi
        """

        _ = try runSSH(server: server, command: withRootPrivileges(installCommand))

        return await status(server: server)
    }

    func start(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        let normalized = try validate(server)
        let serviceName = systemdServiceName(for: normalized)
        _ = try runSSH(server: normalized, command: withRootPrivileges("systemctl start \(shellQuote(serviceName))"))
        return await status(server: normalized)
    }

    func stop(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        let normalized = try validate(server)
        let serviceName = systemdServiceName(for: normalized)
        _ = try runSSH(server: normalized, command: withRootPrivileges("systemctl stop \(shellQuote(serviceName))"))
        return await status(server: normalized)
    }

    func readLogs(server: RemoteServerConfig, lines: Int) async throws -> String {
        let normalized = try validate(server)
        let serviceName = systemdServiceName(for: normalized)
        let count = min(max(lines, 20), 400)

        return try runSSH(
            server: normalized,
            command: withRootPrivileges("journalctl -u \(shellQuote(serviceName)) -n \(count) --no-pager"),
            timeout: 20
        )
    }

    private func validate(_ server: RemoteServerConfig) throws -> RemoteServerConfig {
        var normalized = server
        normalized.label = normalized.label.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.host = normalized.host.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.sshUser = normalized.sshUser.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.remoteDir = normalized.remoteDir.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.identityFile = normalized.identityFile?.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.privateKey = normalized.privateKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.password = normalized.password?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.label.isEmpty else { throw AppError.invalidData(L10n.tr("error.remote.label_empty")) }
        guard !normalized.host.isEmpty else { throw AppError.invalidData(L10n.tr("error.remote.host_empty")) }
        guard !normalized.sshUser.isEmpty else { throw AppError.invalidData(L10n.tr("error.remote.ssh_user_empty")) }
        guard !normalized.remoteDir.isEmpty else { throw AppError.invalidData(L10n.tr("error.remote.remote_dir_empty")) }
        guard normalized.sshPort > 0 else { throw AppError.invalidData(L10n.tr("error.remote.ssh_port_invalid")) }
        guard normalized.listenPort > 0 else { throw AppError.invalidData(L10n.tr("error.remote.listen_port_invalid")) }

        switch normalized.authMode {
        case "keyContent":
            guard normalized.privateKey?.isEmpty == false else {
                throw AppError.invalidData(L10n.tr("error.remote.private_key_content_empty"))
            }
        case "password":
            guard normalized.password?.isEmpty == false else {
                throw AppError.invalidData(L10n.tr("error.remote.password_empty"))
            }
        default:
            guard normalized.identityFile?.isEmpty == false else {
                throw AppError.invalidData(L10n.tr("error.remote.identity_file_empty"))
            }
        }

        return normalized
    }

    private func ensureSSHToolsAvailable(for server: RemoteServerConfig) throws {
        guard CommandRunner.resolveExecutable("ssh") != nil else {
            throw AppError.io(L10n.tr("error.remote.ssh_not_found"))
        }
        guard CommandRunner.resolveExecutable("scp") != nil else {
            throw AppError.io(L10n.tr("error.remote.scp_not_found"))
        }
        if server.authMode == "password", CommandRunner.resolveExecutable("sshpass") == nil {
            throw AppError.io(L10n.tr("error.remote.sshpass_required"))
        }
    }

    private func ensureDaemonBinary(for server: RemoteServerConfig) throws -> URL {
        let platform = try detectRemoteLinuxPlatform(for: server)
        guard let manifestPath = proxydManifestPath() else {
            throw AppError.io(L10n.tr("error.remote.unavailable_missing_proxyd_source"))
        }
        guard CommandRunner.resolveExecutable("cargo") != nil else {
            throw AppError.io("\(L10n.tr("error.remote.build_proxyd_failed")): cargo command not found")
        }

        try ensureLinuxBuildDependenciesIfNeeded()
        let targetDir = try proxydBuildTargetDirectory()
        let manifestDirectory = manifestPath.deletingLastPathComponent()
        var buildErrors: [String] = []

        for target in [platform.primaryTarget, platform.fallbackTarget] {
            try ensureRustTargetAddedIfPossible(target)
            let binaryPath = targetDir
                .appendingPathComponent(target, isDirectory: true)
                .appendingPathComponent("release", isDirectory: true)
                .appendingPathComponent(RepositoryLocator.proxydBinaryName, isDirectory: false)

            if fileManager.isExecutableFile(atPath: binaryPath.path) {
                return binaryPath
            }

            for build in buildAttemptCommands(manifestPath: manifestPath, target: target, targetDir: targetDir) {
                let result = try CommandRunner.run(
                    "/usr/bin/env",
                    arguments: build.command,
                    currentDirectory: manifestDirectory
                )
                if result.status == 0, fileManager.isExecutableFile(atPath: binaryPath.path) {
                    return binaryPath
                }
                let details = result.stderr.isEmpty ? result.stdout : result.stderr
                let compact = details.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = compact.isEmpty ? "exit \(result.status)" : compact
                buildErrors.append("\(build.label): \(message)")
            }
        }

        let suffix = buildErrors.isEmpty ? "" : " \(buildErrors.joined(separator: " | "))"
        throw AppError.io("\(L10n.tr("error.remote.build_proxyd_failed")):\(suffix)")
    }

    private func proxydManifestPath() -> URL? {
        if let repoRoot {
            let manifest = repoRoot.appendingPathComponent(RepositoryLocator.proxydManifestRelativePath, isDirectory: false)
            if fileManager.fileExists(atPath: manifest.path) {
                return manifest
            }
        }

        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent(RepositoryLocator.proxydBundledManifestRelativePath, isDirectory: false)
        if let bundled, fileManager.fileExists(atPath: bundled.path) {
            return bundled
        }

        return nil
    }

    private func buildRemoteAccountsStoreData() throws -> Data {
        var mergedStore = AccountsStore()
        var loadDiagnostics: [String] = []

        for path in candidateAccountStorePaths() {
            guard fileManager.fileExists(atPath: path.path) else {
                continue
            }
            do {
                let store = try decodeAccountsStore(from: path)
                mergeAccounts(from: store.accounts, into: &mergedStore)
                let usable = store.accounts.filter(isProxyUsable(account:)).count
                loadDiagnostics.append("\(path.path): total=\(store.accounts.count), usable=\(usable)")
            } catch {
                loadDiagnostics.append("\(path.path): decode_failed=\(error.localizedDescription)")
                logger.error("Failed to decode account store for remote deploy at \(path.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if !mergedStore.accounts.contains(where: isProxyUsable(account:)),
           let auth = try readCurrentAuthJSONValue(),
           let imported = buildStoredAccount(fromCurrentAuth: auth) {
            if let index = mergedStore.accounts.firstIndex(where: { $0.accountID == imported.accountID }) {
                mergedStore.accounts[index] = imported
            } else {
                mergedStore.accounts.append(imported)
            }
            loadDiagnostics.append("current_auth_imported=\(imported.accountID)")
        }

        let usableAccounts = mergedStore.accounts.filter(isProxyUsable(account:))
        guard !usableAccounts.isEmpty else {
            let details = loadDiagnostics.isEmpty ? "" : " [\(loadDiagnostics.joined(separator: " | "))]"
            throw AppError.invalidData("\(L10n.tr("error.remote.no_usable_accounts_for_deploy"))\(details)")
        }

        logger.info(
            "Prepared remote accounts for deploy. source=\(self.sourceAccountStorePath.path, privacy: .public), merged_total=\(mergedStore.accounts.count), usable=\(usableAccounts.count)"
        )

        return try encodeRemoteCompatibleStore(mergedStore)
    }

    private func candidateAccountStorePaths() -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        let fallbackSwiftStore = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("CodexToolsSwift", isDirectory: true)
            .appendingPathComponent("accounts.json", isDirectory: false)
        let legacyTauriStore = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("com.carry.codex-tools", isDirectory: true)
            .appendingPathComponent("accounts.json", isDirectory: false)

        var unique: [URL] = []
        var seen = Set<String>()
        for path in [sourceAccountStorePath, fallbackSwiftStore, legacyTauriStore] {
            if seen.insert(path.path).inserted {
                unique.append(path)
            }
        }
        return unique
    }

    private func decodeAccountsStore(from path: URL) throws -> AccountsStore {
        let data = try Data(contentsOf: path)
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode(AccountsStore.self, from: data) {
            return decoded
        }
        if let recovered = StoreFileRepository.extractFirstJSONObjectData(from: data),
           let decoded = try? decoder.decode(AccountsStore.self, from: recovered) {
            return decoded
        }
        throw AppError.invalidData("Invalid accounts.json format")
    }

    private func mergeAccounts(from incoming: [StoredAccount], into merged: inout AccountsStore) {
        for account in incoming {
            if let index = merged.accounts.firstIndex(where: { $0.accountID == account.accountID }) {
                merged.accounts[index] = preferredAccount(existing: merged.accounts[index], incoming: account)
            } else {
                merged.accounts.append(account)
            }
        }
    }

    private func preferredAccount(existing: StoredAccount, incoming: StoredAccount) -> StoredAccount {
        let existingUsable = isProxyUsable(account: existing)
        let incomingUsable = isProxyUsable(account: incoming)
        if incomingUsable != existingUsable {
            return incomingUsable ? incoming : existing
        }
        if incoming.updatedAt != existing.updatedAt {
            return incoming.updatedAt > existing.updatedAt ? incoming : existing
        }
        return existing
    }

    private func encodeRemoteCompatibleStore(_ store: AccountsStore) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let raw = try encoder.encode(store)

        let any = try JSONSerialization.jsonObject(with: raw)
        guard var root = any as? [String: Any] else {
            return raw
        }

        root["settings"] = remoteSettingsObject(from: store.settings)
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private func remoteSettingsObject(from settings: AppSettings) -> [String: Any] {
        [
            "launchAtStartup": settings.launchAtStartup,
            "launchCodexAfterSwitch": settings.launchCodexAfterSwitch,
            "syncOpencodeOpenaiAuth": settings.syncOpencodeOpenaiAuth,
            "restartEditorsOnSwitch": settings.restartEditorsOnSwitch,
            "restartEditorTargets": settings.restartEditorTargets.map(\.rawValue),
            "autoStartApiProxy": settings.autoStartApiProxy,
            "remoteServers": [],
            "apiProxyApiKey": NSNull(),
            "locale": legacyLocaleIdentifier(for: settings.locale),
        ]
    }

    private func legacyLocaleIdentifier(for locale: String) -> String {
        switch AppLocale.resolve(locale) {
        case .simplifiedChinese:
            return "zh-CN"
        case .traditionalChinese:
            return "zh-TW"
        case .english:
            return "en-US"
        case .japanese:
            return "ja-JP"
        case .korean:
            return "ko-KR"
        case .french:
            return "fr-FR"
        case .german:
            return "de-DE"
        case .italian:
            return "it-IT"
        case .spanish:
            return "es-ES"
        case .russian:
            return "ru-RU"
        case .dutch:
            return "nl-NL"
        }
    }

    private func readCurrentAuthJSONValue() throws -> JSONValue? {
        guard fileManager.fileExists(atPath: sourceAuthPath.path) else {
            return nil
        }
        let data = try Data(contentsOf: sourceAuthPath)
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONValue.from(any: object)
    }

    private func buildStoredAccount(fromCurrentAuth auth: JSONValue) -> StoredAccount? {
        guard let extracted = extractAuthFromJSONValue(auth) else {
            return nil
        }
        let now = Int64(Date().timeIntervalSince1970)
        let label = extracted.email ?? "Remote Imported \(extracted.accountID.prefix(8))"
        return StoredAccount(
            id: UUID().uuidString,
            label: label,
            email: extracted.email,
            accountID: extracted.accountID,
            planType: extracted.planType,
            teamName: nil,
            teamAlias: nil,
            authJSON: auth,
            addedAt: now,
            updatedAt: now,
            usage: nil,
            usageError: nil
        )
    }

    private func isProxyUsable(account: StoredAccount) -> Bool {
        extractAuthFromJSONValue(account.authJSON) != nil
    }

    private func extractAuthFromJSONValue(_ auth: JSONValue) -> (accountID: String, email: String?, planType: String?)? {
        let mode = auth["auth_mode"]?.stringValue?.lowercased() ?? ""
        guard let tokens = authTokenObject(from: auth) else {
            if !mode.isEmpty && mode != "chatgpt" && mode != "chatgpt_auth_tokens" {
                return nil
            }
            return nil
        }

        guard tokens["access_token"]?.stringValue != nil,
              let idToken = tokens["id_token"]?.stringValue else {
            return nil
        }

        var accountID = tokens["account_id"]?.stringValue
        var email: String?
        var planType: String?
        if let claims = try? decodeJWTPayload(idToken) {
            email = claims["email"]?.stringValue
            if accountID == nil {
                accountID = claims["https://api.openai.com/auth"]?["chatgpt_account_id"]?.stringValue
            }
            planType = claims["https://api.openai.com/auth"]?["chatgpt_plan_type"]?.stringValue
        }
        guard let accountID, !accountID.isEmpty else {
            return nil
        }
        return (accountID, email, planType)
    }

    private func authTokenObject(from auth: JSONValue) -> [String: JSONValue]? {
        if let tokens = auth["tokens"]?.objectValue {
            return tokens
        }

        if let object = auth.objectValue,
           object["access_token"]?.stringValue != nil,
           object["id_token"]?.stringValue != nil {
            return object
        }

        return nil
    }

    private func decodeJWTPayload(_ token: String) throws -> JSONValue {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count > 1 else {
            throw AppError.invalidData(L10n.tr("error.auth.id_token_invalid_format"))
        }

        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload) else {
            throw AppError.invalidData(L10n.tr("error.auth.decode_id_token_failed"))
        }
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONValue.from(any: object)
    }

    private func proxydBuildTargetDirectory() throws -> URL {
        let caches = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let path = caches
            .appendingPathComponent("Copool", isDirectory: true)
            .appendingPathComponent("proxyd-target", isDirectory: true)
        try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    private func ensureRustTargetAddedIfPossible(_ target: String) throws {
        guard CommandRunner.resolveExecutable("rustup") != nil else {
            return
        }
        _ = try? CommandRunner.run("/usr/bin/env", arguments: ["rustup", "target", "add", target])
    }

    private func buildAttemptCommands(manifestPath: URL, target: String, targetDir: URL) -> [BuildAttempt] {
        let manifest = manifestPath.path
        let targetDirPath = targetDir.path
        var attempts: [BuildAttempt] = []

        if CommandRunner.resolveExecutable("cross") != nil {
            attempts.append(
                BuildAttempt(
                    label: "cross \(target)",
                    command: [
                        "cross", "build",
                        "--manifest-path", manifest,
                        "--release",
                        "--target", target,
                        "--target-dir", targetDirPath,
                    ]
                )
            )
        }

        if hasCargoZigbuild() {
            attempts.append(
                BuildAttempt(
                    label: "cargo zigbuild \(target)",
                    command: [
                        "cargo", "zigbuild",
                        "--manifest-path", manifest,
                        "--release",
                        "--target", target,
                        "--target-dir", targetDirPath,
                    ]
                )
            )
        }

        attempts.append(
            BuildAttempt(
                label: "cargo build \(target)",
                command: [
                    "cargo", "build",
                    "--manifest-path", manifest,
                    "--release",
                    "--target", target,
                    "--target-dir", targetDirPath,
                ]
            )
        )

        return attempts
    }

    private func hasCargoZigbuild() -> Bool {
        guard CommandRunner.resolveExecutable("zig") != nil else {
            return false
        }
        if CommandRunner.resolveExecutable("cargo-zigbuild") != nil {
            return true
        }
        guard CommandRunner.resolveExecutable("cargo") != nil else {
            return false
        }
        if let help = try? CommandRunner.run("/usr/bin/env", arguments: ["cargo", "zigbuild", "--help"]) {
            return help.status == 0
        }
        return false
    }

    private func ensureLinuxBuildDependenciesIfNeeded() throws {
        if CommandRunner.resolveExecutable("cross") != nil || hasCargoZigbuild() {
            return
        }

        #if os(macOS)
        guard CommandRunner.resolveExecutable("brew") != nil else {
            return
        }

        if CommandRunner.resolveExecutable("zig") == nil {
            _ = try CommandRunner.runChecked(
                "/usr/bin/env",
                arguments: ["brew", "install", "zig"],
                errorPrefix: "\(L10n.tr("error.remote.build_proxyd_failed")) (install zig)"
            )
        }

        if !hasCargoZigbuild() {
            _ = try CommandRunner.runChecked(
                "/usr/bin/env",
                arguments: ["cargo", "install", "cargo-zigbuild", "--locked"],
                errorPrefix: "\(L10n.tr("error.remote.build_proxyd_failed")) (install cargo-zigbuild)"
            )
        }
        #endif
    }

    private func detectRemoteLinuxPlatform(for server: RemoteServerConfig) throws -> RemoteLinuxPlatform {
        let output = try runSSH(server: server, command: "uname -s && uname -m")
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let os = lines.first ?? ""
        let arch = lines.count > 1 ? lines[1] : ""

        guard os == "Linux" else {
            let value = os.isEmpty ? "unknown" : os
            throw AppError.io("Remote deploy supports Linux only (detected: \(value))")
        }

        switch arch {
        case "x86_64", "amd64":
            return RemoteLinuxPlatform(
                primaryTarget: "x86_64-unknown-linux-musl",
                fallbackTarget: "x86_64-unknown-linux-gnu"
            )
        case "aarch64", "arm64":
            return RemoteLinuxPlatform(
                primaryTarget: "aarch64-unknown-linux-musl",
                fallbackTarget: "aarch64-unknown-linux-gnu"
            )
        default:
            let value = arch.isEmpty ? "unknown" : arch
            throw AppError.io("Unsupported remote Linux architecture: \(value)")
        }
    }

    private func runSSH(server: RemoteServerConfig, command: String, timeout: TimeInterval = 60) throws -> String {
        var temporaryKey: URL?
        defer {
            if let temporaryKey {
                try? fileManager.removeItem(at: temporaryKey)
            }
        }

        let identityPath: String?
        switch server.authMode {
        case "keyContent":
            let tempKey = fileManager.temporaryDirectory.appendingPathComponent("codex-tools-key-\(UUID().uuidString)", isDirectory: false)
            try server.privateKey?.write(to: tempKey, atomically: true, encoding: .utf8)
            #if canImport(Darwin)
            _ = chmod(tempKey.path, S_IRUSR | S_IWUSR)
            #endif
            temporaryKey = tempKey
            identityPath = tempKey.path
        case "password":
            identityPath = nil
        default:
            identityPath = server.identityFile
        }

        var args: [String] = []
        if server.authMode == "password", let password = server.password {
            args.append(contentsOf: ["sshpass", "-p", password, "ssh"])
        } else {
            args.append("ssh")
        }

        args.append(contentsOf: [
            "-p", String(server.sshPort),
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=12",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=2",
        ])
        if server.authMode != "password" {
            args.append(contentsOf: ["-o", "BatchMode=yes"])
        }
        if let identityPath {
            args.append(contentsOf: ["-i", identityPath])
        }
        args.append("\(server.sshUser)@\(server.host)")
        args.append(command)

        let result = try CommandRunner.run("/usr/bin/env", arguments: args, timeout: timeout)
        guard result.status == 0 else {
            throw AppError.io(L10n.tr("error.remote.ssh_command_failed_format", result.stderr.isEmpty ? result.stdout : result.stderr))
        }
        return result.stdout
    }

    private func runSCP(server: RemoteServerConfig, localPath: String, remotePath: String, timeout: TimeInterval = 90) throws {
        var temporaryKey: URL?
        defer {
            if let temporaryKey {
                try? fileManager.removeItem(at: temporaryKey)
            }
        }

        let identityPath: String?
        switch server.authMode {
        case "keyContent":
            let tempKey = fileManager.temporaryDirectory.appendingPathComponent("codex-tools-key-\(UUID().uuidString)", isDirectory: false)
            try server.privateKey?.write(to: tempKey, atomically: true, encoding: .utf8)
            #if canImport(Darwin)
            _ = chmod(tempKey.path, S_IRUSR | S_IWUSR)
            #endif
            temporaryKey = tempKey
            identityPath = tempKey.path
        case "password":
            identityPath = nil
        default:
            identityPath = server.identityFile
        }

        var args: [String] = []
        if server.authMode == "password", let password = server.password {
            args.append(contentsOf: ["sshpass", "-p", password, "scp"])
        } else {
            args.append("scp")
        }

        args.append(contentsOf: [
            "-P", String(server.sshPort),
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=12",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=2",
        ])
        if server.authMode != "password" {
            args.append(contentsOf: ["-o", "BatchMode=yes"])
        }
        if let identityPath {
            args.append(contentsOf: ["-i", identityPath])
        }

        args.append(localPath)
        args.append("\(server.sshUser)@\(server.host):\(remotePath)")

        let result = try CommandRunner.run("/usr/bin/env", arguments: args, timeout: timeout)
        guard result.status == 0 else {
            throw AppError.io(L10n.tr("error.remote.scp_failed_format", result.stderr.isEmpty ? result.stdout : result.stderr))
        }
    }

    private func parseStatusOutput(_ output: String, serviceName: String, host: String, listenPort: Int) -> RemoteProxyStatus {
        var installed = false
        var serviceInstalled = false
        var running = false
        var enabled = false
        var pid: Int?
        var apiKey: String?

        for line in output.split(whereSeparator: { $0.isNewline }) {
            let text = String(line)
            if let value = text.split(separator: "=", maxSplits: 1).dropFirst().first {
                if text.hasPrefix("installed=") {
                    installed = value == "1"
                } else if text.hasPrefix("service_installed=") {
                    serviceInstalled = value == "1"
                } else if text.hasPrefix("running=") {
                    running = value == "1"
                } else if text.hasPrefix("enabled=") {
                    enabled = value == "1"
                } else if text.hasPrefix("pid=") {
                    pid = Int(value)
                } else if text.hasPrefix("api_key=") {
                    let key = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
                    apiKey = key.isEmpty ? nil : key
                }
            }
        }

        return RemoteProxyStatus(
            installed: installed,
            serviceInstalled: serviceInstalled,
            running: running,
            enabled: enabled,
            serviceName: serviceName,
            pid: pid,
            baseURL: "http://\(host):\(listenPort)/v1",
            apiKey: apiKey,
            lastError: nil
        )
    }

    private func systemdServiceName(for server: RemoteServerConfig) -> String {
        "codex-tools-proxyd-\(safeFragment(server.id)).service"
    }

    private func safeFragment(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let chars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let sanitized = String(chars)
        return sanitized.isEmpty ? "default" : sanitized
    }

    private func renderSystemdUnit(server: RemoteServerConfig, serviceName: String) -> String {
        """
        [Unit]
        Description=Codex Tools Remote API Proxy (\(serviceName))
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=simple
        WorkingDirectory=\(server.remoteDir)
        ExecStart=\(server.remoteDir)/codex-tools-proxyd serve --data-dir \(server.remoteDir) --host 0.0.0.0 --port \(server.listenPort) --no-sync-current-auth
        Restart=always
        RestartSec=3
        Environment=RUST_LOG=info

        [Install]
        WantedBy=multi-user.target
        """
    }

    private func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func withRootPrivileges(_ command: String) -> String {
        "if [ \"$(id -u)\" = \"0\" ]; then \(command); else sudo sh -lc \(shellQuote(command)); fi"
    }
}

private struct RemoteLinuxPlatform {
    let primaryTarget: String
    let fallbackTarget: String
}

private struct BuildAttempt {
    let label: String
    let command: [String]
}
#else
actor RemoteProxyService: RemoteProxyServiceProtocol {
    init(repoRoot: URL?, sourceAccountStorePath: URL, sourceAuthPath: URL, fileManager: FileManager = .default) {
        _ = repoRoot
        _ = sourceAccountStorePath
        _ = sourceAuthPath
        _ = fileManager
    }

    func status(server: RemoteServerConfig) async -> RemoteProxyStatus {
        RemoteProxyStatus(
            installed: false,
            serviceInstalled: false,
            running: false,
            enabled: false,
            serviceName: "codex-tools-proxyd-\(server.id).service",
            pid: nil,
            baseURL: "http://\(server.host):\(server.listenPort)/v1",
            apiKey: nil,
            lastError: PlatformCapabilities.unsupportedOperationMessage
        )
    }

    func deploy(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        _ = server
        throw AppError.io(PlatformCapabilities.unsupportedOperationMessage)
    }

    func start(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        _ = server
        throw AppError.io(PlatformCapabilities.unsupportedOperationMessage)
    }

    func stop(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        _ = server
        throw AppError.io(PlatformCapabilities.unsupportedOperationMessage)
    }

    func readLogs(server: RemoteServerConfig, lines: Int) async throws -> String {
        _ = server
        _ = lines
        throw AppError.io(PlatformCapabilities.unsupportedOperationMessage)
    }
}
#endif
