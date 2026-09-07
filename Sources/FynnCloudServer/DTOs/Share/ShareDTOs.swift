import Vapor

// MARK: - Share DTOs

struct CreateShareLinkInput: Content {
    var expiresAt: Date?
    var password: String?
    var linkType: ShareLinkType?
}

struct ShareLinkDTO: Content {
    var id: UUID
    var token: String
    var fileID: UUID
    var expiresAt: Date?
    var hasPassword: Bool
    var createdAt: Date?
    var linkType: ShareLinkType

    init(from link: ShareLink) {
        self.id = link.id!
        self.token = link.token
        self.fileID = link.$file.id
        self.expiresAt = link.expiresAt
        self.hasPassword = link.passwordHash != nil
        self.createdAt = link.createdAt
        self.linkType = link.linkType
    }
}

struct SharedFileDTO: Content {
    var id: UUID
    var filename: String
    var contentType: String
    var size: Int64
    var isDirectory: Bool
    var hasThumbnail: Bool
    var lastModified: Date?
    var createdAt: Date?

    init(from file: FileMetadata) {
        self.id = file.id!
        self.filename = file.filename
        self.contentType = file.contentType
        self.size = file.size
        self.isDirectory = file.isDirectory
        self.hasThumbnail = file.hasThumbnail
        self.lastModified = file.lastModified
        self.createdAt = file.createdAt
    }
}

struct ShareContentDTO: Content {
    var file: SharedFileDTO
    var children: [SharedFileDTO]?
    var linkType: ShareLinkType
    var expiresAt: Date?
}
