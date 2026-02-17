import ArgumentParser
import Darwin
import Foundation
import FoundationModels
import HTTPTypes
import Hummingbird

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

// MARK: - Ollama API Types

private let ollamaModelDisplayName = "Apple Foundation Model"
private let ollamaModelID = "apple-foundation-model"
private let maxRequestBodySize = 1_048_576

struct OllamaGenerateRequest: Decodable, Sendable {
    let model: String?
    let prompt: String
    let system: String?
    let stream: Bool?
    let options: OllamaRequestOptions?
}

struct OllamaMessage: Codable, Sendable {
    let role: String
    let content: String
}

struct OllamaChatRequest: Decodable, Sendable {
    let model: String?
    let messages: [OllamaMessage]
    let stream: Bool?
    let options: OllamaRequestOptions?
}

struct OllamaRequestOptions: Decodable, Sendable {
    let temperature: Double?
    let num_predict: Int?
}

struct OllamaGenerateResponse: Encodable, Sendable {
    let model: String
    let created_at: String
    let response: String
    let done: Bool
}

struct OllamaChatResponse: Encodable, Sendable {
    let model: String
    let created_at: String
    let message: OllamaMessage
    let done: Bool
}

struct OllamaTagsResponse: Encodable, Sendable {
    struct ModelInfo: Encodable, Sendable {
        let name: String
        let model: String
        let modified_at: String
        let size: Int
    }
    let models: [ModelInfo]
}

struct OllamaVersionResponse: Encodable, Sendable {
    let version: String
}

private func currentTimestamp() -> String {
    Date.now.formatted(.iso8601)
}

private func encodeJSONLine(_ value: some Encodable) throws -> ByteBuffer {
    let data = try JSONEncoder().encode(value)
    var buffer = ByteBufferAllocator().buffer(capacity: data.count + 1)
    buffer.writeBytes(data)
    buffer.writeString("\n")
    return buffer
}

private func jsonResponse(_ value: some Encodable) throws -> Response {
    let data = try JSONEncoder().encode(value)
    var buffer = ByteBufferAllocator().buffer(capacity: data.count)
    buffer.writeBytes(data)
    return Response(
        status: .ok,
        headers: HTTPFields([HTTPField(name: .contentType, value: "application/json")]),
        body: .init(byteBuffer: buffer)
    )
}

private func decodeJSON<T: Decodable>(_ type: T.Type, from buffer: ByteBuffer) throws -> T {
    var buf = buffer
    let data = buf.readData(length: buf.readableBytes) ?? Data()
    return try JSONDecoder().decode(type, from: data)
}

private func makeGenerationOptions(from options: OllamaRequestOptions?) -> GenerationOptions {
    var genOptions = GenerationOptions()
    if let temp = options?.temperature {
        genOptions.temperature = temp
    }
    if let numPredict = options?.num_predict {
        genOptions.maximumResponseTokens = numPredict
    }
    return genOptions
}

private func streamingResponse(
    system: String?,
    prompt: String,
    options: GenerationOptions,
    makeChunk: @escaping @Sendable (String, String, Bool) -> some Encodable & Sendable
) -> Response {
    let (byteStream, continuation) = AsyncStream<ByteBuffer>.makeStream()

    Task {
        do {
            let session: LanguageModelSession
            if let system, !system.isEmpty {
                session = LanguageModelSession(instructions: system)
            } else {
                session = LanguageModelSession()
            }

            let stream = session.streamResponse(to: prompt, options: options)
            var printedCount = 0
            for try await partial in stream {
                let content = partial.content
                if content.utf8.count > printedCount {
                    let start = content.utf8.index(content.utf8.startIndex, offsetBy: printedCount)
                    let delta = String(content[start...])
                    printedCount = content.utf8.count
                    let buf = try encodeJSONLine(makeChunk(delta, currentTimestamp(), false))
                    continuation.yield(buf)
                }
            }
            let buf = try encodeJSONLine(makeChunk("", currentTimestamp(), true))
            continuation.yield(buf)
        } catch {
            if let buf = try? encodeJSONLine(makeChunk("", currentTimestamp(), true)) {
                continuation.yield(buf)
            }
        }
        continuation.finish()
    }

    return Response(
        status: .ok,
        headers: HTTPFields([HTTPField(name: .contentType, value: "application/x-ndjson")]),
        body: .init(asyncSequence: byteStream)
    )
}

// MARK: - CLI

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

          # Ollama-compatible API server
          foundation-models-cli --listen 127.0.0.1:11434
        """
    )

    @Argument(help: "Prompt to send to the LLM")
    var prompt: String?

    @Option(name: .long, help: "Start Ollama-compatible API server (host:port)")
    var listen: String?

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
        if listen != nil && prompt != nil {
            throw ValidationError("--listen and prompt cannot be used together")
        }
        if listen == nil && prompt == nil {
            throw ValidationError("Either prompt or --listen must be specified")
        }
    }

    func run() async throws {
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            throw ValidationError("Apple Intelligence model is not available. Please check your device and OS settings.")
        }

        if let listen {
            try await startServer(listen: listen)
        } else {
            try await handlePrompt()
        }
    }

    private func handlePrompt() async throws {
        guard let prompt else { return }

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

    private func startServer(listen: String) async throws {
        let parts = listen.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else {
            throw ValidationError("Invalid listen address. Use host:port format (e.g., 127.0.0.1:11434)")
        }
        let host = String(parts[0])

        let router = Router()

        router.get("/") { _, _ in
            "Ollama is running"
        }

        router.get("/api/version") { _, _ -> Response in
            try jsonResponse(OllamaVersionResponse(version: "0.0.0"))
        }

        router.get("/api/tags") { _, _ -> Response in
            try jsonResponse(OllamaTagsResponse(models: [
                .init(name: ollamaModelDisplayName, model: ollamaModelID, modified_at: currentTimestamp(), size: 0),
            ]))
        }

        router.post("/api/generate") { request, _ -> Response in
            let buffer = try await request.body.collect(upTo: maxRequestBodySize)
            let req = try decodeJSON(OllamaGenerateRequest.self, from: buffer)
            let genOptions = makeGenerationOptions(from: req.options)
            let shouldStream = req.stream ?? true

            if shouldStream {
                return streamingResponse(
                    system: req.system,
                    prompt: req.prompt,
                    options: genOptions
                ) { delta, timestamp, done in
                    OllamaGenerateResponse(
                        model: ollamaModelID,
                        created_at: timestamp,
                        response: delta,
                        done: done
                    )
                }
            } else {
                let session: LanguageModelSession
                if let system = req.system {
                    session = LanguageModelSession(instructions: system)
                } else {
                    session = LanguageModelSession()
                }
                let response = try await session.respond(to: req.prompt, options: genOptions)
                return try jsonResponse(OllamaGenerateResponse(
                    model: ollamaModelID,
                    created_at: currentTimestamp(),
                    response: response.content,
                    done: true
                ))
            }
        }

        router.post("/api/chat") { request, _ -> Response in
            let buffer = try await request.body.collect(upTo: maxRequestBodySize)
            let req = try decodeJSON(OllamaChatRequest.self, from: buffer)
            let genOptions = makeGenerationOptions(from: req.options)

            let systemMessages = req.messages.filter { $0.role == "system" }
            let systemInstruction = systemMessages.map(\.content).joined(separator: "\n")

            let nonSystemMessages = req.messages.filter { $0.role != "system" }
            guard let lastUserMessage = nonSystemMessages.last?.content else {
                return Response(status: .badRequest)
            }

            let prompt: String
            if nonSystemMessages.count > 1 {
                let history = nonSystemMessages.dropLast()
                let context = history.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
                prompt = "Previous conversation:\n\(context)\n\nuser: \(lastUserMessage)"
            } else {
                prompt = lastUserMessage
            }

            let shouldStream = req.stream ?? true

            if shouldStream {
                return streamingResponse(
                    system: systemInstruction.isEmpty ? nil : systemInstruction,
                    prompt: prompt,
                    options: genOptions
                ) { delta, timestamp, done in
                    OllamaChatResponse(
                        model: ollamaModelID,
                        created_at: timestamp,
                        message: OllamaMessage(role: "assistant", content: delta),
                        done: done
                    )
                }
            } else {
                let session: LanguageModelSession
                if !systemInstruction.isEmpty {
                    session = LanguageModelSession(instructions: systemInstruction)
                } else {
                    session = LanguageModelSession()
                }
                let response = try await session.respond(to: prompt, options: genOptions)
                return try jsonResponse(OllamaChatResponse(
                    model: ollamaModelID,
                    created_at: currentTimestamp(),
                    message: OllamaMessage(role: "assistant", content: response.content),
                    done: true
                ))
            }
        }

        let app = Application(
            router: router,
            configuration: .init(address: .hostname(host, port: port))
        )

        print("Ollama-compatible server listening on \(host):\(port)")
        try await app.runService()
    }
}
