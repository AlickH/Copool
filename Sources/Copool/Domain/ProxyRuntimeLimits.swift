import Foundation

enum ProxyRuntimeLimits {
    // Hard limits to prevent unbounded buffering from exhausting app memory.
    static let maxInboundRequestBytes = 8 * 1024 * 1024
    static let maxUpstreamResponseBytes = 12 * 1024 * 1024

    static func limitDescription(for bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.includesCount = true
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
