import Vapor

// MARK: - WOPI DTOs

/// Response for `GET /api/wopi/files/{id}` (CheckFileInfo). Keys use WOPI's PascalCase convention.
struct WopiCheckFileInfo: Content {
    let baseFileName: String
    let size: Int64
    let version: String
    let lastModifiedTime: String
    let ownerId: String
    let userId: String
    let userFriendlyName: String
    let userCanWrite: Bool
    let readOnly: Bool
    let userCanNotWriteRelative: Bool
    let supportsLocks: Bool
    let supportsGetLock: Bool
    let supportsUpdate: Bool
    /// Makes EuroOffice render its built-in close button and emit a `UI_Close` postMessage to the host frame on click.
    let closePostMessage: Bool
    /// Target origin EuroOffice uses for postMessages back to the host (the FynnCloud UI).
    let postMessageOrigin: String

    enum CodingKeys: String, CodingKey {
        case baseFileName = "BaseFileName"
        case size = "Size"
        case version = "Version"
        case lastModifiedTime = "LastModifiedTime"
        case ownerId = "OwnerId"
        case userId = "UserId"
        case userFriendlyName = "UserFriendlyName"
        case userCanWrite = "UserCanWrite"
        case readOnly = "ReadOnly"
        case userCanNotWriteRelative = "UserCanNotWriteRelative"
        case supportsLocks = "SupportsLocks"
        case supportsGetLock = "SupportsGetLock"
        case supportsUpdate = "SupportsUpdate"
        case closePostMessage = "ClosePostMessage"
        case postMessageOrigin = "PostMessageOrigin"
    }
}
