import Fluent
import Vapor

/// Links a local `User` to an external SSO identity (an LDAP entry or an OIDC subject).
/// Uniqueness on `(provider, subject)` guarantees one external identity maps to exactly one user.
final class UserIdentity: Model, @unchecked Sendable {
    static let schema = "user_identities"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    /// Provider key, e.g. `"ldap"` or `"oidc:main"`.
    @Field(key: "provider")
    var provider: String

    /// Stable external subject id (LDAP `entryUUID`, OIDC `sub`).
    @Field(key: "subject")
    var subject: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, userID: User.IDValue, provider: String, subject: String) {
        self.id = id
        self.$user.id = userID
        self.provider = provider
        self.subject = subject
    }
}
