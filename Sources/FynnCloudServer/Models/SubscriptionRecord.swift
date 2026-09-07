import Fluent
import Vapor

/// Persisted server subscription token record.
///
/// Deliberately not `Content`: a subscription key is a credential and must never be
/// serialized into an API response. It lives in its own table (single row)
/// rather than the generic `AppSetting` key/value store.
final class SubscriptionRecord: Model, @unchecked Sendable {
    static let schema = "subscriptions"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "token")
    var token: String

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, token: String) {
        self.id = id
        self.token = token
    }
}
