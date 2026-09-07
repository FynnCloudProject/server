import Fluent
import Vapor

final class OAuthGrant: Model, Content, @unchecked Sendable {
    static let schema = "oauth_grants"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "client_id")
    var clientID: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Field(key: "user_agent")
    var userAgent: String?

    @Field(key: "current_refresh_token_id")
    var currentRefreshTokenID: UUID?

    @Field(key: "previous_refresh_token_id")
    var previousRefreshTokenID: UUID?

    @Field(key: "last_rotated_at")
    var lastRotatedAt: Date?

    @Field(key: "last_used_at")
    var lastUsedAt: Date?

    @Field(key: "ip_address")
    var ipAddress: String?

    init() {}

    init(
        id: UUID? = nil, userID: UUID, clientID: String, userAgent: String, ipAddress: String? = nil,
    ) {
        self.id = id
        self.$user.id = userID
        self.clientID = clientID
        self.userAgent = userAgent
        self.ipAddress = ipAddress
        self.currentRefreshTokenID = nil
        self.previousRefreshTokenID = nil
        self.lastRotatedAt = nil
    }
}
