import Foundation

struct MultipartSessionPayload: Codable, Sendable {
    let sessionID: UUID
    let fileID: UUID
    let uploadID: String
    let userID: UUID
    let filename: String
    let totalSize: Int64
    let parentID: UUID?
    let expiresAt: Date
    let isUpdate: Bool?
    /// The quota reservation held for this session, so the expiry sweeper can release it without
    /// the client's token.
    let reservationID: String?

    init(
        sessionID: UUID,
        fileID: UUID,
        uploadID: String,
        userID: UUID,
        filename: String,
        totalSize: Int64,
        parentID: UUID? = nil,
        expiresAt: Date,
        isUpdate: Bool? = false,
        reservationID: String? = nil
    ) {
        self.sessionID = sessionID
        self.fileID = fileID
        self.uploadID = uploadID
        self.userID = userID
        self.filename = filename
        self.totalSize = totalSize
        self.parentID = parentID
        self.expiresAt = expiresAt
        self.isUpdate = isUpdate
        self.reservationID = reservationID
    }
}
