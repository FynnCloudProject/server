import Fluent
import Vapor

final class StorageTier: Model, Content, @unchecked Sendable {
    static let schema = "storage_tiers"

    @ID(custom: "id")
    var id: Int?

    @Field(key: "name")
    var name: String  // e.g., "Free", "Pro", "Business"

    @Field(key: "limit_bytes")
    var limitBytes: Int64

    @Children(for: \.$tier)
    var users: [User]

    init() {}

    init(id: Int? = nil, name: String, limitBytes: Int64) {
        self.id = id
        self.name = name
        self.limitBytes = limitBytes
    }
}
