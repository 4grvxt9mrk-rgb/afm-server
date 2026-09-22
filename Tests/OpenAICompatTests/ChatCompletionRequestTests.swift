import XCTest
@testable import OpenAICompat
import ShimCore

final class ChatCompletionRequestTests: XCTestCase {
    private func decode(_ json: String) throws -> GenerationRequest {
        try JSONDecoder()
            .decode(ChatCompletionRequest.self, from: Data(json.utf8))
            .toDomain()
    }

    func testNullContentDoesNotThrow() throws {
        let req = try decode("""
        { "model": "m", "messages": [ { "role": "assistant", "content": null } ] }
        """)
        // An explicit JSON null decodes as absent content, not a throw.
        XCTAssertNil(req.messages.first?.content)
    }

    func testArrayContentIsFlattenedToText() throws {
        let req = try decode("""
        {
          "model": "m",
          "messages": [
            { "role": "user", "content": [
              { "type": "text", "text": "hello" },
              { "type": "text", "text": "world" }
            ] }
          ]
        }
        """)
        XCTAssertEqual(req.messages.first?.content, "hello\nworld")
    }

    func testToolsAndToolChoiceDecode() throws {
        let req = try decode("""
        {
          "model": "m",
          "messages": [ { "role": "user", "content": "route me" } ],
          "tools": [
            {
              "type": "function",
              "function": {
                "name": "web_search",
                "description": "Search the web",
                "parameters": {
                  "type": "object",
                  "properties": { "query": { "type": "string" } },
                  "required": ["query"]
                }
              }
            }
          ],
          "tool_choice": "required"
        }
        """)

        XCTAssertEqual(req.tools.count, 1)
        XCTAssertEqual(req.tools.first?.name, "web_search")
        XCTAssertEqual(req.tools.first?.description, "Search the web")
        XCTAssertNotNil(req.tools.first?.parameters)
        XCTAssertEqual(req.toolChoice, .required)
        XCTAssertTrue(req.wantsToolCalling)
    }

    func testNamedToolChoiceDecodes() throws {
        let req = try decode("""
        {
          "model": "m",
          "messages": [ { "role": "user", "content": "hi" } ],
          "tools": [ { "type": "function", "function": { "name": "t" } } ],
          "tool_choice": { "type": "function", "function": { "name": "t" } }
        }
        """)
        XCTAssertEqual(req.toolChoice, .named("t"))
    }

    func testToolChoiceNoneDisablesToolCalling() throws {
        let req = try decode("""
        {
          "model": "m",
          "messages": [ { "role": "user", "content": "hi" } ],
          "tools": [ { "type": "function", "function": { "name": "t" } } ],
          "tool_choice": "none"
        }
        """)
        XCTAssertEqual(req.toolChoice, .none)
        XCTAssertFalse(req.wantsToolCalling)
    }

    func testIncomingToolResultTurnDecodes() throws {
        // The follow-up request AnythingLLM sends after executing a tool.
        let req = try decode("""
        {
          "model": "m",
          "messages": [
            { "role": "user", "content": "weather?" },
            { "role": "assistant", "content": null, "tool_calls": [
              { "id": "call_1", "type": "function",
                "function": { "name": "get_weather", "arguments": "{\\"city\\":\\"Paris\\"}" } }
            ] },
            { "role": "tool", "tool_call_id": "call_1", "name": "get_weather", "content": "18C" }
          ]
        }
        """)

        let assistant = req.messages[1]
        XCTAssertEqual(assistant.toolCalls.first?.id, "call_1")
        XCTAssertEqual(assistant.toolCalls.first?.name, "get_weather")
        XCTAssertEqual(assistant.toolCalls.first?.argumentsJSON, "{\"city\":\"Paris\"}")

        let tool = req.messages[2]
        XCTAssertEqual(tool.role, .tool)
        XCTAssertEqual(tool.toolCallID, "call_1")
        XCTAssertEqual(tool.content, "18C")

        // Flattened prompt replays the tool round-trip as context.
        XCTAssertTrue(req.prompt.contains("get_weather"))
        XCTAssertTrue(req.prompt.contains("Tool get_weather result: 18C"))
    }
}

final class ChatCompletionResponseTests: XCTestCase {
    private func encodeToObject(_ result: GenerationResult) throws -> [String: Any] {
        let response = ChatCompletionResponse.make(model: "m", result: result)
        let data = try JSONEncoder().encode(response)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testPlainAnswerEncodesContentAndStop() throws {
        let obj = try encodeToObject(GenerationResult(text: "hello", finishReason: .stop))
        let choice = try XCTUnwrap((obj["choices"] as? [[String: Any]])?.first)
        let message = try XCTUnwrap(choice["message"] as? [String: Any])
        XCTAssertEqual(message["content"] as? String, "hello")
        XCTAssertNil(message["tool_calls"])
        XCTAssertEqual(choice["finish_reason"] as? String, "stop")
    }

    func testToolCallEncodesNullContentAndToolCalls() throws {
        let result = GenerationResult(
            text: "",
            toolCalls: [ToolCall(id: "call_1", name: "web_search", argumentsJSON: "{\"query\":\"cats\"}")],
            finishReason: .toolCalls
        )
        let obj = try encodeToObject(result)
        let choice = try XCTUnwrap((obj["choices"] as? [[String: Any]])?.first)
        XCTAssertEqual(choice["finish_reason"] as? String, "tool_calls")

        let message = try XCTUnwrap(choice["message"] as? [String: Any])
        XCTAssertTrue(message["content"] is NSNull)

        let calls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?["id"] as? String, "call_1")
        XCTAssertEqual(calls.first?["type"] as? String, "function")
        let fn = try XCTUnwrap(calls.first?["function"] as? [String: Any])
        XCTAssertEqual(fn["name"] as? String, "web_search")
        XCTAssertEqual(fn["arguments"] as? String, "{\"query\":\"cats\"}")
    }
}
