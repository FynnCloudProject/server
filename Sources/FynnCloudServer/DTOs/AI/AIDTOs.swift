import Vapor
import Foundation

// MARK: - Client facing DTOs

public struct AIChatRequest: Content, Sendable {
    public var messages: [AIChatMessage]
    public var contextFileIDs: [UUID]?

    public init(messages: [AIChatMessage], contextFileIDs: [UUID]? = nil) {
        self.messages = messages
        self.contextFileIDs = contextFileIDs
    }
}

public struct AIChatMessage: Content, Sendable {
    public var id: String?
    public var role: String
    public var content: String?
    public var name: String?
    public var toolCalls: [AIToolCall]?
    public var toolCallId: String?
    public var timestamp: String?

    public init(
        id: String? = nil,
        role: String,
        content: String?,
        name: String? = nil,
        toolCalls: [AIToolCall]? = nil,
        toolCallId: String? = nil,
        timestamp: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.name = name
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case name
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
        case timestamp
    }
}

public struct AIToolCall: Content, Sendable {
    public var id: String
    public var type: String
    public var function: AIFunctionCall

    public init(id: String, type: String = "function", function: AIFunctionCall) {
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct AIFunctionCall: Content, Sendable {
    public var name: String
    public var arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}

public struct AIFileMatchDTO: Content, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var mimeType: String
    public var size: String
    public var score: Int
    public var reason: String
    public var updatedAt: String
    public var isFavorite: Bool?
    public var isShared: Bool?
    public var hasThumbnail: Bool?
    public var owner: OwnerInfo?
    public var permissions: FilePermissionsDTO?

    public struct OwnerInfo: Content, Sendable {
        public var id: UUID
        public var username: String?
        public var displayName: String?
        public var email: String?

        public init(id: UUID, username: String? = nil, displayName: String? = nil, email: String? = nil) {
            self.id = id
            self.username = username
            self.displayName = displayName
            self.email = email
        }
    }

    public init(
        id: UUID,
        name: String,
        path: String,
        mimeType: String,
        size: String,
        score: Int,
        reason: String,
        updatedAt: String,
        isFavorite: Bool? = nil,
        isShared: Bool? = nil,
        hasThumbnail: Bool? = nil,
        owner: OwnerInfo? = nil,
        permissions: FilePermissionsDTO? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.mimeType = mimeType
        self.size = size
        self.score = score
        self.reason = reason
        self.updatedAt = updatedAt
        self.isFavorite = isFavorite
        self.isShared = isShared
        self.hasThumbnail = hasThumbnail
        self.owner = owner
        self.permissions = permissions
    }
}

public struct AIUIActionDTO: Content, Sendable {
    public var type: String
    public var fileID: UUID
    public var fileName: String?

    public init(type: String, fileID: UUID, fileName: String? = nil) {
        self.type = type
        self.fileID = fileID
        self.fileName = fileName
    }
}

public struct AIChatResponse: Content, Sendable {
    public var message: AIChatMessage
    public var fileMatches: [AIFileMatchDTO]
    public var toolsUsed: [String]
    public var action: AIUIActionDTO?
    public var followUpQuestions: [String]?

    public init(
        message: AIChatMessage,
        fileMatches: [AIFileMatchDTO],
        toolsUsed: [String],
        action: AIUIActionDTO? = nil,
        followUpQuestions: [String]? = nil
    ) {
        self.message = message
        self.fileMatches = fileMatches
        self.toolsUsed = toolsUsed
        self.action = action
        self.followUpQuestions = followUpQuestions
    }
}

public struct AIStatusResponse: Content, Sendable {
    public var enabled: Bool
    public var model: String
    public var configured: Bool

    public init(enabled: Bool, model: String, configured: Bool) {
        self.enabled = enabled
        self.model = model
        self.configured = configured
    }
}

// MARK: - OpenAI Compatible API Models

public struct OpenAIChatRequest: Content, Sendable {
    public var model: String
    public var messages: [OpenAIChatMessage]
    public var tools: [OpenAITool]?
    public var toolChoice: AnyCodableValue?
    public var temperature: Double?
    public var maxTokens: Int?

    public init(
        model: String,
        messages: [OpenAIChatMessage],
        tools: [OpenAITool]? = nil,
        toolChoice: AnyCodableValue? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case tools
        case toolChoice = "tool_choice"
        case temperature
        case maxTokens = "max_tokens"
    }
}

public enum AnyCodableValue: Codable, Sendable, Equatable, ExpressibleByStringLiteral {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: AnyCodableValue])
    case array([AnyCodableValue])
    case null

    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let o = try? container.decode([String: AnyCodableValue].self) {
            self = .object(o)
        } else if let a = try? container.decode([AnyCodableValue].self) {
            self = .array(a)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported AnyCodableValue")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }
}

public struct OpenAIChatMessage: Content, Sendable {
    public var role: String
    public var content: String?
    public var name: String?
    public var toolCalls: [OpenAIToolCall]?
    public var toolCallId: String?
    public var extraContent: [String: AnyCodableValue]?

    public init(
        role: String,
        content: String?,
        name: String? = nil,
        toolCalls: [OpenAIToolCall]? = nil,
        toolCallId: String? = nil,
        extraContent: [String: AnyCodableValue]? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.extraContent = extraContent
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case name
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
        case extraContent = "extra_content"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallId, forKey: .toolCallId)
        try container.encodeIfPresent(extraContent, forKey: .extraContent)
    }
}

public struct OpenAITool: Content, Sendable {
    public var type: String
    public var function: OpenAIFunctionDefinition

    public init(type: String = "function", function: OpenAIFunctionDefinition) {
        self.type = type
        self.function = function
    }
}

public struct OpenAIFunctionDefinition: Content, Sendable {
    public var name: String
    public var description: String
    public var parameters: OpenAIFunctionParameters

    public init(name: String, description: String, parameters: OpenAIFunctionParameters) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct OpenAIFunctionParameters: Content, Sendable {
    public var type: String
    public var properties: [String: OpenAIFunctionProperty]
    public var required: [String]?

    public init(type: String = "object", properties: [String: OpenAIFunctionProperty], required: [String]? = nil) {
        self.type = type
        self.properties = properties
        self.required = required
    }
}

public struct OpenAIFunctionProperty: Content, Sendable {
    public var type: String
    public var description: String
    public var `enum`: [String]?
    /// JSON Schema `items` for `type: "array"` properties (only supports a plain scalar item type).
    public var items: OpenAIFunctionItemsSchema?

    public init(type: String, description: String, enumValues: [String]? = nil, items: OpenAIFunctionItemsSchema? = nil) {
        self.type = type
        self.description = description
        self.enum = enumValues
        self.items = items
    }

    enum CodingKeys: String, CodingKey {
        case type
        case description
        case `enum`
        case items
    }
}

public struct OpenAIFunctionItemsSchema: Content, Sendable {
    public var type: String

    public init(type: String) {
        self.type = type
    }
}

public struct OpenAIToolCall: Content, Sendable {
    public var id: String
    public var type: String
    public var function: OpenAIFunctionCall
    public var extraContent: [String: AnyCodableValue]?

    public init(
        id: String,
        type: String = "function",
        function: OpenAIFunctionCall,
        extraContent: [String: AnyCodableValue]? = nil
    ) {
        self.id = id
        self.type = type
        self.function = function
        self.extraContent = extraContent
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case function
        case extraContent = "extra_content"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(function, forKey: .function)
        try container.encodeIfPresent(extraContent, forKey: .extraContent)
    }
}

public struct OpenAIFunctionCall: Content, Sendable {
    public var name: String
    public var arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}

public struct OpenAIChatResponse: Content, Sendable {
    public var id: String?
    public var choices: [OpenAIChoice]
    public var usage: OpenAIUsage?

    public init(id: String? = nil, choices: [OpenAIChoice], usage: OpenAIUsage? = nil) {
        self.id = id
        self.choices = choices
        self.usage = usage
    }
}

public struct OpenAIChoice: Content, Sendable {
    public var index: Int
    public var message: OpenAIChatMessage
    public var finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index
        case message
        case finishReason = "finish_reason"
    }
}

public struct OpenAIUsage: Content, Sendable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}
