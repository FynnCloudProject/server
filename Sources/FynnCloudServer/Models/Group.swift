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

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: Int? = nil, name: String, tierID: StorageTier.IDValue? = nil, isAdmin: Bool = false) {
        self.id = id
        self.name = name
        self.isAdmin = isAdmin
        self.$tier.id = tierID
    }

    struct Public: Content {
        var id: Int
        var name: String
        var tierID: Int?
        var tierName: String?
        var isAdmin: Bool
    }

    func toPublic() throws -> Public {
        try Public(
            id: self.requireID(),
            name: self.name,
            tierID: self.$tier.id,
            tierName: self.$tier.value??.name,
            isAdmin: self.isAdmin
        )
    }
}
