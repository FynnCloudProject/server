import Fluent
import Vapor

final class User: Model, Content, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "username")
    var username: String

    @Field(key: "email")
    var email: String

    @OptionalField(key: "display_name")
    var displayName: String?

    @OptionalField(key: "avatar_updated_at")
    var avatarUpdatedAt: Date?

    @Field(key: "password_hash")
    var passwordHash: String

    @Field(key: "current_storage_usage")
    var currentStorageUsage: Int64

    @Children(for: \.$owner)
    var files: [FileMetadata]

    @OptionalParent(key: "tier_id")
    var tier: StorageTier?

    @Siblings(through: UserGroup.self, from: \.$user, to: \.$group)
    var groups: [Group]

    init() {}

    init(
        id: UUID? = nil, username: String, email: String, passwordHash: String,
        displayName: String? = nil,
        tierID: StorageTier.IDValue? = nil
    ) {
        self.id = id
        self.username = username
        self.email = email
        self.passwordHash = passwordHash
        self.displayName = displayName
        self.currentStorageUsage = 0
        self.$tier.id = tierID
    }

    var isAdmin: Bool {
        self.$groups.value?.contains(where: { $0.isAdmin }) ?? false
    }

    struct Public: Content {
        var id: UUID
        var username: String
        var email: String
        var displayName: String?
        var avatarUpdatedAt: Date?
        var currentStorageUsage: Int64
        var groups: [Group]
        var tierID: Int?
        var tierName: String?
        var isAdmin: Bool
        /// Whether the account has TOTP two-factor enabled. Populated by `/me` (defaults false elsewhere).
        var twoFactorEnabled: Bool = false
        /// For SSO-granted memberships: group id (as string) -> provider source (e.g. "oidc:keycloak").
        /// Absent for memberships assigned manually. Only populated by admin listings.
        var ssoGroupSources: [String: String]? = nil
    }

    func toPublic() throws -> Public {
        let effectiveDisplayName = (self.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? self.username
        return try Public(
            id: self.requireID(),
            username: self.username,
            email: self.email,
            displayName: effectiveDisplayName,
            avatarUpdatedAt: self.avatarUpdatedAt,
            currentStorageUsage: self.currentStorageUsage,
            groups: self.$groups.value ?? [],
            tierID: self.$tier.id,
            tierName: self.$tier.value??.name,
            isAdmin: self.isAdmin
        )
    }
}

extension User: ModelSessionAuthenticatable {
    static let usernameKey: KeyPath<User, FieldProperty<User, String>> = \User.$username
    static let passwordHashKey: KeyPath<User, FieldProperty<User, String>> = \User.$passwordHash

    func verify(password: String) throws -> Bool {
        // An empty hash marks an SSO-only account, which must never authenticate via a local password.
        guard !self.passwordHash.isEmpty else { return false }
        return try Bcrypt.verify(password, created: self.passwordHash)
    }
}
