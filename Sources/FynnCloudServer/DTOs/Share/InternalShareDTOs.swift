import Vapor

public struct CreateInternalShareInput: Content, Sendable {
    public var granteeType: ShareGranteeType
    public var granteeUserID: UUID?
    public var granteeGroupID: Int?
    public var role: InternalShareRole?

    public init(
        granteeType: ShareGranteeType,
        granteeUserID: UUID? = nil,
        granteeGroupID: Int? = nil,
        role: InternalShareRole? = .viewer
    ) {
        self.granteeType = granteeType
        self.granteeUserID = granteeUserID
        self.granteeGroupID = granteeGroupID
        self.role = role ?? .viewer
    }
}

public struct UpdateInternalShareInput: Content, Sendable {
    public var role: InternalShareRole

    public init(role: InternalShareRole) {
        self.role = role
    }
}

public struct InternalShareDTO: Content, Sendable {
    public var id: UUID
    public var fileID: UUID
    public var granteeType: ShareGranteeType
    public var granteeID: String
    public var granteeName: String
    public var granteeDisplayName: String?
    public var role: InternalShareRole
    public var createdAt: Date?
    public var createdBy: UUID
    public var systemKey: String?

    public init(
        id: UUID,
        fileID: UUID,
        granteeType: ShareGranteeType,
        granteeID: String,
        granteeName: String,
        granteeDisplayName: String? = nil,
        role: InternalShareRole,
        createdAt: Date?,
        createdBy: UUID,
        systemKey: String? = nil
    ) {
        self.id = id
        self.fileID = fileID
        self.granteeType = granteeType
        self.granteeID = granteeID
        self.granteeName = granteeName
        self.granteeDisplayName = granteeDisplayName
        self.role = role
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.systemKey = systemKey
    }
}

public struct ShareRecipientDTO: Content, Sendable {
    public var id: String
    public var name: String
    public var displayName: String?
    public var type: ShareGranteeType
    public var avatarUpdatedAt: Date?
    public var systemKey: String?

    public init(
        id: String,
        name: String,
        displayName: String? = nil,
        type: ShareGranteeType,
        avatarUpdatedAt: Date? = nil,
        systemKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.type = type
        self.avatarUpdatedAt = avatarUpdatedAt
        self.systemKey = systemKey
    }
}

extension InternalShareDTO {
    init(from share: InternalShare) {
        let granteeID: String
        let granteeName: String
        let granteeDisplayName: String?
        let systemKey: String?

        switch share.granteeType {
        case .user:
            granteeID = share.$granteeUser.id?.uuidString ?? ""
            granteeName = share.granteeUser?.username ?? "User"
            granteeDisplayName = share.granteeUser?.displayName
            systemKey = nil
        case .group:
            granteeID = share.$granteeGroup.id.map(String.init) ?? ""
            granteeName = share.granteeGroup?.name ?? "Group"
            granteeDisplayName = nil
            systemKey = share.granteeGroup?.systemKey
        }

        self.init(
            id: share.id ?? UUID(),
            fileID: share.$file.id,
            granteeType: share.granteeType,
            granteeID: granteeID,
            granteeName: granteeName,
            granteeDisplayName: granteeDisplayName,
            role: share.role,
            createdAt: share.createdAt,
            createdBy: share.$creator.id,
            systemKey: systemKey
        )
    }
}
