import Foundation

/// A single message in a conversation, provider-agnostic.
public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Codable {
        case system, user, assistant, tool
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// A normalized generation request, decoupled from any wire format.
public struct GenerationRequest: Sendable {
    public let model: String
    public let messages: [ChatMessage]
    public let temperature: Double?
    public let maxTokens: Int?
    public let stream: Bool

    public init(
        model: String,
        messages: [ChatMessage],
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        stream: Bool = false
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stream = stream
    }

    /// System messages joined into a single instructions string, if any.
    public var instructions: String? {
        let systemText = messages
            .filter { $0.role == .system }
            .map(\.content)
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
                case .assistant: return "Assistant: \(msg.content)"
                case .tool:      return "Tool: \(msg.content)"
                default:         return "User: \(msg.content)"
                }
            }
            .joined(separator: "\n")
    }
}

/// A completed, non-streamed generation.
public struct GenerationResult: Sendable {
    public let text: String
    public let promptTokens: Int?
    public let completionTokens: Int?

    public init(text: String, promptTokens: Int? = nil, completionTokens: Int? = nil) {
        self.text = text
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
