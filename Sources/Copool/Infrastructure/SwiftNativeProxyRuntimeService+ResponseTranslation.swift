import Foundation

extension SwiftNativeProxyRuntimeService {
    func convertCompletedResponseToChatCompletion(_ response: [String: Any], fallbackModel: String) -> [String: Any] {
        let id = (response["id"] as? String) ?? "chatcmpl_\(UUID().uuidString)"
        let created = (response["created_at"] as? Int) ?? Int(dateProvider.unixSecondsNow())
        let model = normalizeModelForClient((response["model"] as? String) ?? fallbackModel)

        var message: [String: Any] = ["role": "assistant"]
        var reasoningContent: String?
        var textContent: String?
        var toolCalls: [[String: Any]] = []

        if let output = response["output"] as? [Any] {
            for rawItem in output {
                guard let item = rawItem as? [String: Any],
                      let type = item["type"] as? String else { continue }

                switch type {
                case "reasoning":
                    if let summary = item["summary"] as? [Any] {
                        for rawSummary in summary {
                            guard let summaryObject = rawSummary as? [String: Any] else { continue }
                            if (summaryObject["type"] as? String) == "summary_text",
                               let text = summaryObject["text"] as? String,
                               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                reasoningContent = text
                                break
                            }
                        }
                    }
                case "message":
                    if let content = item["content"] as? [Any] {
                        var chunks: [String] = []
                        for rawContent in content {
                            guard let contentObject = rawContent as? [String: Any] else { continue }
                            if (contentObject["type"] as? String) == "output_text",
                               let text = contentObject["text"] as? String,
                               !text.isEmpty {
                                chunks.append(text)
                            }
                        }
                        if !chunks.isEmpty {
                            textContent = chunks.joined()
                        }
                    }
                case "function_call":
                    let callID = (item["call_id"] as? String) ?? ""
                    let name = (item["name"] as? String) ?? ""
                    let arguments = (item["arguments"] as? String) ?? ""
                    toolCalls.append([
                        "id": callID,
                        "type": "function",
                        "function": [
                            "name": name,
                            "arguments": arguments
                        ]
                    ])
                default:
                    break
                }
            }
        }

        if textContent == nil {
            textContent = extractAssistantText(fromCompletedResponse: response)
        }

        message["content"] = textContent ?? NSNull()
        if let reasoningContent {
            message["reasoning_content"] = reasoningContent
        }
        if !toolCalls.isEmpty {
            message["tool_calls"] = toolCalls
        }

        let finishReason = toolCalls.isEmpty ? "stop" : "tool_calls"

        var root: [String: Any] = [
            "id": id,
            "object": "chat.completion",
            "created": created,
            "model": model,
            "choices": [[
                "index": 0,
                "message": message,
                "finish_reason": finishReason,
                "native_finish_reason": finishReason
            ]]
        ]

        if let usage = response["usage"] as? [String: Any] {
            root["usage"] = buildOpenAIUsage(from: usage)
        }

        return root
    }

    func convertResponsesSSEToChatCompletionsSSE(_ sseData: Data, fallbackModel: String) throws -> Data {
        let decoder = makeChatCompletionsSSEStreamDecoder(fallbackModel: fallbackModel)
        let chunks = try consumeChatCompletionsSSEStreamChunk(decoder, data: sseData, isFinal: true)

        var lines = ""
        for chunk in chunks {
            lines += "data: \(jsonString(chunk))\n\n"
        }
        lines += "data: [DONE]\n\n"
        return Data(lines.utf8)
    }

    func makeChatCompletionsSSEStreamDecoder(fallbackModel: String) -> ChatCompletionsSSEStreamDecoder {
        ChatCompletionsSSEStreamDecoder(
            decoder: SSEStreamDecoder(),
            state: ChatStreamState(
                responseID: "chatcmpl_\(UUID().uuidString)",
                createdAt: Int(dateProvider.unixSecondsNow()),
                model: normalizeModelForClient(fallbackModel),
                functionCallIndex: -1,
                hasReceivedArgumentsDelta: false,
                hasToolCallAnnounced: false
            )
        )
    }

    func consumeChatCompletionsSSEStreamChunk(
        _ decoder: ChatCompletionsSSEStreamDecoder,
        data: Data,
        isFinal: Bool
    ) throws -> [[String: Any]] {
        var chunks: [[String: Any]] = []
        for event in decoder.decoder.push(data: data, isFinal: isFinal) {
            chunks.append(contentsOf: translateSSEEventToChatChunks(event, state: &decoder.state))
        }
        return chunks
    }

    func makeResponsesPassthroughSSEStreamDecoder() -> SSEStreamDecoder {
        SSEStreamDecoder()
    }

    func consumeResponsesPassthroughSSEChunk(
        _ decoder: SSEStreamDecoder,
        data: Data,
        isFinal: Bool
    ) -> [Data] {
        decoder.push(data: data, isFinal: isFinal).map { event in
            serializeSSEEvent(event: event.event, data: rewriteSSEEventDataModelsForClient(event.data))
        }
    }

    func translateSSEEventToChatChunks(_ event: SSEEvent, state: inout ChatStreamState) -> [[String: Any]] {
        guard event.data != "[DONE]",
              let payloadData = event.data.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let kind = parsed["type"] as? String else {
            return []
        }

        switch kind {
        case "response.created":
            if let response = parsed["response"] as? [String: Any] {
                state.responseID = (response["id"] as? String) ?? state.responseID
                state.createdAt = (response["created_at"] as? Int) ?? state.createdAt
                state.model = normalizeModelForClient((response["model"] as? String) ?? state.model)
            }
            return []

        case "response.reasoning_summary_text.delta":
            let delta = (parsed["delta"] as? String) ?? ""
            guard !delta.isEmpty else { return [] }
            return [
                buildChatChunk(
                    state: state,
                    delta: ["role": "assistant", "reasoning_content": delta],
                    finishReason: nil,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        case "response.reasoning_summary_text.done":
            return [
                buildChatChunk(
                    state: state,
                    delta: ["role": "assistant", "reasoning_content": "\n\n"],
                    finishReason: nil,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        case "response.output_text.delta":
            let delta = (parsed["delta"] as? String) ?? ""
            guard !delta.isEmpty else { return [] }
            return [
                buildChatChunk(
                    state: state,
                    delta: ["role": "assistant", "content": delta],
                    finishReason: nil,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        case "response.output_item.added":
            guard let item = parsed["item"] as? [String: Any],
                  (item["type"] as? String) == "function_call" else {
                return []
            }
            state.functionCallIndex += 1
            state.hasReceivedArgumentsDelta = false
            state.hasToolCallAnnounced = true
            return [
                buildChatChunk(
                    state: state,
                    delta: [
                        "role": "assistant",
                        "tool_calls": [[
                            "index": state.functionCallIndex,
                            "id": (item["call_id"] as? String) ?? "",
                            "type": "function",
                            "function": [
                                "name": (item["name"] as? String) ?? "",
                                "arguments": ""
                            ]
                        ]]
                    ],
                    finishReason: nil,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        case "response.function_call_arguments.delta":
            state.hasReceivedArgumentsDelta = true
            return [
                buildChatChunk(
                    state: state,
                    delta: [
                        "tool_calls": [[
                            "index": state.functionCallIndex,
                            "function": [
                                "arguments": (parsed["delta"] as? String) ?? ""
                            ]
                        ]]
                    ],
                    finishReason: nil,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        case "response.function_call_arguments.done":
            if state.hasReceivedArgumentsDelta {
                return []
            }
            return [
                buildChatChunk(
                    state: state,
                    delta: [
                        "tool_calls": [[
                            "index": state.functionCallIndex,
                            "function": [
                                "arguments": (parsed["arguments"] as? String) ?? ""
                            ]
                        ]]
                    ],
                    finishReason: nil,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        case "response.output_item.done":
            guard let item = parsed["item"] as? [String: Any],
                  (item["type"] as? String) == "function_call" else {
                return []
            }

            if state.hasToolCallAnnounced {
                state.hasToolCallAnnounced = false
                return []
            }

            state.functionCallIndex += 1
            return [
                buildChatChunk(
                    state: state,
                    delta: [
                        "role": "assistant",
                        "tool_calls": [[
                            "index": state.functionCallIndex,
                            "id": (item["call_id"] as? String) ?? "",
                            "type": "function",
                            "function": [
                                "name": (item["name"] as? String) ?? "",
                                "arguments": (item["arguments"] as? String) ?? ""
                            ]
                        ]]
                    ],
                    finishReason: nil,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        case "response.completed":
            let finishReason = state.functionCallIndex >= 0 ? "tool_calls" : "stop"
            return [
                buildChatChunk(
                    state: state,
                    delta: [:],
                    finishReason: finishReason,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        default:
            return []
        }
    }

    func buildChatChunk(
        state: ChatStreamState,
        delta: [String: Any],
        finishReason: String?,
        usage: [String: Any]?
    ) -> [String: Any] {
        let finishValue: Any = finishReason ?? NSNull()
        var chunk: [String: Any] = [
            "id": state.responseID,
            "object": "chat.completion.chunk",
            "created": max(0, state.createdAt),
            "model": state.model,
            "choices": [[
                "index": 0,
                "delta": delta,
                "finish_reason": finishValue,
                "native_finish_reason": finishValue
            ]]
        ]

        if let usage {
            chunk["usage"] = buildOpenAIUsage(from: usage)
        }

        return chunk
    }

    func extractAssistantText(fromCompletedResponse response: [String: Any]) -> String {
        var segments: [String] = []

        if let outputs = response["output"] as? [Any] {
            for item in outputs {
                guard let object = item as? [String: Any] else { continue }

                if let type = object["type"] as? String, type == "output_text", let text = object["text"] as? String {
                    segments.append(text)
                    continue
                }

                if let messageType = object["type"] as? String, messageType == "message",
                   let content = object["content"] as? [Any] {
                    for part in content {
                        guard let partObj = part as? [String: Any] else { continue }
                        if let text = partObj["text"] as? String {
                            segments.append(text)
                        }
                    }
                }
            }
        }

        if segments.isEmpty, let text = response["output_text"] as? String {
            segments.append(text)
        }

        return segments.joined(separator: "")
    }

    func buildOpenAIUsage(from usage: [String: Any]) -> [String: Any] {
        var root: [String: Any] = [:]
        if let inputTokens = usage["input_tokens"] {
            root["prompt_tokens"] = inputTokens
        }
        if let outputTokens = usage["output_tokens"] {
            root["completion_tokens"] = outputTokens
        }
        if let totalTokens = usage["total_tokens"] {
            root["total_tokens"] = totalTokens
        }
        if let inputDetails = usage["input_tokens_details"] as? [String: Any],
           let cached = inputDetails["cached_tokens"] {
            root["prompt_tokens_details"] = ["cached_tokens": cached]
        }
        if let outputDetails = usage["output_tokens_details"] as? [String: Any],
           let reasoning = outputDetails["reasoning_tokens"] {
            root["completion_tokens_details"] = ["reasoning_tokens": reasoning]
        }
        return root
    }

    func extractCompletedResponse(fromSSE data: Data) throws -> [String: Any] {
        let events = parseSSEEvents(from: data)
        var lastJSON: [String: Any]?
        var accumulator = CompletedResponseAccumulator()

        for event in events {
            guard event.data != "[DONE]" else { continue }
            guard let payloadData = event.data.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                continue
            }

            lastJSON = object
            accumulator.observe(object)

            if (object["type"] as? String) == "response.completed",
               let response = object["response"] as? [String: Any] {
                return accumulator.finalize(response)
            }

            if object["id"] != nil, object["output"] != nil {
                return object
            }

            if (object["type"] as? String) == "response.error" {
                let message = (object["error"] as? [String: Any])?["message"] as? String ?? L10n.tr("error.proxy_runtime.upstream_response_error")
                throw AppError.network(message)
            }
        }

        if let lastJSON {
            return lastJSON
        }

        throw AppError.network(L10n.tr("error.proxy_runtime.sse_extract_completed_failed"))
    }

    func parseSSEEvents(from data: Data) -> [SSEEvent] {
        SSEStreamDecoder().push(data: data, isFinal: true)
    }

    func rewriteSSEEventDataModelsForClient(_ data: String) -> String {
        guard data != "[DONE]",
              let payloadData = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return data
        }
        return jsonString(rewriteResponseModelFields(object))
    }

    func serializeSSEEvent(event: String?, data: String) -> Data {
        var lines = ""
        if let event, !event.isEmpty {
            lines += "event: \(event)\n"
        }
        for line in data.split(separator: "\n", omittingEmptySubsequences: false) {
            lines += "data: \(line)\n"
        }
        lines += "\n"
        return Data(lines.utf8)
    }
}

struct SSEEvent {
    var event: String?
    var data: String
}

struct ChatStreamState {
    var responseID: String
    var createdAt: Int
    var model: String
    var functionCallIndex: Int
    var hasReceivedArgumentsDelta: Bool
    var hasToolCallAnnounced: Bool
}

private struct CompletedResponseAccumulator {
    private var outputItems: [Int: [String: Any]] = [:]

    mutating func observe(_ object: [String: Any]) {
        guard (object["type"] as? String) == "response.output_item.done",
              let item = object["item"] as? [String: Any] else {
            return
        }

        let index = object["output_index"] as? Int ?? outputItems.count
        outputItems[index] = item
    }

    func finalize(_ response: [String: Any]) -> [String: Any] {
        let currentOutput = response["output"] as? [Any] ?? []
        guard currentOutput.isEmpty, !outputItems.isEmpty else {
            return response
        }

        var updated = response
        updated["output"] = outputItems.keys.sorted().compactMap { outputItems[$0] }
        return updated
    }
}

final class ChatCompletionsSSEStreamDecoder: @unchecked Sendable {
    let decoder: SSEStreamDecoder
    var state: ChatStreamState

    init(decoder: SSEStreamDecoder, state: ChatStreamState) {
        self.decoder = decoder
        self.state = state
    }
}

final class SSEStreamDecoder: @unchecked Sendable {
    private var buffer = Data()

    func push(data: Data, isFinal: Bool) -> [SSEEvent] {
        if !data.isEmpty {
            buffer.append(data)
        }

        var events: [SSEEvent] = []
        while let range = nextSeparatorRange(in: buffer) {
            let chunk = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)
            if let event = parseEventBlock(chunk) {
                events.append(event)
            }
        }

        if isFinal, !buffer.isEmpty {
            if let event = parseEventBlock(buffer) {
                events.append(event)
            }
            buffer.removeAll(keepingCapacity: false)
        }

        return events
    }

    private func nextSeparatorRange(in data: Data) -> Range<Int>? {
        let bytes = Array(data)
        guard bytes.count >= 2 else { return nil }

        var index = 0
        while index < bytes.count - 1 {
            if bytes[index] == 0x0A && bytes[index + 1] == 0x0A {
                return index..<(index + 2)
            }
            if index < bytes.count - 3 &&
                bytes[index] == 0x0D &&
                bytes[index + 1] == 0x0A &&
                bytes[index + 2] == 0x0D &&
                bytes[index + 3] == 0x0A {
                return index..<(index + 4)
            }
            index += 1
        }

        return nil
    }

    private func parseEventBlock(_ data: Data) -> SSEEvent? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }

        var eventName: String?
        var dataLines: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            if line.hasPrefix("event:") {
                eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
            }
        }

        let joinedData = dataLines.joined(separator: "\n")
        return joinedData.isEmpty ? nil : SSEEvent(event: eventName, data: joinedData)
    }
}
