import XCTest
import Vapor
@testable import FynnCloudServer

final class EmbeddingServiceTests: XCTestCase {

    func testEndpointResolution() {
        let app = Application(.testing)
        defer { app.shutdown() }

        let client = app.client
        let logger = app.logger

        let s1 = EmbeddingService(client: client, url: "http://localhost:8000", logger: logger)
        XCTAssertEqual(s1.embeddingsEndpoint.string, "http://localhost:8000/v1/embeddings")

        let s2 = EmbeddingService(client: client, url: "http://localhost:8000/", logger: logger)
        XCTAssertEqual(s2.embeddingsEndpoint.string, "http://localhost:8000/v1/embeddings")

        let s3 = EmbeddingService(client: client, url: "https://api.openai.com/v1", logger: logger)
        XCTAssertEqual(s3.embeddingsEndpoint.string, "https://api.openai.com/v1/embeddings")

        let s4 = EmbeddingService(client: client, url: "https://api.openai.com/v1/", logger: logger)
        XCTAssertEqual(s4.embeddingsEndpoint.string, "https://api.openai.com/v1/embeddings")

        let s5 = EmbeddingService(client: client, url: "http://custom:8080/v1/embeddings", logger: logger)
        XCTAssertEqual(s5.embeddingsEndpoint.string, "http://custom:8080/v1/embeddings")

        let s6 = EmbeddingService(client: client, url: "http://custom:8080/embeddings", logger: logger)
        XCTAssertEqual(s6.embeddingsEndpoint.string, "http://custom:8080/embeddings")
    }

    func testOpenAIEmbeddingRequestEncoding() throws {
        let req = EmbeddingService.OpenAIEmbeddingRequest(
            input: .strings(["hello world"]),
            model: "text-embedding-3-small"
        )

        let data = try JSONEncoder().encode(req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["model"] as? String, "text-embedding-3-small")
        XCTAssertEqual(json?["input"] as? [String], ["hello world"])
    }

    func testOpenAIEmbeddingMultimodalRequestEncoding() throws {
        let req = EmbeddingService.OpenAIEmbeddingRequest(
            input: .parts([
                .text("mountain photo"),
                .imageUrl(url: "data:image/jpeg;base64,abc123")
            ]),
            model: "jinaai/jina-clip-v2"
        )

        let data = try JSONEncoder().encode(req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["model"] as? String, "jinaai/jina-clip-v2")
        guard let parts = json?["input"] as? [[String: Any]] else {
            XCTFail("input was not encoded as an array of parts")
            return
        }

        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertEqual(parts[0]["text"] as? String, "mountain photo")

        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        let imgUrl = parts[1]["image_url"] as? [String: Any]
        XCTAssertEqual(imgUrl?["url"] as? String, "data:image/jpeg;base64,abc123")
    }

    func testOpenAIEmbeddingResponseDecoding() throws {
        let json = """
        {
            "object": "list",
            "data": [
                {
                    "object": "embedding",
                    "embedding": [0.12, -0.34, 0.56],
                    "index": 0
                }
            ],
            "model": "jinaai/jina-clip-v2",
            "usage": {
                "prompt_tokens": 5,
                "total_tokens": 5
            }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(EmbeddingService.OpenAIEmbeddingResponse.self, from: json)
        XCTAssertEqual(decoded.object, "list")
        XCTAssertEqual(decoded.model, "jinaai/jina-clip-v2")
        XCTAssertEqual(decoded.data.count, 1)
        XCTAssertEqual(decoded.data[0].index, 0)
        XCTAssertEqual(decoded.data[0].embedding, [0.12, -0.34, 0.56])
    }
}
