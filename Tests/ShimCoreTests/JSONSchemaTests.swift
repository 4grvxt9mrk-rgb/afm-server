import XCTest
@testable import ShimCore

final class JSONSchemaTests: XCTestCase {
    private func decode(_ json: String) throws -> JSONSchema {
        try JSONDecoder().decode(JSONSchema.self, from: Data(json.utf8))
    }

    func testDecodesTypicalToolParameters() throws {
        let schema = try decode("""
        {
          "type": "object",
          "properties": {
            "location": { "type": "string", "description": "City name" },
            "units": { "type": "string", "enum": ["celsius", "fahrenheit"] },
            "days": { "type": "integer" }
          },
          "required": ["location"]
        }
        """)

        guard case .object(let props, let required) = schema else {
            return XCTFail("expected object, got \(schema)")
        }
        XCTAssertEqual(required, ["location"])
        // Properties are sorted by name for determinism.
        XCTAssertEqual(props.map(\.name), ["days", "location", "units"])

        let location = props.first { $0.name == "location" }
        XCTAssertEqual(location?.description, "City name")
        XCTAssertTrue(location?.isRequired == true)
        XCTAssertEqual(location?.schema, .string(enumValues: nil))

        let units = props.first { $0.name == "units" }
        XCTAssertEqual(units?.isRequired, false)
        XCTAssertEqual(units?.schema, .string(enumValues: ["celsius", "fahrenheit"]))

        XCTAssertEqual(props.first { $0.name == "days" }?.schema, .integer)
    }

    func testDecodesArrayAndNestedObject() throws {
        let schema = try decode("""
        {
          "type": "object",
          "properties": {
            "tags": { "type": "array", "items": { "type": "string" } },
            "nested": { "type": "object", "properties": { "n": { "type": "number" } } }
          }
        }
        """)
        guard case .object(let props, _) = schema else { return XCTFail("expected object") }
        XCTAssertEqual(props.first { $0.name == "tags" }?.schema, .array(items: .string(enumValues: nil)))
        if case .object(let nestedProps, _)? = props.first(where: { $0.name == "nested" })?.schema {
            XCTAssertEqual(nestedProps.first?.schema, .number)
        } else {
            XCTFail("expected nested object")
        }
    }

    func testUntypedPropertiesTreatedAsObject() throws {
        // Some clients omit "type" on the root parameters object.
        let schema = try decode(#"{ "properties": { "x": { "type": "boolean" } } }"#)
        guard case .object(let props, _) = schema else { return XCTFail("expected object") }
        XCTAssertEqual(props.first?.schema, .boolean)
    }

    func testNonObjectFallsBackToUnknown() throws {
        XCTAssertEqual(try decode("true"), .unknown)
    }
}
