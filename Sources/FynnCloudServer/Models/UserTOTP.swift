import Fluent
import Vapor

final class UserTOTP: Model, @unchecked Sendable {
    static let schema = "user_totp"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    /// Encrypted base32-encoded shared secret (see `SecretBox`).
    @Field(key: "secret")
    var secret: String

    @Field(key: "is_enabled")
    var isEnabled: Bool

    @Children(for: \.$totp)
    var recoveryCodes: [UserTOTPRecoveryCode]

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @OptionalField(key: "confirmed_at")
    var confirmedAt: Date?

    init() {}

    init(userID: User.IDValue, secret: String, isEnabled: Bool = false) {
        self.$user.id = userID
        self.secret = secret
        self.isEnabled = isEnabled
    }
}

extension UserTOTP {
    /// Count of recovery codes that are still valid (not yet redeemed).
    func remainingRecoveryCodeCount(on db: any Database) async throws -> Int {
        try await $recoveryCodes.query(on: db)
            .filter(\.$usedAt == nil)
            .count()
    }

    /// Replaces every recovery code with a freshly bcrypt-hashed set, invalidating the old ones.
    func resetRecoveryCodes(_ plaintext: [String], on db: any Database) async throws {
        let totpID = try requireID()
        try await $recoveryCodes.query(on: db).delete()
        for code in plaintext {
            let hash = try Bcrypt.hash(TOTP.normalizeRecoveryCode(code))
            try await UserTOTPRecoveryCode(totpID: totpID, codeHash: hash).save(on: db)
        }
    }

    /// Redeems a submitted recovery code if it matches an unused one, stamping `usedAt`.
    func consumeRecoveryCode(_ submitted: String, on db: any Database) async throws -> Bool {
        let normalized = TOTP.normalizeRecoveryCode(submitted)
        let codes = try await $recoveryCodes.query(on: db)
            .filter(\.$usedAt == nil)
            .all()
        for code in codes where (try? Bcrypt.verify(normalized, created: code.codeHash)) == true {
            code.usedAt = Date()
            try await code.save(on: db)
            return true
        }
        return false
    }
}
