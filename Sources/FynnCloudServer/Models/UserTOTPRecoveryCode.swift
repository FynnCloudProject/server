import Fluent
import Vapor

/// A single TOTP recovery code, stored one row per code as a bcrypt hash. A code is consumed
/// by stamping `usedAt` rather than deleting, preserving an audit trail of when it was used.
final class UserTOTPRecoveryCode: Model, @unchecked Sendable {
    static let schema = "user_totp_recovery_code"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "totp_id")
    var totp: UserTOTP

    /// Bcrypt hash of the normalized recovery code.
    @Field(key: "code_hash")
    var codeHash: String

    /// Set when the code is redeemed; `nil` means still valid.
    @OptionalField(key: "used_at")
    var usedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(totpID: UserTOTP.IDValue, codeHash: String) {
        self.$totp.id = totpID
        self.codeHash = codeHash
    }
}
