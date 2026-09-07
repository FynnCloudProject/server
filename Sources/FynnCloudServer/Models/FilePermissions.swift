import Vapor

public struct FilePermissions: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let read    = FilePermissions(rawValue: 1 << 0)
    public static let write   = FilePermissions(rawValue: 1 << 1)
    public static let delete  = FilePermissions(rawValue: 1 << 2)
    public static let share   = FilePermissions(rawValue: 1 << 3)
    public static let manage  = FilePermissions(rawValue: 1 << 4)

    public static let none: FilePermissions = []
    public static let viewer: FilePermissions = [.read]
    public static let editor: FilePermissions = [.read, .write, .delete]
    public static let manager: FilePermissions = [.read, .write, .delete, .share, .manage]
    public static let all: FilePermissions = [.read, .write, .delete, .share, .manage]

    public var canRead: Bool { contains(.read) }
    public var canWrite: Bool { contains(.write) }
    public var canDelete: Bool { contains(.delete) }
    public var canShare: Bool { contains(.share) }
    public var canManage: Bool { contains(.manage) }
}

public struct FilePermissionsDTO: Content, Sendable, Equatable {
    public var canRead: Bool
    public var canWrite: Bool
    public var canDelete: Bool
    public var canShare: Bool
    public var canManage: Bool
    public var isOwner: Bool

    public init(permissions: FilePermissions, isOwner: Bool) {
        self.canRead = permissions.canRead
        self.canWrite = permissions.canWrite
        self.canDelete = permissions.canDelete
        self.canShare = permissions.canShare
        self.canManage = permissions.canManage
        self.isOwner = isOwner
    }

    public static func owner() -> FilePermissionsDTO {
        FilePermissionsDTO(permissions: .all, isOwner: true)
    }
}

extension ShareLinkType {
    public var permissions: FilePermissions {
        switch self {
        case .viewOnly:
            return .viewer
        case .collaborative:
            return .editor
        case .fileDrop:
            return [.write]
        }
    }
}
