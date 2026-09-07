import Fluent
import Vapor

enum ShareLinkType: String, Codable {
    case viewOnly = "view_only"
    case fileDrop = "file_drop"
    case collaborative = "collaborative"

    var allowsUpload: Bool {
        switch self {
        case .fileDrop, .collaborative:
            return true
        case .viewOnly:
            return false
        }
    }

    var allowsView: Bool {
        switch self {
        case .viewOnly, .collaborative:
            return true
        case .fileDrop:
            return false
        }
    }
}

final class ShareLink: Model, Content, @unchecked Sendable {
    static let schema = "share_links"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "token")
    var token: String

    @Parent(key: "file_id")
    var file: FileMetadata

    @Parent(key: "created_by")
    var creator: User

    @OptionalField(key: "expires_at")
    var expiresAt: Date?

    @OptionalField(key: "password_hash")
    var passwordHash: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Field(key: "link_type")
    var linkType: ShareLinkType

    @Field(key: "requires_auth")
    var requiresAuth: Bool

    init() {}

    init(
        id: UUID? = nil,
        token: String,
        fileID: FileMetadata.IDValue,
        createdBy: User.IDValue,
        expiresAt: Date? = nil,
        passwordHash: String? = nil,
        linkType: ShareLinkType = .viewOnly,
        requiresAuth: Bool = false
    ) {
        self.id = id
        self.token = token
        self.$file.id = fileID
        self.$creator.id = createdBy
        self.expiresAt = expiresAt
        self.passwordHash = passwordHash
        self.linkType = linkType
        self.requiresAuth = requiresAuth
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date()
    }
}
