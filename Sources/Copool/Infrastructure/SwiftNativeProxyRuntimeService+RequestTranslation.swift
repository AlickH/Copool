import Foundation

extension SwiftNativeProxyRuntimeService {
    private static let unsupportedResponsesForwardingKeys: Set<String> = [
        "prompt_cache_key",
        "prompt_cache_retention",
        "safety_identifier",
        "service_tier",
        "max_output_tokens",
        "temperature"
    ]

    func normalizeResponsesRequest(_ request: [String: Any]) throws -> (payload: [String: Any], downstreamStream: Bool) {
        guard let rawModel = request["model"] as? String, !rawModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.missing_model"))
        }
        let modelResolution = try resolveClientModel(rawModel)
        let model = modelResolution.upstreamModel

        var payload = request
        let downstreamStream = (request["stream"] as? Bool) ?? false

        for key in Self.unsupportedResponsesForwardingKeys {
            payload.removeValue(forKey: key)
        }
        payload["model"] = model
        payload["stream"] = true
        payload["store"] = false
        if let input = payload["input"] {
            payload["input"] = normalizeResponsesInput(input)
        }
        if payload["instructions"] == nil {
            payload["instructions"] = ""
        }
        if payload["parallel_tool_calls"] == nil {
            payload["parallel_tool_calls"] = true
        }

        let currentReasoning = payload["reasoning"] as? [String: Any] ?? [:]
        payload["reasoning"] = Self.mergedReasoningForUpstream(
            existing: currentReasoning,
            defaultEffort: modelResolution.defaultReasoningEffort,
            upstreamModel: model
        )

        var include = payload["include"] as? [Any] ?? []
        if !include.contains(where: { ($0 as? String) == "reasoning.encrypted_content" }) {
            include.append("reasoning.encrypted_content")
        }
        payload["include"] = include

        return (payload, downstreamStream)
    }

    func normalizeResponsesInput(_ input: Any) -> Any {
        if let text = input as? String {
            return [[
                "type": "message",
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": text
                ]]
            ]]
        }

        if let message = input as? [String: Any],
           let role = message["role"] as? String {
            return [[
                "type": "message",
                "role": role == "assistant" ? "assistant" : (["system", "developer"].contains(role) ? "developer" : "user"),
                "content": convertMessageContentToCodexParts(role: role, content: message["content"])
            ]]
        }

        return input
    }

    func convertChatRequestToResponses(_ request: [String: Any]) throws -> (payload: [String: Any], downstreamStream: Bool) {
        if request["messages"] == nil, request["input"] != nil {
            return try normalizeResponsesRequest(request)
        }

        guard let rawModel = request["model"] as? String, !rawModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.missing_model"))
        }
        let modelResolution = try resolveClientModel(rawModel)
        let model = modelResolution.upstreamModel

        guard let messages = request["messages"] as? [Any] else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.chat_missing_messages"))
        }

        let downstreamStream = (request["stream"] as? Bool) ?? false

        var input: [[String: Any]] = []
        for raw in messages {
            guard let message = raw as? [String: Any] else {
                throw AppError.invalidData(L10n.tr("error.proxy_runtime.messages_item_must_be_object"))
            }

            guard let role = message["role"] as? String, !role.isEmpty else {
                throw AppError.invalidData(L10n.tr("error.proxy_runtime.message_missing_role"))
            }

            if role == "tool" {
                let callID = (message["tool_call_id"] as? String) ?? ""
                let output = stringifyMessageContent(message["content"])
                input.append([
                    "type": "function_call_output",
                    "call_id": callID,
                    "output": output
                ])
                continue
            }

            let mappedRole: String
            switch role {
            case "system", "developer": mappedRole = "developer"
            case "assistant": mappedRole = "assistant"
            default: mappedRole = "user"
            }

            let contentParts = convertMessageContentToCodexParts(role: role, content: message["content"])
            input.append([
                "type": "message",
                "role": mappedRole,
                "content": contentParts
            ])

            if role == "assistant",
               let toolCalls = message["tool_calls"] as? [Any] {
                for rawToolCall in toolCalls {
                    guard let toolCall = rawToolCall as? [String: Any] else { continue }
                    let toolType = (toolCall["type"] as? String) ?? "function"
                    if toolType != "function" { continue }
                    guard let function = toolCall["function"] as? [String: Any] else { continue }

                    let name = (function["name"] as? String) ?? ""
                    let arguments = stringifyJSONField(function["arguments"])
                    let callID = (toolCall["id"] as? String) ?? ""
                    input.append([
                        "type": "function_call",
                        "call_id": callID,
                        "name": name,
                        "arguments": arguments
                    ])
                }
            }
        }

        let currentReasoning = request["reasoning"] as? [String: Any] ?? [:]
        var requestedReasoning = currentReasoning
        if let reasoningEffort = request["reasoning_effort"] as? String {
            requestedReasoning["effort"] = reasoningEffort
        }
        if requestedReasoning["summary"] == nil {
            requestedReasoning["summary"] = "auto"
        }
        let reasoning = Self.mergedReasoningForUpstream(
            existing: requestedReasoning,
            defaultEffort: modelResolution.defaultReasoningEffort,
            upstreamModel: model
        )

        var payload: [String: Any] = [
            "model": model,
            "stream": true,
            "store": false,
            "instructions": "",
            "parallel_tool_calls": (request["parallel_tool_calls"] as? Bool) ?? true,
            "include": ["reasoning.encrypted_content"],
            "reasoning": reasoning,
            "input": input
        ]

        if let tools = request["tools"] as? [Any] {
            var convertedTools: [[String: Any]] = []
            for rawTool in tools {
                guard let tool = rawTool as? [String: Any] else { continue }
                let type = (tool["type"] as? String) ?? ""
                if type == "function",
                   let function = tool["function"] as? [String: Any] {
                    var converted: [String: Any] = ["type": "function"]
                    if let name = function["name"] { converted["name"] = name }
                    if let description = function["description"] { converted["description"] = description }
                    if let parameters = function["parameters"] { converted["parameters"] = parameters }
                    if let strict = function["strict"] { converted["strict"] = strict }
                    convertedTools.append(converted)
                } else {
                    convertedTools.append(tool)
                }
            }
            if !convertedTools.isEmpty {
                payload["tools"] = convertedTools
            }
        }
        if let toolChoice = request["tool_choice"] {
            payload["tool_choice"] = toolChoice
        }

        if let responseFormat = request["response_format"] {
            mapResponseFormat(into: &payload, responseFormat: responseFormat)
        }
        if let text = request["text"] {
            mapTextSettings(into: &payload, text: text)
        }

        return (payload, downstreamStream)
    }

    func convertMessageContentToCodexParts(role: String, content: Any?) -> [[String: Any]] {
        let textType = role == "assistant" ? "output_text" : "input_text"

        guard let content else { return [] }

        if let text = content as? String {
            guard !text.isEmpty else { return [] }
            return [["type": textType, "text": text]]
        }

        guard let items = content as? [Any] else { return [] }
        var parts: [[String: Any]] = []

        for raw in items {
            guard let item = raw as? [String: Any],
                  let type = item["type"] as? String else { continue }

            if type == "text", let text = item["text"] as? String {
                parts.append(["type": textType, "text": text])
                continue
            }

            if type == "image_url",
               let image = item["image_url"] as? [String: Any],
               let url = image["url"] as? String,
               ["user", "developer", "system"].contains(role) {
                parts.append(["type": "input_image", "image_url": url])
                continue
            }
        }

        return parts
    }

    func stringifyContent(_ value: Any?) -> String {
        guard let value else { return "" }

        if let text = value as? String {
            return text
        }

        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return text
        }

        return String(describing: value)
    }

    func stringifyMessageContent(_ content: Any?) -> String {
        guard let content else { return "" }

        if let text = content as? String {
            return text
        }

        if let items = content as? [Any] {
            let texts = items.compactMap { item -> String? in
                guard let object = item as? [String: Any] else { return nil }
                return object["text"] as? String
            }
            return texts.joined(separator: "\n")
        }

        if let null = content as? NSNull, null == NSNull() {
            return ""
        }

        if JSONSerialization.isValidJSONObject(content),
           let data = try? JSONSerialization.data(withJSONObject: content),
           let text = String(data: data, encoding: .utf8) {
            return text
        }

        return ""
    }

    func stringifyJSONField(_ value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String {
            return text
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return ""
    }

    func mapResponseFormat(into root: inout [String: Any], responseFormat: Any) {
        guard let formatObject = responseFormat as? [String: Any],
              let formatType = formatObject["type"] as? String else {
            return
        }

        var text = root["text"] as? [String: Any] ?? [:]
        var format = text["format"] as? [String: Any] ?? [:]

        switch formatType {
        case "text":
            format["type"] = "text"
        case "json_schema":
            format["type"] = "json_schema"
            if let schemaObject = formatObject["json_schema"] as? [String: Any] {
                if let name = schemaObject["name"] { format["name"] = name }
                if let strict = schemaObject["strict"] { format["strict"] = strict }
                if let schema = schemaObject["schema"] { format["schema"] = schema }
            }
        default:
            break
        }

        text["format"] = format
        root["text"] = text
    }

    func mapTextSettings(into root: inout [String: Any], text value: Any) {
        guard let textObject = value as? [String: Any],
              let verbosity = textObject["verbosity"] else {
            return
        }

        var target = root["text"] as? [String: Any] ?? [:]
        target["verbosity"] = verbosity
        root["text"] = target
    }
}
