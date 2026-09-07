import Vapor

struct AIController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let ai = routes.grouped("api", "ai")
        let protected = ai.grouped(UserPayloadAuthenticator(), UserPayload.guardMiddleware())
        // Chat costs real LLM-provider money and does up to `aiMaxToolIterations` round trips per
        // call, so it gets its own stricter, per-user limit instead of the generic `.api` one.
        let chatRateLimited = protected.grouped(RateLimitMiddleware(category: .ai))

        chatRateLimited.post("chat", use: chat)
        chatRateLimited.post("chat", "stream", use: chatStream)
        protected.get("status", use: status)
    }

    func chat(req: Request) async throws -> AIChatResponse {
        let userID = try req.auth.require(UserPayload.self).getID()
        let chatReq = try req.content.decode(AIChatRequest.self)

        return try await req.aiService().chat(
            messages: chatReq.messages,
            userID: userID,
            contextFileIDs: chatReq.contextFileIDs
        )
    }

    /// Same as `chat`, but streams status/token progress over Server-Sent Events instead of
    /// waiting for the whole response. Events: `status` (tool progress text), `token` (answer text
    /// chunk), `done` (final `AIChatResponse` JSON), `error` (failure reason).
    func chatStream(req: Request) async throws -> Response {
        let userID = try req.auth.require(UserPayload.self).getID()
        let chatReq = try req.content.decode(AIChatRequest.self)
        let aiService = await req.aiService()
        let logger = req.logger

        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: "Content-Type", value: "text/event-stream; charset=utf-8")
        headers.replaceOrAdd(name: "Cache-Control", value: "no-cache")
        headers.replaceOrAdd(name: "Connection", value: "keep-alive")
        headers.replaceOrAdd(name: "X-Accel-Buffering", value: "no")

        let body = Response.Body(
            managedAsyncStream: { writer in
                @Sendable func send<T: Encodable & Sendable>(_ event: String, _ payload: T)
                    async throws
                {
                    let data = try JSONEncoder().encode(payload)
                    let json = String(decoding: data, as: UTF8.self)
                    try await writer.write(
                        .buffer(ByteBuffer(string: "event: \(event)\ndata: \(json)\n\n")))
                }

                do {
                    let result = try await aiService.chat(
                        messages: chatReq.messages,
                        userID: userID,
                        contextFileIDs: chatReq.contextFileIDs
                    ) { event in
                        switch event {
                        case .status(let text):
                            try await send("status", ["text": text])
                        case .token(let text):
                            try await send("token", ["text": text])
                        }
                    }
                    try await send("done", result)
                } catch is CancellationError {
                    // Client disconnected or stopped generation early; nothing more to send.
                } catch {
                    logger.scoped(to: .ai).error("AI stream chat failed: \(error)")
                    let reason =
                        (error as? (any AbortError))?.reason
                        ?? "Failed to get a response from the AI assistant."
                    try? await send("error", ["reason": reason])
                }
            },
            count: -1
        )

        return Response(status: .ok, headers: headers, body: body)
    }

    func status(req: Request) async throws -> AIStatusResponse {
        let settings = req.application.settings

        let enabled = try await settings.get(AppSettings.AiEnabled.self)
        let model = try await settings.get(AppSettings.AiModel.self)
        let url = try await settings.get(AppSettings.AiApiUrl.self)
        let apiKeyRaw = try await settings.get(AppSettings.AiApiKey.self)
        let resolvedApiKey =
            (!apiKeyRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? apiKeyRaw : nil)

        let trimmedUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasApiKey = (resolvedApiKey != nil && !resolvedApiKey!.isEmpty)

        let isConfigured = !trimmedUrl.isEmpty
            && !trimmedModel.isEmpty
            && (hasApiKey || !trimmedUrl.contains("openai.com"))

        return AIStatusResponse(
            enabled: enabled,
            model: trimmedModel,
            configured: isConfigured
        )
    }
}
