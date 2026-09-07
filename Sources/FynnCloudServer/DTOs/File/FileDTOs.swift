import Fluent
import Vapor

struct CreateDirData: Content {
    var name: String
    var parentID: UUID?
}

enum NewFileType: String, Content {
    case document
    case spreadsheet
    case presentation
    case text

    var fileExtension: String {
        switch self {
        case .document: return "docx"
        case .spreadsheet: return "xlsx"
        case .presentation: return "pptx"
        case .text: return "txt"
        }
    }

    var contentType: String {
        switch self {
        case .document:
            return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case .spreadsheet:
            return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case .presentation:
            return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case .text:
            return "text/plain"
        }
    }

    /// Returns the initial template ByteBuffer for this file type.
    func initialBuffer() throws -> ByteBuffer {
        try FileTemplates.templateBuffer(for: self)
    }

    /// Returns the initial template Data for this file type.
    func initialData() throws -> Data {
        try FileTemplates.loadTemplateData(for: self)
    }
}

struct CreateFileData: Content {
    var name: String
    var type: NewFileType
    var parentID: UUID?
}

struct FileIndexItemDTO: Content {
    var id: UUID?
    var filename: String
    var contentType: String
    var size: Int64
    var isDirectory: Bool
    var lastModified: Date?
    var createdAt: Date?
    var uploadedAt: Date?
    var updatedAt: Date?
    var deletedAt: Date?
    var isFavorite: Bool
    var isShared: Bool
    var hasThumbnail: Bool
    var owner: OwnerInfo
    var parent: ParentID?
    var path: String?
    var permissions: FilePermissionsDTO?

    struct OwnerInfo: Content {
        var id: UUID
        var username: String?
        var displayName: String?
        var email: String?
    }

    struct ParentID: Content {
        var id: UUID
    }

    /// `hidesParent` omits the parent link for viewers who cannot see the containing folder, so the
    /// client never renders a breadcrumb it would get a 404 for.
    init(
        from model: FileMetadata,
        isFavorite: Bool? = nil,
        path: String? = nil,
        permissions: FilePermissionsDTO? = nil,
        hidesParent: Bool = false
    ) {
        self.id = model.id
        self.filename = model.filename
        self.contentType = model.contentType
        self.size = model.size
        self.isDirectory = model.isDirectory
        self.lastModified = model.lastModified
        self.createdAt = model.createdAt
        self.uploadedAt = model.uploadedAt ?? model.createdAt
        self.updatedAt = model.updatedAt
        self.deletedAt = model.deletedAt
        self.isFavorite = isFavorite ?? model.isFavorite
        self.isShared = model.isShared
        self.hasThumbnail = model.hasThumbnail
        if let ownerUser = model.$owner.value {
            self.owner = OwnerInfo(
                id: model.$owner.id,
                username: ownerUser.username,
                displayName: ownerUser.displayName,
                email: ownerUser.email
            )
        } else {
            self.owner = OwnerInfo(id: model.$owner.id)
        }
        if let parentID = model.$parent.id, !hidesParent {
            self.parent = ParentID(id: parentID)
        } else {
            self.parent = nil
        }
        self.path = path
        self.permissions = permissions
    }
}

struct FileIndexDTO: Content {
    var files: [FileIndexItemDTO]
    var parentID: UUID?
    var breadcrumbs: [Breadcrumb]
    var totalCount: Int
    var hasMore: Bool
}

struct Breadcrumb: Content {
    var name: String
    var id: UUID?
    var labelKey: String?
    var icon: String?
    var path: String?
}

/// Breadcrumb roots for the virtual (non-folder) views.
extension Breadcrumb {
    static let allFiles = Breadcrumb(
        name: "All Files", id: nil, labelKey: LocalizationKeys.Navigation.AllFiles,
        icon: "home", path: "/")
    static let favorites = Breadcrumb(
        name: "Favorites", id: nil, labelKey: "navigation.favorites", icon: "star",
        path: "/favorites")
    static let recent = Breadcrumb(
        name: "Recent", id: nil, labelKey: "navigation.recent", icon: "clock", path: "/recent")
    static let sharedWithMe = Breadcrumb(
        name: "Shared with me", id: nil, labelKey: "navigation.sharedWithMe", icon: "share",
        path: "/shared")
    static let sharedWithOthers = Breadcrumb(
        name: "Shared with others", id: nil, labelKey: "navigation.sharedWithOthers",
        icon: "share", path: "/shared/with-others")
    static let trash = Breadcrumb(
        name: "Trash", id: nil, labelKey: "navigation.trash", icon: "trash", path: "/trash")
    static let search = Breadcrumb(
        name: "Search", id: nil, labelKey: "navigation.search", icon: "search", path: "/search")
}

struct MoveFilesInput: Content {
    var ids: [UUID]
    var parentID: UUID?
}

struct FileIDsInput: Content {
    var ids: [UUID]
}

/// Result of an operation on a set of files. Callers read the arrays instead of a status code,
/// since a batch has one outcome per id.
struct BulkFileResultDTO: Content {
    var succeeded: [UUID]
    var failed: [UUID]
}

/// Same, for operations that hand the updated files back.
struct BulkFileItemsResultDTO: Content {
    var succeeded: [FileIndexItemDTO]
    var failed: [UUID]
}

struct RenameInput: Content {
    var name: String
}

struct ToggleFavoriteInput: Content {
    var isFavorite: Bool?
}
