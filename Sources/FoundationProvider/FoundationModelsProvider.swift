import Foundation
import ShimCore

#if canImport(FoundationModels)
import FoundationModels

/// Bridges Apple's on-device FoundationModels framework to `LLMProvider`.
///
/// Each request builds a fresh `LanguageModelSession`; the shim is stateless,
/// so conversation history arrives already flattened in `GenerationRequest`.
public struct FoundationModelsProvider: LLMProvider {
    private let advertisedModelID: String

    public init(modelID: String) {
        self.advertisedModelID = modelID
    }

    public var models: [ModelInfo] {
        [ModelInfo(id: advertisedModelID)]
    }

    public func availability() async -> Result<Void, ShimError> {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .success(())
        case .unavailable(let reason):
            return .failure(.modelUnavailable(reason: String(describing: reason)))
        @unknown default:
            return .failure(.modelUnavailable(reason: "unknown availability state"))
        }
    }

    private func makeSession(_ request: GenerationRequest) -> LanguageModelSession {
        if let instructions = request.instructions {
            return LanguageModelSession(instructions: instructions)
        }
        return LanguageModelSession()
    }

    private func options(_ request: GenerationRequest) -> GenerationOptions {
        GenerationOptions(temperature: request.temperature)
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        if case .failure(let error) = await availability() { throw error }

        let session = makeSession(request)
        do {
            // Tool calling: constrain the model to a structured "which tool +
            // what arguments" decision, then translate it into tool calls.
            if request.wantsToolCalling, let schema = SchemaBridge.decisionSchema(for: request) {
                return try await generateWithTools(request, session: session, schema: schema)
            }

            let response = try await session.respond(
                to: request.prompt,
                options: options(request)
            )
            return GenerationResult(text: response.content)
        } catch let error as ShimError {
            throw error
        } catch {
            throw ShimError.generationFailed(String(describing: error))
        }
    }

    private func generateWithTools(
        _ request: GenerationRequest,
        session: LanguageModelSession,
        schema: GenerationSchema
    ) async throws -> GenerationResult {
        let allowFinal = request.toolChoice == .auto
        let guide = SchemaBridge.toolGuide(for: request, allowFinal: allowFinal)
        let prompt = "\(request.prompt)\n\n\(guide)"

        let response = try await session.respond(
            to: prompt,
            schema: schema,
            options: options(request)
        )
        switch SchemaBridge.interpret(response.content) {
        case .finalAnswer(let text):
            return GenerationResult(text: text, finishReason: .stop)
        case .toolCalls(let calls):
            return GenerationResult(text: "", toolCalls: calls, finishReason: .toolCalls)
        }
    }

    public func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                if case .failure(let error) = await availability() {
                    continuation.finish(throwing: error)
                    return
                }

                let session = makeSession(request)
                do {
                    // FoundationModels yields cumulative snapshots; diff them
                    // into deltas so clients receive incremental text.
                    var emitted = ""
                    let responseStream = session.streamResponse(
                        to: request.prompt,
                        options: options(request)
                    )
                    for try await snapshot in responseStream {
                        let full = snapshot.content
                        guard full.count > emitted.count else { continue }
                        let delta = String(full.dropFirst(emitted.count))
                        emitted = full
                        continuation.yield(GenerationChunk(delta: delta))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ShimError.generationFailed(String(describing: error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

#else

/// Fallback for build environments without FoundationModels. Reports the
/// backend as unavailable rather than failing to compile.
public struct FoundationModelsProvider: LLMProvider {
    private let advertisedModelID: String

    public init(modelID: String) {
        self.advertisedModelID = modelID
    }

    public var models: [ModelInfo] { [ModelInfo(id: advertisedModelID)] }

    public func availability() async -> Result<Void, ShimError> {
        .failure(.modelUnavailable(reason: "FoundationModels not available in this build environment"))
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        throw ShimError.modelUnavailable(reason: "FoundationModels unavailable")
    }

    public func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationChunk, Error> {
        AsyncThrowingStream { $0.finish(throwing: ShimError.modelUnavailable(reason: "FoundationModels unavailable")) }
    }
}

#endif
