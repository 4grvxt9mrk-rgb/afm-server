import Foundation
import Hummingbird
import ShimCore

/// Registers the OpenAI-compatible routes against a Hummingbird router.
public struct OpenAIRoutes: Sendable {
    private let provider: any LLMProvider
    private let encoder = JSONEncoder()

    public init(provider: any LLMProvider) {
        self.provider = provider
    }

    public func register(on router: Router<BasicRequestContext>) {
        router.get("/health") { _, _ in "OK" }
        router.get("/v1/models") { _, _ in try self.modelsResponse() }
        router.post("/v1/chat/completions") { request, context in
            try await self.chatCompletions(request, context)
        }
    }

    // MARK: - Handlers

    private func modelsResponse() throws -> Response {
        try json(ModelsResponse.make(provider.models))
    }

    private func chatCompletions(_ request: Request, _ context: BasicRequestContext) async throws -> Response {
        let decoded: ChatCompletionRequest
        do {
            let buffer = try await request.body.collect(upTo: 4 * 1024 * 1024)
            let data = Data(buffer.readableBytesView)
            decoded = try JSONDecoder().decode(ChatCompletionRequest.self, from: data)
        } catch {
            return try errorResponse("Invalid request body: \(error)", status: .badRequest)
        }

        let domain = decoded.toDomain()

        if case .failure(let shimError) = await provider.availability() {
            return try errorResponse(message(for: shimError), status: .serviceUnavailable, type: "server_error")
        }

        // Tool-calling decisions are computed with constrained decoding, which is
        // inherently non-streaming; emit the result as SSE only if the client
        // asked for a stream.
        if domain.wantsToolCalling {
            return try await toolCallResponse(domain)
        }

        return domain.stream
            ? streamingResponse(domain)
            : try await completionResponse(domain)
    }

    private func toolCallResponse(_ request: GenerationRequest) async throws -> Response {
        let result: GenerationResult
        do {
            result = try await provider.generate(request)
        } catch let shimError as ShimError {
            return try errorResponse(message(for: shimError), status: .internalServerError, type: "server_error")
        } catch {
            return try errorResponse("Generation failed: \(error)", status: .internalServerError, type: "server_error")
        }

        guard request.stream else {
            return try json(ChatCompletionResponse.make(model: request.model, result: result))
        }
        return oneShotStream(result, model: request.model)
    }

    /// Emit a single already-computed result as an SSE stream (opening role
    /// chunk, one content-or-tool_calls chunk, a finish chunk, then `[DONE]`).
    private func oneShotStream(_ result: GenerationResult, model: String) -> Response {
        let id = "chatcmpl-\(UUID().uuidString)"
        let created = Int(Date().timeIntervalSince1970)
        let enc = encoder

        let sse = AsyncThrowingStream<ByteBuffer, Error> { continuation in
            func send(_ chunk: ChatCompletionChunk) {
                guard let data = try? enc.encode(chunk),
                      let line = String(data: data, encoding: .utf8) else { return }
                continuation.yield(ByteBuffer(string: "data: \(line)\n\n"))
            }

            send(ChatCompletionChunk(
                id: id, object: "chat.completion.chunk", created: created, model: model,
                choices: [.init(index: 0, delta: .init(role: "assistant"), finish_reason: nil)]
            ))

            if result.toolCalls.isEmpty {
                send(ChatCompletionChunk(
                    id: id, object: "chat.completion.chunk", created: created, model: model,
                    choices: [.init(index: 0, delta: .init(content: result.text), finish_reason: nil)]
                ))
            } else {
                let deltas = result.toolCalls.enumerated().map { index, call in
                    ChatCompletionChunk.ToolCallDelta(
                        index: index, id: call.id,
                        function: .init(name: call.name, arguments: call.argumentsJSON)
                    )
                }
                send(ChatCompletionChunk(
                    id: id, object: "chat.completion.chunk", created: created, model: model,
                    choices: [.init(index: 0, delta: .init(tool_calls: deltas), finish_reason: nil)]
                ))
            }

            send(ChatCompletionChunk(
                id: id, object: "chat.completion.chunk", created: created, model: model,
                choices: [.init(index: 0, delta: .init(), finish_reason: result.finishReason.rawValue)]
            ))
            continuation.yield(ByteBuffer(string: "data: [DONE]\n\n"))
            continuation.finish()
        }

        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache"
        return Response(status: .ok, headers: headers, body: ResponseBody(asyncSequence: sse))
    }

    private func completionResponse(_ request: GenerationRequest) async throws -> Response {
        do {
            let result = try await provider.generate(request)
            return try json(ChatCompletionResponse.make(model: request.model, result: result))
        } catch let shimError as ShimError {
            return try errorResponse(message(for: shimError), status: .internalServerError, type: "server_error")
        } catch {
            return try self.errorResponse("Generation failed: \(error)", status: .internalServerError, type: "server_error")
        }
    }

    private func streamingResponse(_ request: GenerationRequest) -> Response {
        let model = request.model
        let id = "chatcmpl-\(UUID().uuidString)"
        let created = Int(Date().timeIntervalSince1970)
        let enc = encoder
        let upstream = provider.stream(request)

        let sse = AsyncThrowingStream<ByteBuffer, Error> { continuation in
            let task = Task {
                func send(_ chunk: ChatCompletionChunk) {
                    guard let data = try? enc.encode(chunk),
                          let line = String(data: data, encoding: .utf8) else { return }
                    continuation.yield(ByteBuffer(string: "data: \(line)\n\n"))
                }

                // Opening chunk announces the assistant role.
                send(ChatCompletionChunk(
                    id: id, object: "chat.completion.chunk", created: created, model: model,
                    choices: [.init(index: 0, delta: .init(role: "assistant", content: nil), finish_reason: nil)]
                ))

                do {
                    for try await part in upstream {
                        send(ChatCompletionChunk(
                            id: id, object: "chat.completion.chunk", created: created, model: model,
                            choices: [.init(index: 0, delta: .init(role: nil, content: part.delta), finish_reason: nil)]
                        ))
                    }
                    send(ChatCompletionChunk(
                        id: id, object: "chat.completion.chunk", created: created, model: model,
                        choices: [.init(index: 0, delta: .init(role: nil, content: nil), finish_reason: "stop")]
                    ))
                    continuation.yield(ByteBuffer(string: "data: [DONE]\n\n"))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache"
        return Response(status: .ok, headers: headers, body: ResponseBody(asyncSequence: sse))
    }

    // MARK: - Helpers

    private func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
        let data = try encoder.encode(value)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: status, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    private func errorResponse(_ message: String, status: HTTPResponse.Status, type: String = "invalid_request_error") throws -> Response {
        try json(ErrorResponse.make(message, type: type), status: status)
    }

    private func message(for error: ShimError) -> String {
        switch error {
        case .modelUnavailable(let reason): return "Model unavailable: \(reason)"
        case .unsupportedModel(let model):  return "Unsupported model: \(model)"
        case .generationFailed(let detail): return "Generation failed: \(detail)"
        }
    }
}
