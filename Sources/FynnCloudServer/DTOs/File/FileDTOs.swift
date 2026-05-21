import Fluent
import Vapor

struct CreateDirData: Content {
    var name: String
    var parentID: UUID?
}

struct FileIndexDTO: Content {
    var files: [FileMetadata]
    var parentID: UUID?
    var breadcrumbs: [Breadcrumb]
}

struct Breadcrumb: Content {
    var name: String
    var id: UUID?
    var labelKey: String?
    var icon: String?
    var path: String?
}

struct MoveFileInput: Content {
    var fileID: UUID
    var parentID: UUID?
}

struct RenameInput: Content {
    var name: String
}

struct ToggleFavoriteInput: Content {
    var isFavorite: Bool?
}
