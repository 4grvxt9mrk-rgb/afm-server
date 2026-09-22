import Foundation
import ShimCore

// MARK: - Requests

/// `POST /v1/chat/completions` request body (subset of the OpenAI spec).
struct ChatCompletionRequest: Decodable {
    let model: String
    let messages: [Message]
    let temperature: Double?
    let max_tokens: Int?
    let stream: Bool?
    let tools: [Tool]?
    let tool_choice: ToolChoiceWire?

    struct Message: Decodable {
        let role: String
        let content: MessageContent?
        let tool_calls: [ToolCallWire]?
        let tool_call_id: String?
        let name: String?
    }

    struct Tool: Decodable {
        let type: String?
        let function: Function

        struct Function: Decodable {
            let name: String
            let description: String?
            let parameters: JSONSchema?
        }
    }

    struct ToolCallWire: Decodable {
        let id: String?
        let type: String?
        let function: Function

        struct Function: Decodable {
            let name: String
            let arguments: String?
        }
    }

    func toDomain() -> GenerationRequest {
        let domainTools: [ToolSpec] = (tools ?? []).map {
            ToolSpec(name: $0.function.name, description: $0.function.description, parameters: $0.function.parameters)
        }
        return GenerationRequest(
            model: model,
            messages: messages.map { $0.toDomain() },
            temperature: temperature,
            maxTokens: max_tokens,
            stream: stream ?? false,
            tools: domainTools,
            toolChoice: (tool_choice ?? .auto).toDomain()
        )
    }
}

extension ChatCompletionRequest.Message {
    func toDomain() -> ChatMessage {
        ChatMessage(
            role: ChatMessage.Role(rawValue: role) ?? .user,
            content: content?.text,
            toolCalls: (tool_calls ?? []).map {
                ToolCall(
                    id: $0.id ?? "call_\(UUID().uuidString.prefix(8))",
                    name: $0.function.name,
                    argumentsJSON: $0.function.arguments ?? "{}"
                )
            },
            toolCallID: tool_call_id,
            name: name
        )
    }
}

/// OpenAI message `content` may be a string, `null`, or an array of typed
/// parts (text / image_url / …). We flatten to plain text and ignore non-text
/// parts, which the on-device text model can't consume anyway.
enum MessageContent: Decodable {
    case text(String)

    var text: String { if case .text(let s) = self { return s } else { return "" } }

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .text(""); return }
        if let s = try? single.decode(String.self) { self = .text(s); return }

        struct Part: Decodable { let type: String?; let text: String? }
        if let parts = try? single.decode([Part].self) {
            let joined = parts.compactMap { $0.text }.joined(separator: "\n")
            self = .text(joined)
            return
        }
        self = .text("")
    }
}

/// `tool_choice` may be the strings `"auto"`/`"none"`/`"required"`, or an
/// object `{"type":"function","function":{"name":"…"}}`.
enum ToolChoiceWire: Decodable {
    case auto, none, required, named(String)

    func toDomain() -> ToolChoice {
        switch self {
        case .auto:            return .auto
        case .none:            return .none
        case .required:        return .required
        case .named(let name): return .named(name)
        }
    }

    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            switch s {
            case "none":     self = .none
            case "required": self = .required
            default:         self = .auto
            }
            return
        }
        struct Object: Decodable {
            struct Fn: Decodable { let name: String }
            let function: Fn
        }
        if let obj = try? Object(from: decoder) {
            self = .named(obj.function.name)
        } else {
            self = .auto
        }
    }
}

// MARK: - Non-streaming response

struct ChatCompletionResponse: Encodable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [Choice]
    let usage: Usage

    struct Choice: Encodable {
        let index: Int
        let message: Message
        let finish_reason: String
    }

    struct Message: Encodable {
        let role: String
        let content: String?
        let tool_calls: [ToolCallOut]?

        // Emit `content` explicitly — as JSON `null` when absent — since the
        // OpenAI shape for a tool-call message is `content: null`, and some
        // clients require the key to be present. `tool_calls` is omitted when
        // empty (the synthesized default).
        enum CodingKeys: String, CodingKey { case role, content, tool_calls }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(role, forKey: .role)
            if let content { try c.encode(content, forKey: .content) }
            else { try c.encodeNil(forKey: .content) }
            try c.encodeIfPresent(tool_calls, forKey: .tool_calls)
        }
    }

    struct ToolCallOut: Encodable {
        let id: String
        let type = "function"
        let function: Function
        struct Function: Encodable {
            let name: String
            let arguments: String
        }
    }

    struct Usage: Encodable {
        let prompt_tokens: Int
        let completion_tokens: Int
        let total_tokens: Int
    }

    static func make(model: String, result: GenerationResult) -> ChatCompletionResponse {
        let prompt = result.promptTokens ?? 0
        let completion = result.completionTokens ?? 0
        let toolCallsOut: [ToolCallOut]? = result.toolCalls.isEmpty ? nil : result.toolCalls.map {
            ToolCallOut(id: $0.id, function: .init(name: $0.name, arguments: $0.argumentsJSON))
        }
        // When there are tool calls, OpenAI sends `content: null`.
        let content: String? = result.toolCalls.isEmpty ? result.text : nil
        return ChatCompletionResponse(
            id: "chatcmpl-\(UUID().uuidString)",
            object: "chat.completion",
            created: Int(Date().timeIntervalSince1970),
            model: model,
            choices: [
                Choice(
                    index: 0,
                    message: Message(role: "assistant", content: content, tool_calls: toolCallsOut),
                    finish_reason: result.finishReason.rawValue
                )
            ],
            usage: Usage(prompt_tokens: prompt, completion_tokens: completion, total_tokens: prompt + completion)
        )
    }
}

// MARK: - Streaming response (SSE chunks)

struct ChatCompletionChunk: Encodable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [Choice]

    struct Choice: Encodable {
        let index: Int
        let delta: Delta
        let finish_reason: String?
    }

    struct Delta: Encodable {
        let role: String?
        let content: String?
        let tool_calls: [ToolCallDelta]?

        init(role: String? = nil, content: String? = nil, tool_calls: [ToolCallDelta]? = nil) {
            self.role = role
            self.content = content
            self.tool_calls = tool_calls
        }
    }

    struct ToolCallDelta: Encodable {
        let index: Int
        let id: String
        let type = "function"
        let function: Function
        struct Function: Encodable {
            let name: String
            let arguments: String
        }
    }
}

// MARK: - Models listing

struct ModelsResponse: Encodable {
    let object = "list"
    let data: [Model]

    struct Model: Encodable {
        let id: String
        let object = "model"
        let created: Int
        let owned_by = "apple"
    }

    static func make(_ infos: [ModelInfo]) -> ModelsResponse {
        ModelsResponse(data: infos.map {
            Model(id: $0.id, created: Int($0.created.timeIntervalSince1970))
        })
    }
}

// MARK: - Errors

struct ErrorResponse: Encodable {
    let error: Body
    struct Body: Encodable {
        let message: String
        let type: String
    }

    static func make(_ message: String, type: String = "invalid_request_error") -> ErrorResponse {
        ErrorResponse(error: Body(message: message, type: type))
    }
}
