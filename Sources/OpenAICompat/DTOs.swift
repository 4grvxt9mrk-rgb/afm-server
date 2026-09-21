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

    struct Message: Decodable {
        let role: String
        let content: String
    }

    func toDomain() -> GenerationRequest {
        GenerationRequest(
            model: model,
            messages: messages.map {
                ChatMessage(role: ChatMessage.Role(rawValue: $0.role) ?? .user, content: $0.content)
            },
            temperature: temperature,
            maxTokens: max_tokens,
            stream: stream ?? false
        )
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
        let content: String
    }

    struct Usage: Encodable {
        let prompt_tokens: Int
        let completion_tokens: Int
        let total_tokens: Int
    }

    static func make(model: String, result: GenerationResult) -> ChatCompletionResponse {
        let prompt = result.promptTokens ?? 0
        let completion = result.completionTokens ?? 0
        return ChatCompletionResponse(
            id: "chatcmpl-\(UUID().uuidString)",
            object: "chat.completion",
            created: Int(Date().timeIntervalSince1970),
            model: model,
            choices: [
                Choice(index: 0, message: Message(role: "assistant", content: result.text), finish_reason: "stop")
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
