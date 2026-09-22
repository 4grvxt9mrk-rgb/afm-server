import Foundation

/// A single message in a conversation, provider-agnostic.
public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Codable {
        case system, user, assistant, tool
    }

    public let role: Role
    /// Free-text content. Optional because assistant messages that only carry
    /// `toolCalls`, and some client payloads, send `content: null`.
    public let content: String?
    /// Tool calls this (assistant) message requested, replayed on follow-up turns.
    public let toolCalls: [ToolCall]
    /// For `role == .tool`, the id of the call this message answers.
    public let toolCallID: String?
    /// Optional author name (OpenAI `name`); for tool messages, the tool name.
    public let name: String?

    public init(
        role: Role,
        content: String?,
        toolCalls: [ToolCall] = [],
        toolCallID: String? = nil,
        name: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
    }
}

/// A tool the client is offering the model, translated from an OpenAI
/// `{"type":"function","function":{...}}` entry.
public struct ToolSpec: Sendable, Equatable {
    public let name: String
    public let description: String?
    /// The function's `parameters` schema; `nil` for a no-argument tool.
    public let parameters: JSONSchema?

    public init(name: String, description: String?, parameters: JSONSchema?) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// How the model is allowed to use the offered tools (OpenAI `tool_choice`).
public enum ToolChoice: Sendable, Equatable {
    /// The model may call a tool or answer directly.
    case auto
    /// The model must not call a tool.
    case none
    /// The model must call some tool.
    case required
    /// The model must call this specific tool.
    case named(String)
}

/// A single tool invocation — either requested by the model (in a result) or
/// replayed from history (in a message).
public struct ToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    /// Arguments as a JSON string, matching the OpenAI wire shape.
    public let argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// Why a generation stopped, mapped to OpenAI `finish_reason`.
public enum FinishReason: String, Sendable {
    case stop
    case toolCalls = "tool_calls"
    case length
}

/// A normalized generation request, decoupled from any wire format.
public struct GenerationRequest: Sendable {
    public let model: String
    public let messages: [ChatMessage]
    public let temperature: Double?
    public let maxTokens: Int?
    public let stream: Bool
    public let tools: [ToolSpec]
    public let toolChoice: ToolChoice

    public init(
        model: String,
        messages: [ChatMessage],
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        stream: Bool = false,
        tools: [ToolSpec] = [],
        toolChoice: ToolChoice = .auto
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stream = stream
        self.tools = tools
        self.toolChoice = toolChoice
    }

    /// Whether this request should be answered via tool-calling guided
    /// generation. `toolChoice == .none` disables it even if tools are offered.
    public var wantsToolCalling: Bool {
        !tools.isEmpty && toolChoice != .none
    }

    /// System messages joined into a single instructions string, if any.
    public var instructions: String? {
        let systemText = messages
            .filter { $0.role == .system }
            .compactMap(\.content)
            .joined(separator: "\n\n")
        return systemText.isEmpty ? nil : systemText
    }

    /// Non-system turns flattened into a single prompt.
    ///
    /// The shim is stateless per request, so prior turns are replayed as
    /// context. This is a deliberate v1 simplification — see README.
    public var prompt: String {
        messages
            .filter { $0.role != .system }
            .map { msg in
                switch msg.role {
                case .assistant:
                    if !msg.toolCalls.isEmpty {
                        let calls = msg.toolCalls
                            .map { "\($0.name)(\($0.argumentsJSON))" }
                            .joined(separator: ", ")
                        let text = msg.content.map { $0.isEmpty ? "" : "\($0)\n" } ?? ""
                        return "Assistant: \(text)[called tools: \(calls)]"
                    }
                    return "Assistant: \(msg.content ?? "")"
                case .tool:
                    let label = msg.name.map { "Tool \($0)" } ?? "Tool"
                    return "\(label) result: \(msg.content ?? "")"
                default:
                    return "User: \(msg.content ?? "")"
                }
            }
            .joined(separator: "\n")
    }
}

/// A completed, non-streamed generation.
public struct GenerationResult: Sendable {
    public let text: String
    public let toolCalls: [ToolCall]
    public let finishReason: FinishReason
    public let promptTokens: Int?
    public let completionTokens: Int?

    public init(
        text: String,
        toolCalls: [ToolCall] = [],
        finishReason: FinishReason = .stop,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil
    ) {
        self.text = text
        self.toolCalls = toolCalls
        self.finishReason = finishReason
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

/// One incremental chunk of a streamed generation (a text delta).
public struct GenerationChunk: Sendable {
    public let delta: String
    public init(delta: String) {
        self.delta = delta
    }
}

/// Metadata for a model advertised over the API.
public struct ModelInfo: Sendable {
    public let id: String
    public let created: Date

    public init(id: String, created: Date = Date(timeIntervalSince1970: 0)) {
        self.id = id
        self.created = created
    }
}

/// Errors surfaced to the API layer, mapped to HTTP status codes there.
public enum ShimError: Error, Sendable {
    case modelUnavailable(reason: String)
    case unsupportedModel(String)
    case generationFailed(String)
}
