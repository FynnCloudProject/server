import Fluent
import Vapor

final class AppSetting: Model, Content, @unchecked Sendable {
    static let schema = "app_settings"

    @ID(custom: "key", generatedBy: .user)
    var id: String?

    @Field(key: "value")
    var value: String

    init() {}

    init(key: String, value: String) {
        self.id = key
        self.value = value
    }
}
