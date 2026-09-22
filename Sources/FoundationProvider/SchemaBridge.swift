import Foundation
import ShimCore

#if canImport(FoundationModels)
import FoundationModels

/// Translates provider-agnostic tool specs into a `GenerationSchema` that
/// constrains the on-device model to a single "which tool + what arguments"
/// decision, and interprets the resulting `GeneratedContent` back into
/// `ToolCall`s.
///
/// The decision schema is an `anyOf` over one branch per offered tool, plus an
/// optional final-answer branch (present only when `tool_choice` lets the model
/// decline to call a tool). Each branch is an object with exactly one property
/// whose *name is the discriminator*: the tool's name for a tool branch, or
/// `finalAnswerKey` for the plain-answer branch. That makes the model's choice
/// unambiguous to read back.
enum SchemaBridge {
    static let finalAnswerKey = "__final_answer__"

    /// Build the decision schema for a request, or `nil` if it can't be built
    /// (in which case the caller should fall back to plain generation).
    static func decisionSchema(for request: GenerationRequest) -> GenerationSchema? {
        let names = NameGen()

        // Which tools are eligible, and whether a final-answer branch is allowed.
        let (eligible, allowFinal): ([ToolSpec], Bool)
        switch request.toolChoice {
        case .none:
            return nil
        case .auto:
            eligible = request.tools
            allowFinal = true
        case .required:
            eligible = request.tools
            allowFinal = false
        case .named(let wanted):
            eligible = request.tools.filter { $0.name == wanted }
            allowFinal = false
        }
        guard !eligible.isEmpty else { return nil }

        var branches: [DynamicGenerationSchema] = eligible.map { toolBranch($0, names: names) }
        if allowFinal { branches.append(finalBranch(names: names)) }

        let root: DynamicGenerationSchema = branches.count == 1
            ? branches[0]
            : DynamicGenerationSchema(name: names.next("Decision"), anyOf: branches)

        return try? GenerationSchema(root: root, dependencies: [])
    }

    /// A human-readable description of the tools, appended to the prompt so the
    /// model knows each tool's *purpose* (the schema alone carries only shapes).
    static func toolGuide(for request: GenerationRequest, allowFinal: Bool) -> String {
        var lines = ["You have access to the following tools. Choose exactly one option."]
        for tool in request.tools {
            let desc = tool.description.map { ": \($0)" } ?? ""
            lines.append("- \(tool.name)\(desc)")
        }
        if allowFinal {
            lines.append("- \(finalAnswerKey): answer the user directly, using no tool.")
        }
        lines.append("Respond only with the structured decision.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Branch construction

    private static func toolBranch(_ tool: ToolSpec, names: NameGen) -> DynamicGenerationSchema {
        let args = convert(tool.parameters ?? .object(properties: [], required: []), names: names)
        let prop = DynamicGenerationSchema.Property(
            name: tool.name,
            description: tool.description,
            schema: args,
            isOptional: false
        )
        return DynamicGenerationSchema(name: names.next("Branch"), properties: [prop])
    }

    private static func finalBranch(names: NameGen) -> DynamicGenerationSchema {
        let prop = DynamicGenerationSchema.Property(
            name: finalAnswerKey,
            description: "Your direct answer to the user.",
            schema: DynamicGenerationSchema(type: String.self),
            isOptional: false
        )
        return DynamicGenerationSchema(name: names.next("Final"), properties: [prop])
    }

    // MARK: - JSONSchema -> DynamicGenerationSchema

    private static func convert(_ schema: JSONSchema, names: NameGen) -> DynamicGenerationSchema {
        switch schema {
        case .object(let properties, _):
            let props = properties.map {
                DynamicGenerationSchema.Property(
                    name: $0.name,
                    description: $0.description,
                    schema: convert($0.schema, names: names),
                    isOptional: !$0.isRequired
                )
            }
            return DynamicGenerationSchema(name: names.next("Object"), properties: props)
        case .array(let items):
            return DynamicGenerationSchema(arrayOf: convert(items, names: names))
        case .string(let enumValues):
            if let enumValues, !enumValues.isEmpty {
                return DynamicGenerationSchema(name: names.next("Enum"), anyOf: enumValues)
            }
            return DynamicGenerationSchema(type: String.self)
        case .integer:
            return DynamicGenerationSchema(type: Int.self)
        case .number:
            return DynamicGenerationSchema(type: Double.self)
        case .boolean:
            return DynamicGenerationSchema(type: Bool.self)
        case .unknown:
            return DynamicGenerationSchema(type: String.self)
        }
    }

    // MARK: - Reading the decision back

    /// Interpret a decoded decision. Returns either the final answer text or the
    /// tool calls to surface to the client.
    enum Decision {
        case finalAnswer(String)
        case toolCalls([ToolCall])
    }

    static func interpret(_ content: GeneratedContent) -> Decision {
        guard
            let data = content.jsonString.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let (key, value) = object.first
        else {
            // Couldn't parse a structured decision; treat the raw text as an answer.
            return .finalAnswer(content.jsonString)
        }

        if key == finalAnswerKey {
            return .finalAnswer((value as? String) ?? "")
        }

        let argumentsJSON = jsonString(from: value)
        let call = ToolCall(
            id: "call_\(UUID().uuidString.prefix(24))",
            name: key,
            argumentsJSON: argumentsJSON
        )
        return .toolCalls([call])
    }

    /// Serialize an extracted argument value back to a compact JSON string, the
    /// shape OpenAI `tool_calls[].function.arguments` uses.
    private static func jsonString(from value: Any) -> String {
        if let dict = value as? [String: Any] {
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "{}"
        }
        // A non-object argument value is unusual; wrap it so clients still get
        // valid JSON.
        if let data = try? JSONSerialization.data(withJSONObject: ["value": value]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }
}

/// Mints unique, stable schema names. `GenerationSchema` requires distinct names
/// across the tree it assembles.
final class NameGen {
    private var counter = 0
    func next(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)_\(counter)"
    }
}

#endif
