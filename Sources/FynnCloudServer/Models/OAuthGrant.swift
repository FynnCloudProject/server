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

    init() {}

    init(
        id: UUID? = nil, userID: UUID, clientID: String, userAgent: String,
    ) {
        self.id = id
        self.$user.id = userID
        self.clientID = clientID
        self.userAgent = userAgent
        self.currentRefreshTokenID = nil
    }
}
