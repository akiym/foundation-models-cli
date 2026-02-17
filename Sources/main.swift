import ArgumentParser
import Darwin
import Foundation
import FoundationModels

enum FieldType: String, CaseIterable {
    case string = "String"
    case int = "Int"
    case double = "Double"
    case bool = "Bool"
    case stringArray = "[String]"
    case intArray = "[Int]"
    case doubleArray = "[Double]"
    case boolArray = "[Bool]"

    init(parsing raw: String) throws {
        guard let value = FieldType(rawValue: raw) else {
            let supported = Self.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("Unsupported type: \(raw) (supported: \(supported))")
        }
        self = value
    }

    var dynamicSchema: DynamicGenerationSchema {
        switch self {
        case .string:      DynamicGenerationSchema(type: String.self)
        case .int:         DynamicGenerationSchema(type: Int.self)
        case .double:      DynamicGenerationSchema(type: Double.self)
        case .bool:        DynamicGenerationSchema(type: Bool.self)
        case .stringArray: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self))
        case .intArray:    DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: Int.self))
        case .doubleArray: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: Double.self))
        case .boolArray:   DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: Bool.self))
        }
    }

    func extractValue(from content: GeneratedContent, forProperty name: String) throws -> Any {
        switch self {
        case .string:      try content.value(String.self, forProperty: name)
        case .int:         try content.value(Int.self, forProperty: name)
        case .double:      try content.value(Double.self, forProperty: name)
        case .bool:        try content.value(Bool.self, forProperty: name)
        case .stringArray: try content.value([String].self, forProperty: name)
        case .intArray:    try content.value([Int].self, forProperty: name)
        case .doubleArray: try content.value([Double].self, forProperty: name)
        case .boolArray:   try content.value([Bool].self, forProperty: name)
        }
    }
}

struct FieldSpec {
    let name: String
    let type: FieldType
    let description: String

    init(parsing raw: String) throws {
        let parts = raw.split(separator: ":", maxSplits: 2)
        guard parts.count == 3 else {
            throw ValidationError("Invalid field format: \(raw) (expected name:Type:description)")
        }
        self.name = String(parts[0])
        self.type = try FieldType(parsing: String(parts[1]))
        self.description = String(parts[2])
    }
}

@main
struct FoundationModelsCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "foundation-models-cli",
        abstract: "A simple CLI to send prompts to the on-device LLM using FoundationModels",
        discussion: """
        Examples:
          # Plain text output
          foundation-models-cli "Review Inception"

          # Streaming output
          foundation-models-cli "Tell me a story" -s

          # Structured output with Guided Generation
          foundation-models-cli "Review Inception" -f "title:String:The movie title" -f "rating:Int:Rating from 1 to 5" -f "summary:String:A short review"

          # Array types
          foundation-models-cli "List 3 Japanese dishes" -f "dishes:[String]:List of dish names" -f "count:Int:Number of dishes"
        """
    )

    @Argument(help: "Prompt to send to the LLM")
    var prompt: String

    @Option(name: .shortAndLong, help: "System instructions")
    var instructions: String?

    @Option(name: .shortAndLong, help: "Generation temperature (0.0-2.0)")
    var temperature: Double?

    @Option(name: .shortAndLong, help: "Maximum response token count")
    var maxTokens: Int?

    @Flag(name: .long, help: "Use greedy sampling (deterministic output)")
    var greedy: Bool = false

    @Flag(name: .shortAndLong, help: "Enable streaming output")
    var stream: Bool = false

    @Option(name: .shortAndLong, help: """
        Structured output field (name:Type:description). \
        Can be specified multiple times. \
        Types: String, Int, Double, Bool, [String], [Int], [Double], [Bool]
        """)
    var field: [String] = []

    func validate() throws {
        if stream && !field.isEmpty {
            throw ValidationError("--stream and --field cannot be used together")
        }
    }

    func run() async throws {
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            throw ValidationError("Apple Intelligence model is not available. Please check your device and OS settings.")
        }

        let session: LanguageModelSession
        if let instructions {
            session = LanguageModelSession(instructions: instructions)
        } else {
            session = LanguageModelSession()
        }

        var options = GenerationOptions()
        if let temperature {
            options.temperature = temperature
        }
        if let maxTokens {
            options.maximumResponseTokens = maxTokens
        }
        if greedy {
            options.sampling = .greedy
        }

        if field.isEmpty {
            if stream {
                let stream = session.streamResponse(to: prompt, options: options)
                var printedCount = 0
                for try await partial in stream {
                    let content = partial.content
                    if content.utf8.count > printedCount {
                        let start = content.utf8.index(content.utf8.startIndex, offsetBy: printedCount)
                        print(String(content[start...]), terminator: "")
                        fflush(stdout)
                        printedCount = content.utf8.count
                    }
                }
                print()
            } else {
                let response = try await session.respond(to: prompt, options: options)
                print(response.content)
            }
        } else {
            let fields = try field.map { try FieldSpec(parsing: $0) }
            let properties = fields.map { field in
                DynamicGenerationSchema.Property(
                    name: field.name,
                    description: field.description,
                    schema: field.type.dynamicSchema
                )
            }
            let schema = try GenerationSchema(
                root: DynamicGenerationSchema(name: "output", properties: properties),
                dependencies: []
            )
            let response = try await session.respond(to: prompt, schema: schema, options: options)
            var json: [String: Any] = [:]
            for field in fields {
                json[field.name] = try field.type.extractValue(from: response.content, forProperty: field.name)
            }
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            guard let output = String(data: data, encoding: .utf8) else {
                throw ValidationError("Failed to encode JSON output")
            }
            print(output)
        }
    }
}
