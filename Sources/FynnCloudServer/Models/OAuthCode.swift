import Fluent
import Vapor

final class OAuthCode: Model, Content, @unchecked Sendable {
    static let schema = "oauth_codes"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Field(key: "code_challenge") var codeChallenge: String
    @Field(key: "expires_at") var expiresAt: Date
    @Field(key: "client_id") var clientID: String
    @OptionalField(key: "state") var state: String?

    init() {}

    init(
        id: UUID? = nil, userID: UUID, codeChallenge: String, expiresAt: Date, clientID: String,
        state: String?
    ) {
        self.id = id
        self.$user.id = userID
        self.codeChallenge = codeChallenge
        self.expiresAt = expiresAt
        self.clientID = clientID
        self.state = state
    }
}
