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
        tierID: StorageTier.IDValue? = nil
    ) {
        self.id = id
        self.username = username
        self.email = email
        self.passwordHash = passwordHash
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
        var currentStorageUsage: Int64
        var groups: [Group]
        var tierID: Int?
        var tierName: String?
        var isAdmin: Bool
    }

    func toPublic() throws -> Public {
        try Public(
            id: self.requireID(),
            username: self.username,
            email: self.email,
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
        try Bcrypt.verify(password, created: self.passwordHash)
    }
}
