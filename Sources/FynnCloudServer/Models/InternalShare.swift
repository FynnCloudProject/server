import Fluent
import Vapor

public enum ShareGranteeType: String, Codable, Sendable {
    case user = "user"
    case group = "group"
}

public enum InternalShareRole: String, Codable, Sendable, Comparable {
    case viewer = "viewer"
    case editor = "editor"
    case manager = "manager"

    public var permissions: FilePermissions {
        switch self {
        case .viewer:
            return .viewer
        case .editor:
            return .editor
        case .manager:
            return .manager
        }
    }

    private var rank: Int {
        switch self {
        case .viewer: return 1
        case .editor: return 2
        case .manager: return 3
        }
    }

    public static func < (lhs: InternalShareRole, rhs: InternalShareRole) -> Bool {
        lhs.rank < rhs.rank
    }
}

final class InternalShare: Model, Content, @unchecked Sendable {
    static let schema = "internal_shares"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "file_id")
    var file: FileMetadata

    @Field(key: "grantee_type")
    var granteeType: ShareGranteeType

    @OptionalParent(key: "grantee_user_id")
    var granteeUser: User?

    @OptionalParent(key: "grantee_group_id")
    var granteeGroup: Group?

    @Field(key: "role")
    var role: InternalShareRole

    @Parent(key: "created_by")
    var creator: User

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        fileID: FileMetadata.IDValue,
        granteeType: ShareGranteeType,
        granteeUserID: User.IDValue? = nil,
        granteeGroupID: Group.IDValue? = nil,
        role: InternalShareRole = .viewer,
        createdBy: User.IDValue
    ) {
        self.id = id
        self.$file.id = fileID
        self.granteeType = granteeType
        self.$granteeUser.id = granteeUserID
        self.$granteeGroup.id = granteeGroupID
        self.role = role
        self.$creator.id = createdBy
    }
}
