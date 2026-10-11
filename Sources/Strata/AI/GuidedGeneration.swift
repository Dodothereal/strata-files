import Foundation
import FoundationModels

// Guided generation without the @Generable macro.
//
// The FoundationModels macros (`@Generable`, `@Guide`) need the `FoundationModelsMacros` compiler plugin, which ships with Xcode but
// not with the Command Line Tools this package builds with. `DynamicGenerationSchema` gives the same constrained decoding at
// runtime: the model can only produce output that fits the schema (enums, arrays with counts, optional fields), and the result
// comes back as `GeneratedContent`, read here by key.

/// Small builders for `DynamicGenerationSchema`.
nonisolated enum Schema {
    struct Field {
        let name: String
        let description: String?
        let schema: DynamicGenerationSchema
        let optional: Bool
    }

    static func string() -> DynamicGenerationSchema { DynamicGenerationSchema(type: String.self) }

    static func integer(_ range: ClosedRange<Int>? = nil) -> DynamicGenerationSchema {
        DynamicGenerationSchema(type: Int.self, guides: range.map { [.range($0)] } ?? [])
    }

    static func choice(_ name: String, _ values: [String]) -> DynamicGenerationSchema {
        DynamicGenerationSchema(name: name, anyOf: values)
    }

    static func array(_ item: DynamicGenerationSchema, min: Int? = nil, max: Int? = nil) -> DynamicGenerationSchema {
        DynamicGenerationSchema(arrayOf: item, minimumElements: min, maximumElements: max)
    }

    static func field(_ name: String, _ description: String? = nil, _ schema: DynamicGenerationSchema, optional: Bool = false) -> Field {
        Field(name: name, description: description, schema: schema, optional: optional)
    }

    static func object(_ name: String, _ description: String? = nil, _ fields: [Field]) -> DynamicGenerationSchema {
        DynamicGenerationSchema(name: name, description: description, properties: fields.map {
            DynamicGenerationSchema.Property(name: $0.name, description: $0.description, schema: $0.schema, isOptional: $0.optional)
        })
    }

    static func root(_ schema: DynamicGenerationSchema, _ dependencies: [DynamicGenerationSchema] = []) throws -> GenerationSchema {
        try GenerationSchema(root: schema, dependencies: dependencies)
    }
}

/// Reading `GeneratedContent` by key. Works on partial content while streaming (missing keys read as nil).
nonisolated extension GeneratedContent {
    subscript(key: String) -> GeneratedContent? {
        if case let .structure(properties, _) = kind { return properties[key] }
        return nil
    }

    var string: String? {
        if case let .string(value) = kind { return value }
        return nil
    }

    /// A non-empty, trimmed string (the model sometimes fills optional strings with "" or "none").
    var meaningfulString: String? {
        guard let value = string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              !["none", "null", "n/a", "nil", "-"].contains(value.lowercased()) else { return nil }
        return value
    }

    var number: Double? {
        if case let .number(value) = kind { return value }
        if case let .string(value) = kind { return Double(value) }
        return nil
    }

    var integer: Int? { number.map { Int($0.rounded()) } }

    var array: [GeneratedContent] {
        if case let .array(values) = kind { return values }
        return []
    }

    var strings: [String] { array.compactMap(\.meaningfulString) }
}

/// Runs model work with a deadline, so a slow or stuck model never blocks a fallback.
nonisolated enum Deadline {
    struct Expired: Error {}

    static func run<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw Expired()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Expired() }
            return first
        }
    }
}
