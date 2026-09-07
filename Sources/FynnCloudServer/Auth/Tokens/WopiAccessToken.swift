import JWT
import Vapor

// MARK: - WOPI Access Token

/// Short-lived, per-file token echoed back by the WOPI client (EuroOffice) on every WOPI call.
/// Binds the session to a single file so the host can enforce scope and permissions.
///
/// Identity is deliberately split:
/// - `ownerID` is the file's owner, authoritative for storage/quota reads and writes.
/// - `userID` is the acting editor's identity (equals `ownerID` for owner sessions; a random
///   per-session UUID for anonymous share guests) used only for WOPI presence/attribution.
/// - `shareLinkID`, when set, scopes the session to a share link and forces per-call re-validation.
struct WopiAccessToken: JWTPayload, Authenticatable {
    var exp: ExpirationClaim
    var iat: IssuedAtClaim

    var fileID: UUID
    var userID: UUID
    var canWrite: Bool
    /// File owner used for storage/quota. Optional for backward compatibility with owner-only tokens
    /// issued before the split (falls back to `userID`).
    var ownerID: UUID?
    /// Set when the session originates from a share link; triggers per-call share re-validation.
    var shareLinkID: UUID?
    /// Display name shown in the editor (e.g. "Guest" for anonymous share sessions).
    var userFriendlyName: String?

    /// Owner to use for storage/quota operations.
    var effectiveOwnerID: UUID { ownerID ?? userID }

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try self.exp.verifyNotExpired()
    }
}
