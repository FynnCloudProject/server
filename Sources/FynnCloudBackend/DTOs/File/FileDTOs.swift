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
