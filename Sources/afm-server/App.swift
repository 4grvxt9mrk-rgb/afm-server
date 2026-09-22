import Foundation
import Hummingbird
import ShimCore
import FoundationProvider
import OpenAICompat

@main
struct AFMServer {
    static func main() async throws {
        let config = Config.fromEnvironment()
        let provider = FoundationModelsProvider(modelID: config.modelID)

        // Report availability at startup so misconfiguration is obvious.
        switch await provider.availability() {
        case .success:
            print("✓ On-device model available (advertised as \"\(config.modelID)\")")
        case .failure(let error):
            print("⚠︎ On-device model not ready: \(error). Server will still start; requests will 503.")
        }

        let router = Router()
        OpenAIRoutes(provider: provider).register(on: router)

        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(config.host, port: config.port),
                serverName: "afm-server/\(ShimCore.AFMServer.version)"
            )
        )

        print("→ afm-server \(ShimCore.AFMServer.version) listening on http://\(config.host):\(config.port)  (OpenAI-compatible)")
        try await app.runService()
    }
}
