import Foundation

enum RuntimePlatform: Equatable {
    case macOS
}

enum PlatformCapabilities {
    static let currentPlatform: RuntimePlatform = .macOS

    static var supportsMenuBarScene: Bool { true }
    static var supportsLaunchAtStartup: Bool { true }
    static var supportsShellCommands: Bool { true }
    static var supportsCodexCLI: Bool { true }
    static var supportsCloudflared: Bool { true }
    static var supportsRemoteShellManagement: Bool { true }

    static let unsupportedOperationMessage = "This operation is unavailable."
}
