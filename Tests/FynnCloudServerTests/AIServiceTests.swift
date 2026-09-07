import XCTest
import Vapor
@testable import FynnCloudServer

final class AIServiceTests: XCTestCase {

    func testEndpointResolution() async throws {
        let app = try await Application.make(.testing)
        defer {
            Task {
                try? await app.asyncShutdown()
            }
        }

        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.fileStorage = LocalFileSystemProvider(storageDirectory: "/tmp")
        let client = app.client
        let logger = app.logger
        let storage = StorageService(provider: app.fileStorage, eventLoop: app.eventLoopGroup.next())
        let files = FileServiceContext(
            db: app.db, logger: logger,
            storage: storage, redis: try await TestRedis.configure(app))

        let s1 = AIService(
            client: client,
            url: "https://api.openai.com",
            apiKey: "test",
            model: "gpt-4o-mini",
            files: files,
            storageService: storage,
            db: app.db,
            logger: logger
        )
        XCTAssertEqual(s1.chatEndpoint.string, "https://api.openai.com/v1/chat/completions")

        let s2 = AIService(
            client: client,
            url: "https://api.openai.com/",
            apiKey: "test",
            model: "gpt-4o-mini",
            files: files,
            storageService: storage,
            db: app.db,
            logger: logger
        )
        XCTAssertEqual(s2.chatEndpoint.string, "https://api.openai.com/v1/chat/completions")

        let s3 = AIService(
            client: client,
            url: "http://localhost:11434/v1/chat/completions",
            apiKey: nil,
            model: "llama3",
            files: files,
            storageService: storage,
            db: app.db,
            logger: logger
        )
        XCTAssertEqual(s3.chatEndpoint.string, "http://localhost:11434/v1/chat/completions")
    }

    func testOpenAIChatRequestEncoding() throws {
        let req = OpenAIChatRequest(
            model: "gpt-4o-mini",
            messages: [
                OpenAIChatMessage(role: "system", content: "You are an assistant"),
                OpenAIChatMessage(role: "user", content: "Find my invoices")
            ],
            tools: [
                OpenAITool(
                    function: OpenAIFunctionDefinition(
                        name: "search_files",
                        description: "Search files",
                        parameters: OpenAIFunctionParameters(
                            properties: [
                                "query": OpenAIFunctionProperty(type: "string", description: "Search query")
                            ],
                            required: ["query"]
                        )
                    )
                )
            ],
            toolChoice: "auto",
            temperature: 0.2
        )

        let data = try JSONEncoder().encode(req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(json?["tool_choice"] as? String, "auto")

        let messages = json?["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?[0]["role"] as? String, "system")
        XCTAssertEqual(messages?[1]["content"] as? String, "Find my invoices")

        let tools = json?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 1)
        XCTAssertEqual(tools?[0]["type"] as? String, "function")
    }

    func testOpenAIChatResponseDecoding() throws {
        let json = """
        {
            "id": "chatcmpl-123",
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": "I found 3 invoices.",
                        "tool_calls": [
                            {
                                "id": "call_abc",
                                "type": "function",
                                "function": {
                                    "name": "search_files",
                                    "arguments": "{\\"query\\": \\"invoice\\"}"
                                }
                            }
                        ]
                    },
                    "finish_reason": "tool_calls"
                }
            ],
            "usage": {
                "prompt_tokens": 15,
                "completion_tokens": 20,
                "total_tokens": 35
            }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: json)
        XCTAssertEqual(decoded.id, "chatcmpl-123")
        XCTAssertEqual(decoded.choices.count, 1)

        let choice = decoded.choices[0]
        XCTAssertEqual(choice.message.role, "assistant")
        XCTAssertEqual(choice.message.content, "I found 3 invoices.")
        XCTAssertEqual(choice.finishReason, "tool_calls")
        XCTAssertEqual(choice.message.toolCalls?.count, 1)
        XCTAssertEqual(choice.message.toolCalls?[0].function.name, "search_files")
        XCTAssertEqual(choice.message.toolCalls?[0].function.arguments, "{\"query\": \"invoice\"}")
    }

    func testByteFormatting() {
        XCTAssertEqual(AIService.formatBytes(500), "500 B")
        XCTAssertEqual(AIService.formatBytes(1536), "1.5 KB")
        XCTAssertEqual(AIService.formatBytes(5 * 1024 * 1024), "5.0 MB")
        XCTAssertEqual(AIService.formatBytes(2 * 1024 * 1024 * 1024), "2.00 GB")
    }

    func testThoughtSignatureExtraContentPreservation() throws {
        let json = """
        {
            "id": "chatcmpl-gemini",
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "tool_calls": [
                            {
                                "id": "call_123",
                                "type": "function",
                                "function": {
                                    "name": "list_files",
                                    "arguments": "{}"
                                },
                                "extra_content": {
                                    "google": {
                                        "thought_signature": "sig_abc123"
                                    }
                                }
                            }
                        ]
                    }
                }
            ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: json)
        let toolCall = decoded.choices[0].message.toolCalls?[0]
        XCTAssertNotNil(toolCall?.extraContent)
        if case .object(let googleObj)? = toolCall?.extraContent?["google"],
           case .string(let sig)? = googleObj["thought_signature"] {
            XCTAssertEqual(sig, "sig_abc123")
        } else {
            XCTFail("Failed to decode thought_signature")
        }

        // Re-encode and ensure extra_content is preserved
        let reEncoded = try JSONEncoder().encode(decoded.choices[0].message)
        let reDecoded = try JSONDecoder().decode(OpenAIChatMessage.self, from: reEncoded)
        let reToolCall = reDecoded.toolCalls?[0]
        XCTAssertNotNil(reToolCall?.extraContent)
    }
}
