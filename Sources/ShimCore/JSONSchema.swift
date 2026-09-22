import Foundation

/// A minimal, provider-agnostic model of the subset of JSON Schema that OpenAI
/// tool/function `parameters` use in practice.
///
/// This lives in `ShimCore` on purpose: it carries no dependency on Apple's
/// `FoundationModels`. The `FoundationProvider` layer translates it into a
/// `DynamicGenerationSchema` for constrained decoding; a different backend
/// could translate it into whatever its own guided-generation API wants.
public indirect enum JSONSchema: Sendable, Equatable {
    /// An object with named properties; `required` lists the mandatory ones.
    case object(properties: [Property], required: [String])
    /// A homogeneous array.
    case array(items: JSONSchema)
    /// A string, optionally constrained to an enumeration of literals.
    case string(enumValues: [String]?)
    /// An integer (whole number).
    case integer
    /// A floating-point / arbitrary number.
    case number
    /// A boolean.
    case boolean
    /// A schema we don't model; treated as a free-form string downstream.
    case unknown

    public struct Property: Sendable, Equatable {
        public let name: String
        public let description: String?
        public let schema: JSONSchema
        public let isRequired: Bool

        public init(name: String, description: String?, schema: JSONSchema, isRequired: Bool) {
            self.name = name
            self.description = description
            self.schema = schema
            self.isRequired = isRequired
        }
    }
}

extension JSONSchema: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, properties, required, items, description
        case enumValues = "enum"
    }

    public init(from decoder: Decoder) throws {
        // Tolerate anything that isn't a JSON object (e.g. `true`) by falling
        // back to `.unknown` rather than throwing the whole request out.
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = .unknown
            return
        }

        // `type` may be a string or, less commonly, an array of strings; we key
        // off the first recognized value.
        var type = Self.decodeType(from: container)
        let enumValues = (try? container.decodeIfPresent([String].self, forKey: .enumValues)) ?? nil

        // A `properties` map with no explicit `type` is an object in practice.
        if type == nil && container.contains(.properties) { type = "object" }

        switch type {
        case "object":
            let rawProps = (try? container.decodeIfPresent([String: JSONSchema].self, forKey: .properties)) ?? nil
            let required = (try? container.decodeIfPresent([String].self, forKey: .required)) ?? nil ?? []
            let descriptions = Self.propertyDescriptions(from: container)
            let props: [Property] = (rawProps ?? [:]).map { key, schema in
                Property(
                    name: key,
                    description: descriptions[key],
                    schema: schema,
                    isRequired: required.contains(key)
                )
            }
            // Stable ordering keeps generated schemas deterministic.
            self = .object(properties: props.sorted { $0.name < $1.name }, required: required)
        case "array":
            let items = (try? container.decodeIfPresent(JSONSchema.self, forKey: .items)) ?? nil ?? .unknown
            self = .array(items: items)
        case "string":
            self = .string(enumValues: enumValues)
        case "integer":
            self = .integer
        case "number":
            self = .number
        case "boolean":
            self = .boolean
        default:
            // An `enum` with no explicit type is a string enum in OpenAI usage.
            if let enumValues { self = .string(enumValues: enumValues) }
            else { self = .unknown }
        }
    }

    private static func decodeType(from container: KeyedDecodingContainer<CodingKeys>) -> String? {
        if let single = try? container.decodeIfPresent(String.self, forKey: .type) { return single }
        if let many = try? container.decodeIfPresent([String].self, forKey: .type) {
            // Prefer the first non-"null" entry (nullable unions).
            return many.first { $0 != "null" } ?? many.first
        }
        return nil
    }

    /// Pull each property's `description` without a second full decode pass.
    private static func propertyDescriptions(from container: KeyedDecodingContainer<CodingKeys>) -> [String: String] {
        struct Described: Decodable { let description: String? }
        guard let raw = try? container.decodeIfPresent([String: Described].self, forKey: .properties) else {
            return [:]
        }
        return raw.compactMapValues(\.description)
    }
}
