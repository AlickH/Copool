import Foundation

extension SwiftNativeProxyRuntimeService {
    struct ClientModelResolution: Equatable {
        let upstreamModel: String
        let defaultReasoningEffort: String?
    }

    static var clientVisibleModels: [String] {
        let baseModels = [
            "GPT-5",
            "GPT-5.5",
            "GPT-5.4",
            "GPT-5.4-Mini",
            "GPT-5.2",
            "GPT-5.3-Codex",
            "GPT-5.2-Codex",
            "GPT-5.1-Codex-Mini",
            "GPT-5.1-Codex-Max"
        ]
        let reasoningEfforts = ["Low", "Medium", "High", "xHigh"]
        let reasoningAliases = baseModels.flatMap { model in
            reasoningEfforts.map { "\(model)-\($0)" }
        }
        return baseModels + reasoningAliases
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

    func mapClientModelToUpstream(_ model: String) throws -> String {
        try resolveClientModel(model).upstreamModel
    }

    func resolveClientModel(_ model: String) throws -> ClientModelResolution {
        let normalized = normalizedClientModelToken(model)
        if let aliasResolution = resolveReasoningAlias(for: normalized) {
            return aliasResolution
        }

        if normalized == "gpt-5-4" || normalized == "gpt-5.4" || normalized == "gpt5.4" {
            return ClientModelResolution(upstreamModel: "gpt-5.4", defaultReasoningEffort: nil)
        }
        return ClientModelResolution(
            upstreamModel: normalizedNumericModelRevisionIfNeeded(normalized),
            defaultReasoningEffort: nil
        )
    }

    func normalizeModelForClient(_ model: String) -> String {
        Self.clientDisplayModelName(for: model)
    }

    func responsesEndpoint(forUpstreamModel model: String) -> URL {
        let routeFamily = Self.resolveUpstreamRouteFamily(forUpstreamModel: model)
        let base = resolveUpstreamBaseURL(routeFamily: routeFamily)
        return URL(string: "\(base)/responses")!
    }

    private func resolveUpstreamBaseURL(routeFamily: UpstreamRouteFamily) -> String {
        let defaultOrigin = "https://chatgpt.com"
        let configured = readChatGPTBaseURLFromConfig() ?? defaultOrigin
        return Self.resolveUpstreamBaseURL(configuredBaseURL: configured, routeFamily: routeFamily)
    }

    static func clientDisplayModelName(for model: String) -> String {
        let lowercased = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalized: String
        if lowercased == "gpt5.4" {
            normalized = "gpt-5.4"
        } else if lowercased.hasPrefix("gpt5.4-") {
            normalized = "gpt-5.4" + lowercased.dropFirst("gpt5.4".count)
        } else {
            normalized = lowercased
        }
        let parts = normalized.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[0] == "gpt" else {
            return model
        }

        let version: String
        let suffixStart: Int
        if parts.count >= 3, parts[1] == "5", parts[2].allSatisfy(\.isNumber) {
            version = "5.\(parts[2])"
            suffixStart = 3
        } else {
            version = parts[1]
            suffixStart = 2
        }

        var displayParts = ["GPT", version]
        displayParts.append(contentsOf: parts.dropFirst(suffixStart).map(Self.displaySegment))
        return displayParts.joined(separator: "-")
    }

    private static func displaySegment(_ value: String) -> String {
        if value == "xhigh" {
            return "xHigh"
        }
        guard let first = value.first else { return value }
        return String(first).uppercased() + value.dropFirst().lowercased()
    }

    private func resolveReasoningAlias(for normalizedModel: String) -> ClientModelResolution? {
        for effort in ["low", "medium", "high", "xhigh"] {
            let suffix = "-\(effort)"
            guard normalizedModel.hasSuffix(suffix) else { continue }

            let base = String(normalizedModel.dropLast(suffix.count))
            guard !base.isEmpty else { continue }

            do {
                let baseResolution = try resolveClientModel(base)
                return ClientModelResolution(
                    upstreamModel: baseResolution.upstreamModel,
                    defaultReasoningEffort: effort
                )
            } catch {
                continue
            }
        }

        return nil
    }
}
