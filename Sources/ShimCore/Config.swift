import Foundation

/// Runtime configuration, sourced from environment variables so the shim can
/// be pointed at a different host/port without a rebuild.
public struct Config: Sendable {
    public let host: String
    public let port: Int

    /// The model id advertised over the API and accepted in requests.
    /// Clients that hardcode a model name can be satisfied by this alias.
    public let modelID: String

    public init(host: String, port: Int, modelID: String) {
        self.host = host
        self.port = port
        self.modelID = modelID
    }

    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Config {
        Config(
            host: env["AFM_HOST"] ?? "127.0.0.1",
            port: env["AFM_PORT"].flatMap(Int.init) ?? 11535,
            modelID: env["AFM_MODEL_ID"] ?? "apple-on-device"
        )
    }
}
