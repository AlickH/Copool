import Foundation

#if os(macOS)
final class CodexCLIService: CodexCLIServiceProtocol, @unchecked Sendable {
    /// Returns `true` when it falls back to `codex app`.
    func launchApp(workspacePath: String?) throws -> Bool {
        forceStopRunningCodex()

        var appLaunchError: String?
        if let appPath = findCodexAppPath() {
            do {
                try launchCodexBundleApp(at: appPath, workspacePath: workspacePath)
                if waitForCodexProcess(timeoutSeconds: 2) {
                    return false
                }
                appLaunchError = L10n.tr("error.codex_cli.launch_app_open_failed")
            } catch {
                appLaunchError = error.localizedDescription
            }
        }

        do {
            try launchViaCodexCLI(workspacePath: workspacePath)
        } catch {
            if let appLaunchError {
                let appLaunchPrefix = L10n.tr("error.codex_cli.launch_app_open_failed")
                let cliFallbackDetail = L10n.tr("error.codex_cli.launch_app_fallback_failed_format", error.localizedDescription)
                throw AppError.io(
                    "\(appLaunchPrefix): \(appLaunchError) | \(cliFallbackDetail)"
                )
            }
            throw error
        }

        return true
    }

    private func forceStopRunningCodex() {
        _ = try? CommandRunner.run("/usr/bin/pkill", arguments: ["-9", "-x", "Codex"])
        _ = try? CommandRunner.run("/usr/bin/pkill", arguments: ["-9", "-x", "Codex Desktop"])
        Thread.sleep(forTimeInterval: 0.22)
    }

    private func findCodexCLIPath() throws -> String {
        if let fromPATH = CommandRunner.resolveExecutable("codex"), !fromPATH.isEmpty {
            return fromPATH
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            URL(fileURLWithPath: "/usr/bin/codex"),
            home.appendingPathComponent(".local/bin/codex"),
            home.appendingPathComponent(".npm-global/bin/codex"),
            home.appendingPathComponent(".volta/bin/codex"),
            home.appendingPathComponent(".asdf/shims/codex"),
            home.appendingPathComponent("Library/pnpm/codex"),
            home.appendingPathComponent("bin/codex")
        ]

        if let appPath = findCodexAppPath() {
            candidates.append(appPath.appendingPathComponent("Contents/Resources/codex"))
        }

        let nvmVersions = home.appendingPathComponent(".nvm/versions/node")
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: nvmVersions,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries.sorted(by: { $0.path > $1.path }) {
                candidates.append(entry.appendingPathComponent("bin/codex"))
            }
        }

        for candidate in candidates where isExecutable(candidate) {
            return candidate.path
        }

        throw AppError.fileNotFound(L10n.tr("error.codex_cli.executable_not_found"))
    }

    private func findCodexAppPath() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications/Codex.app"),
            URL(fileURLWithPath: "/Applications/Codex Desktop.app"),
            home.appendingPathComponent("Applications/Codex.app"),
            home.appendingPathComponent("Applications/Codex Desktop.app")
        ]
        if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return found
        }

        if let spotlightCodex = spotlightFindApp(named: "Codex.app") {
            return spotlightCodex
        }
        if let spotlightDesktop = spotlightFindApp(named: "Codex Desktop.app") {
            return spotlightDesktop
        }
        return nil
    }

    private func isExecutable(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attrs[.type] as? FileAttributeType,
              type == .typeRegular,
              let perm = attrs[.posixPermissions] as? NSNumber else {
            return false
        }
        return perm.intValue & 0o111 != 0
    }

    private func mergedPathEnvironment(for executablePath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let current = env["PATH"] ?? ""
        let parent = URL(fileURLWithPath: executablePath).deletingLastPathComponent().path
        env["PATH"] = parent + (current.isEmpty ? "" : ":\(current)")
        return env
    }

    private func launchCodexBundleApp(at appPath: URL, workspacePath: String?) throws {
        var arguments = ["-na", appPath.path]
        if let workspacePath, !workspacePath.isEmpty {
            arguments.append(workspacePath)
        }

        _ = try CommandRunner.runChecked(
            "/usr/bin/open",
            arguments: arguments,
            errorPrefix: L10n.tr("error.codex_cli.launch_app_open_failed")
        )
    }

    private func launchViaCodexCLI(workspacePath: String?) throws {
        let codexPath = try findCodexCLIPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = workspacePath?.isEmpty == false ? ["app", workspacePath!] : ["app"]
        process.environment = mergedPathEnvironment(for: codexPath)

        do {
            try process.run()
        } catch {
            throw AppError.io(L10n.tr("error.codex_cli.launch_app_fallback_failed_format", error.localizedDescription))
        }
    }

    private func waitForCodexProcess(timeoutSeconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if isCodexProcessRunning() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private func isCodexProcessRunning() -> Bool {
        let codex = try? CommandRunner.run("/usr/bin/pgrep", arguments: ["-x", "Codex"])
        if codex?.status == 0 {
            return true
        }
        let desktop = try? CommandRunner.run("/usr/bin/pgrep", arguments: ["-x", "Codex Desktop"])
        return desktop?.status == 0
    }

    private func spotlightFindApp(named appName: String) -> URL? {
        let query = "kMDItemFSName == '\(appName)'"
        guard let output = try? CommandRunner.run("/usr/bin/mdfind", arguments: [query]),
              output.status == 0 else {
            return nil
        }
        let line = output.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        guard let line else { return nil }
        let path = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
#else
final class CodexCLIService: CodexCLIServiceProtocol, @unchecked Sendable {
    func launchApp(workspacePath: String?) throws -> Bool {
        _ = workspacePath
        throw AppError.io(PlatformCapabilities.unsupportedOperationMessage)
    }
}
#endif
