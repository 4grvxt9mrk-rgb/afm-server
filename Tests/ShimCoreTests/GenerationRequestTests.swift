import XCTest
@testable import ShimCore

final class GenerationRequestTests: XCTestCase {
    func testInstructionsCollectSystemMessages() {
        let req = GenerationRequest(model: "m", messages: [
            .init(role: .system, content: "Be terse."),
            .init(role: .system, content: "Use British spelling."),
            .init(role: .user, content: "Hi")
        ])
        XCTAssertEqual(req.instructions, "Be terse.\n\nUse British spelling.")
    }

    func testInstructionsNilWhenNoSystemMessages() {
        let req = GenerationRequest(model: "m", messages: [.init(role: .user, content: "Hi")])
        XCTAssertNil(req.instructions)
    }

    func testPromptExcludesSystemAndPrefixesRoles() {
        let req = GenerationRequest(model: "m", messages: [
            .init(role: .system, content: "ignored"),
            .init(role: .user, content: "What is 2+2?"),
            .init(role: .assistant, content: "4"),
            .init(role: .user, content: "And 3+3?")
        ])
        XCTAssertEqual(req.prompt, "User: What is 2+2?\nAssistant: 4\nUser: And 3+3?")
    }

    func testConfigFromEnvironmentDefaults() {
        let config = Config.fromEnvironment([:])
        XCTAssertEqual(config.host, "127.0.0.1")
        XCTAssertEqual(config.port, 11535)
        XCTAssertEqual(config.modelID, "apple-on-device")
    }

    func testConfigFromEnvironmentOverrides() {
        let config = Config.fromEnvironment([
            "SIRI_SHIM_HOST": "0.0.0.0",
            "SIRI_SHIM_PORT": "8080",
            "SIRI_SHIM_MODEL_ID": "siri-local"
        ])
        XCTAssertEqual(config.host, "0.0.0.0")
        XCTAssertEqual(config.port, 8080)
        XCTAssertEqual(config.modelID, "siri-local")
    }
}
