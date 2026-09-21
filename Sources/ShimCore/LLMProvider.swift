import Foundation

/// The seam between the API layer and any model backend.
///
/// `FoundationProvider` implements this over Apple's on-device model; a mock
/// or a future Ollama-native backend can implement the same protocol without
/// the routing layer knowing the difference.
public protocol LLMProvider: Sendable {
    /// Models this provider advertises to `/v1/models`.
    var models: [ModelInfo] { get }

    /// Whether the backend is ready to serve; a human-readable reason if not.
    func availability() async -> Result<Void, ShimError>

    /// Produce a full completion.
    func generate(_ request: GenerationRequest) async throws -> GenerationResult

    /// Produce a stream of text deltas.
    func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationChunk, Error>
}
