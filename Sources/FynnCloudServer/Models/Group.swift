import Fluent
import Vapor

final class Group: Model, Content, @unchecked Sendable {
    static let schema = "groups"

    @ID(custom: "id")
    var id: Int?

    @Field(key: "name")
    var name: String

    @Field(key: "is_admin")
    var isAdmin: Bool

    @OptionalParent(key: "tier_id")
    var tier: StorageTier?

    @Siblings(through: UserGroup.self, from: \.$group, to: \.$user)
    var users: [User]

    @OptionalField(key: "system_key")
    var systemKey: String?

    /// Origin of the group: `"manual"`, `"ldap"`, or `"oidc:<key>"`.
    /// Managed groups are reconciled from that provider on each login/sync and
    /// are never granted admin/tier implicitly (elevation stays admin-controlled).
    @Field(key: "source")
    var source: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: Int? = nil, name: String, systemKey: String? = nil, tierID: StorageTier.IDValue? = nil, isAdmin: Bool = false, source: String = "manual") {
        self.id = id
        self.name = name
        self.systemKey = systemKey
        self.isAdmin = isAdmin
        self.source = source
        self.$tier.id = tierID
    }

    struct Public: Content {
        var id: Int
        var name: String
        var systemKey: String?
        var tierID: Int?
        var tierName: String?
        var isAdmin: Bool
        var source: String
    }

    func toPublic() throws -> Public {
        try Public(
            id: self.requireID(),
            name: self.name,
            systemKey: self.systemKey,
            tierID: self.$tier.id,
            tierName: self.$tier.value??.name,
            isAdmin: self.isAdmin,
            source: self.source
        )
    }
}
