import Fluent
import Vapor

final class UserGroup: Model, Content, @unchecked Sendable {
    static let schema = "user_groups"

    @ID(custom: "id")
    var id: Int?

    @Parent(key: "user_id")
    var user: User

    @Parent(key: "group_id")
    var group: Group

    init() {}

    init(id: Int? = nil, userID: User.IDValue, groupID: Group.IDValue) {
        self.id = id
        self.$user.id = userID
        self.$group.id = groupID
    }
}
