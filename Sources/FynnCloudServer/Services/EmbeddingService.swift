import Vapor
import Foundation
import NIOConcurrencyHelpers

/// Service for generating embeddings via standard OpenAI-compatible `/v1/embeddings` API.
/// Supports text, images, and combined multimodal embedding generation.
struct EmbeddingService: Sendable {
    let client: any Client
    let url: String
    let apiKey: String?
    let model: String
    let logger: Logger

    init(
        client: any Client,
        url: String,
        apiKey: String? = nil,
        model: String = "jinaai/jina-clip-v2",
        logger: Logger
    ) {
        self.client = client
        self.url = url
        self.apiKey = apiKey
        self.model = model
        self.logger = logger
    }

    /// Resolves the full `/v1/embeddings` endpoint URL.
    static func resolveEmbeddingsEndpoint(for url: String) -> URI {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/embeddings") {
            return URI(string: trimmed)
        }
        if trimmed.hasSuffix("/") {
            let withoutSlash = String(trimmed.dropLast())
            if withoutSlash.hasSuffix("/v1") {
                return URI(string: "\(withoutSlash)/embeddings")
            }
            return URI(string: "\(withoutSlash)/v1/embeddings")
        }
        if trimmed.hasSuffix("/v1") {
            return URI(string: "\(trimmed)/embeddings")
        }
        return URI(string: "\(trimmed)/v1/embeddings")
    }

    var embeddingsEndpoint: URI {
        Self.resolveEmbeddingsEndpoint(for: url)
    }

    /// Embeds text as a search query or document.
    /// - Parameter timeout: Optional upper bound (in seconds) on the request. When exceeded the call throws
    ///   `EmbeddingTimeoutError`, letting latency-sensitive callers (e.g. search) fail fast and fall back.
    func getTextEmbedding(for text: String, promptName: String = "query", timeout: TimeInterval? = nil) async throws -> [Float] {
        let work: @Sendable () async throws -> [Float] = {
            let log = self.logger.scoped(to: .embedding)
            let endpoint = self.embeddingsEndpoint
            let taskName = (promptName == "passage") ? "retrieval.passage" : "retrieval.query"
            let reqBody = OpenAIEmbeddingRequest(
                input: .strings([text]),
                model: self.model,
                task: taskName,
                dimensions: 1024
            )

            log.debug(
                "Requesting text embedding",
                metadata: [
                    "endpoint": .string(endpoint.string),
                    "model": .string(self.model),
                ]
            )
            let response = try await self.postWithRetry(endpoint, body: reqBody)

            guard response.status == .ok else {
                log.error(
                    "Text embedding request failed",
                    metadata: [
                        "status": .stringConvertible(response.status.code),
                        "endpoint": .string(endpoint.string),
                    ]
                )
                throw Abort(.internalServerError, reason: "Embedding request failed with status: \(response.status)")
            }

            let resBody = try response.content.decode(OpenAIEmbeddingResponse.self)
            guard let first = resBody.data.first(where: { $0.index == 0 }) ?? resBody.data.first else {
                throw Abort(.internalServerError, reason: "No text embedding returned")
            }
            return first.embedding
        }

        guard let timeout else {
            return try await work()
        }
        return try await Self.withTimeout(timeout, work)
    }

    /// Embeds an image from a file path using standard data URI multimodal format.
    func getImageEmbedding(fromFile filePath: String) async throws -> [Float] {
        let log = logger.scoped(to: .embedding)
        let imageData = try Data(contentsOf: URL(fileURLWithPath: filePath))
        let ext = URL(fileURLWithPath: filePath).pathExtension.lowercased()
        let mimeType = Self.mimeType(for: ext)
        let base64Image = imageData.base64EncodedString()
        let dataURI = "data:\(mimeType);base64,\(base64Image)"

        let endpoint = self.embeddingsEndpoint
        let reqBody = OpenAIEmbeddingRequest(
            input: .parts([
                .imageUrl(url: dataURI)
            ]),
            model: self.model,
            task: "retrieval.passage",
            dimensions: 1024
        )

        log.debug(
            "Requesting image embedding",
            metadata: [
                "endpoint": .string(endpoint.string),
                "model": .string(self.model),
            ]
        )
        let response = try await self.postWithRetry(endpoint, body: reqBody)

        guard response.status == .ok else {
            log.error(
                "Image embedding request failed",
                metadata: [
                    "status": .stringConvertible(response.status.code),
                    "endpoint": .string(endpoint.string),
                ]
            )
            throw Abort(.internalServerError, reason: "Image embedding request failed with status: \(response.status)")
        }

        let resBody = try response.content.decode(OpenAIEmbeddingResponse.self)
        guard let first = resBody.data.first(where: { $0.index == 0 }) ?? resBody.data.first else {
            throw Abort(.internalServerError, reason: "No image embedding returned")
        }
        return first.embedding
    }

    /// Embeds text and image together in a single request. Returns the averaged vector.
    /// The API returns [textEmbedding, imageEmbedding] in order - we average them.
    func getCombinedEmbedding(text: String, imageFilePath: String) async throws -> [Float] {
        let log = logger.scoped(to: .embedding)
        let imageData = try Data(contentsOf: URL(fileURLWithPath: imageFilePath))
        let ext = URL(fileURLWithPath: imageFilePath).pathExtension.lowercased()
        let mimeType = Self.mimeType(for: ext)
        let base64Image = imageData.base64EncodedString()
        let dataURI = "data:\(mimeType);base64,\(base64Image)"

        let endpoint = self.embeddingsEndpoint
        let reqBody = OpenAIEmbeddingRequest(
            input: .parts([
                .text(text),
                .imageUrl(url: dataURI)
            ]),
            model: self.model,
            task: "retrieval.passage",
            dimensions: 1024
        )

        log.debug(
            "Requesting combined text+image embedding",
            metadata: [
                "endpoint": .string(endpoint.string),
                "model": .string(self.model),
            ]
        )
        let response = try await self.postWithRetry(endpoint, body: reqBody)

        guard response.status == .ok else {
            log.warning(
                "Combined embedding request returned non-OK status; falling back to text embedding",
                metadata: [
                    "status": .stringConvertible(response.status.code),
                    "endpoint": .string(endpoint.string),
                ]
            )
            return try await getTextEmbedding(for: text)
        }

        let resBody = try response.content.decode(OpenAIEmbeddingResponse.self)
        guard resBody.data.count >= 2 else {
            guard let first = resBody.data.first?.embedding else {
                throw Abort(.internalServerError, reason: "No embedding returned")
            }
            return first
        }

        let sorted = resBody.data.sorted(by: { $0.index < $1.index })
        let textEmb = sorted[0].embedding
        let imageEmb = sorted[1].embedding
        return zip(textEmb, imageEmb).map { ($0 + $1) / 2.0 }
    }


    private func postWithRetry(_ endpoint: URI, body: OpenAIEmbeddingRequest, maxRetries: Int = 4) async throws -> ClientResponse {
        var delaySeconds: UInt64 = 1
        for attempt in 0..<maxRetries {
            let response = try await client.post(endpoint) { req in
                try req.content.encode(body)
                req.headers.contentType = .json
                if let apiKey = self.apiKey, !apiKey.isEmpty {
                    req.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
                }
            }
            if response.status == .tooManyRequests {
                self.logger.scoped(to: .embedding).warning(
                    "Embedding API returned 429 Too Many Requests; backing off and retrying",
                    metadata: [
                        "attempt": .stringConvertible(attempt + 1),
                        "delaySeconds": .stringConvertible(delaySeconds)
                    ]
                )
                try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                delaySeconds *= 2
                continue
            }
            return response
        }
        return try await client.post(endpoint) { req in
            try req.content.encode(body)
            req.headers.contentType = .json
            if let apiKey = self.apiKey, !apiKey.isEmpty {
                req.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
            }
        }
    }

    private static func mimeType(for ext: String) -> String {
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        default: return "image/jpeg"
        }
    }

    // MARK: - OpenAI DTOs

    enum MultimodalContentPart: Codable, Sendable {
        case text(String)
        case imageUrl(url: String)

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case image
            case imageUrl = "image_url"
        }

        struct ImageURLPayload: Codable, Sendable {
            let url: String
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let text = try? container.decode(String.self, forKey: .text) {
                self = .text(text)
            } else if let img = try? container.decode(String.self, forKey: .image) {
                self = .imageUrl(url: img)
            } else if let payload = try? container.decode(ImageURLPayload.self, forKey: .imageUrl) {
                self = .imageUrl(url: payload.url)
            } else {
                let type = try container.decode(String.self, forKey: .type)
                if type == "text" {
                    let text = try container.decode(String.self, forKey: .text)
                    self = .text(text)
                } else {
                    let payload = try container.decode(ImageURLPayload.self, forKey: .imageUrl)
                    self = .imageUrl(url: payload.url)
                }
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let str):
                try container.encode("text", forKey: .type)
                try container.encode(str, forKey: .text)
            case .imageUrl(let url):
                try container.encode("image_url", forKey: .type)
                try container.encode(ImageURLPayload(url: url), forKey: .imageUrl)
            }
        }
    }

    enum EmbeddingInput: Codable, Sendable {
        case string(String)
        case strings([String])
        case parts([MultimodalContentPart])

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let single = try? container.decode(String.self) {
                self = .string(single)
            } else if let list = try? container.decode([String].self) {
                self = .strings(list)
            } else if let parts = try? container.decode([MultimodalContentPart].self) {
                self = .parts(parts)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid EmbeddingInput format")
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let s):
                try container.encode(s)
            case .strings(let list):
                try container.encode(list)
            case .parts(let parts):
                try container.encode(parts)
            }
        }
    }

    struct OpenAIEmbeddingRequest: Content {
        let input: EmbeddingInput
        let model: String
        let task: String?
        let dimensions: Int?
        let encodingFormat: String?

        init(input: EmbeddingInput, model: String, task: String? = nil, dimensions: Int? = 1024, encodingFormat: String? = nil) {
            self.input = input
            self.model = model
            self.task = task
            self.dimensions = dimensions
            self.encodingFormat = encodingFormat
        }

        enum CodingKeys: String, CodingKey {
            case input, model, task, dimensions
            case encodingFormat = "encoding_format"
        }
    }

    struct OpenAIEmbeddingResponse: Content {
        struct EmbeddingData: Content {
            let object: String?
            let embedding: [Float]
            let index: Int
        }
        let object: String?
        let data: [EmbeddingData]
        let model: String?
    }

    // MARK: - Timeout support

    /// Races `operation` against a deadline and returns whichever finishes first.
    ///
    /// Unlike a `withThrowingTaskGroup`-based timeout, this does **not** wait for the operation to
    /// finish once the deadline is hit. Vapor's `Client` bridges an `EventLoopFuture` via `.get()`,
    /// which ignores Swift-concurrency cancellation, so a task group would block until the request's
    /// own connect/read timeout. Here the losing task is abandoned (best-effort cancelled) and the
    /// caller is unblocked immediately when the deadline fires.
    static func withTimeout<T: Sendable>(
        _ timeout: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let hasResumed = NIOLockedValueBox(false)
        // Returns true only for the first caller, guaranteeing the continuation resumes exactly once.
        @Sendable func claim() -> Bool {
            hasResumed.withLockedValue { resumed in
                if resumed { return false }
                resumed = true
                return true
            }
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let work = Task {
                do {
                    let value = try await operation()
                    if claim() { continuation.resume(returning: value) }
                } catch {
                    if claim() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                if claim() {
                    work.cancel()
                    continuation.resume(throwing: EmbeddingTimeoutError())
                }
            }
        }
    }
}

/// Thrown when an embedding request exceeds its caller-supplied timeout.
struct EmbeddingTimeoutError: Error, CustomStringConvertible {
    var description: String { "Embedding request timed out" }
}

extension Request {
    var embedding: EmbeddingService {
        EmbeddingService(
            client: self.client,
            url: AppSettings.EmbeddingUrl.defaultValue,
            apiKey: nil,
            model: AppSettings.EmbeddingModel.defaultValue,
            logger: self.logger
        )
    }
}
