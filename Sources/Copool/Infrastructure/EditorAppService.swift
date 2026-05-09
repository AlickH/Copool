import Foundation

final class EditorAppService: EditorAppServiceProtocol, @unchecked Sendable {
    private struct EditorSpec {
        let id: EditorAppID
        let label: String
        let bundleNames: [String]
        let processNames: [String]
    }

    private let specs: [EditorSpec] = [
        EditorSpec(
            id: .vscode,
            label: "VS Code",
            bundleNames: ["Visual Studio Code.app", "Code.app"],
            processNames: ["Code", "Visual Studio Code"]
        ),
        EditorSpec(
            id: .vscodeInsiders,
            label: "Visual Studio Code - Insiders",
            bundleNames: ["Visual Studio Code - Insiders.app", "Code - Insiders.app"],
            processNames: ["Code - Insiders", "Visual Studio Code - Insiders"]
        ),
        EditorSpec(
            id: .cursor,
            label: "Cursor",
            bundleNames: ["Cursor.app"],
            processNames: ["Cursor"]
        ),
        EditorSpec(
            id: .antigravity,
            label: "Antigravity",
            bundleNames: ["Antigravity.app", "Antigravity IDE.app"],
            processNames: ["Antigravity", "Antigravity IDE"]
        ),
        EditorSpec(
            id: .kiro,
            label: "Kiro",
            bundleNames: ["Kiro.app"],
            processNames: ["Kiro"]
        ),
        EditorSpec(
            id: .trae,
            label: "Trae",
            bundleNames: ["Trae.app"],
            processNames: ["Trae"]
        ),
        EditorSpec(
            id: .qoder,
            label: "Qoder",
            bundleNames: ["Qoder.app"],
            processNames: ["Qoder"]
        )
    ]

    func listInstalledApps() -> [InstalledEditorApp] {
        specs.compactMap { spec in
            guard detectBundlePath(for: spec) != nil else { return nil }
            return InstalledEditorApp(id: spec.id, label: spec.label)
        }
    }

    func restartSelectedApps(_ targets: [EditorAppID]) -> (restarted: [EditorAppID], error: String?) {
        guard !targets.isEmpty else {
            return ([], L10n.tr("error.editor.no_restart_target_selected"))
        }

        var restarted: [EditorAppID] = []
        var errors: [String] = []

        for target in targets {
            guard let spec = specs.first(where: { $0.id == target }) else {
                errors.append(L10n.tr("error.editor.unknown_editor_id_format", target.rawValue))
                continue
            }

            do {
                let path = try resolveBundlePath(for: spec)
                forceKillProcesses(spec.processNames)
                Thread.sleep(forTimeInterval: 0.22)
                _ = try CommandRunner.runChecked(
                    "/usr/bin/open",
                    arguments: ["-na", path.path],
                    errorPrefix: L10n.tr("error.editor.restart_app_failed")
                )
                restarted.append(spec.id)
            } catch {
                errors.append("\(spec.label): \(error.localizedDescription)")
            }
        }

        return (restarted, errors.isEmpty ? nil : errors.joined(separator: " | "))
    }

    private func resolveBundlePath(for spec: EditorSpec) throws -> URL {
        guard let path = detectBundlePath(for: spec) else {
            throw AppError.fileNotFound(L10n.tr("error.editor.installation_path_not_found"))
        }
        return path
    }

    private func detectBundlePath(for spec: EditorSpec) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for bundle in spec.bundleNames {
            let systemPath = URL(fileURLWithPath: "/Applications").appendingPathComponent(bundle)
            if FileManager.default.fileExists(atPath: systemPath.path) {
                return systemPath
            }
            let userPath = home.appendingPathComponent("Applications").appendingPathComponent(bundle)
            if FileManager.default.fileExists(atPath: userPath.path) {
                return userPath
            }
        }
        return nil
    }

    private func forceKillProcesses(_ processNames: [String]) {
        for name in processNames {
            _ = try? CommandRunner.run("/usr/bin/pkill", arguments: ["-9", "-x", name])
        }
    }
}
