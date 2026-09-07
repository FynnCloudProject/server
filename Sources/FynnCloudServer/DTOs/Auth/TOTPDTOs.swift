import Vapor

/// Returned by `POST /api/auth/totp/setup`: the secret to store in the authenticator plus
/// the provisioning URI for the QR code. The row is created disabled until confirmed.
struct TOTPSetupResponse: Content {
    let secret: String
    let otpauthURL: String
}

struct TOTPCodeDTO: Content {
    let code: String
}

/// Confirms setup: the client echoes back the secret it just scanned along with a live code.
/// No DB row exists until this succeeds, so setup never leaves an unconfirmed record behind.
struct TOTPEnableDTO: Content {
    let secret: String
    let code: String
}

/// Disabling requires re-confirming identity with either a current TOTP code or the password.
struct TOTPDisableDTO: Content {
    let code: String?
    let password: String?
}

struct TOTPStatusResponse: Content {
    let enabled: Bool
    let remainingRecoveryCodes: Int
}

/// Returned when TOTP is confirmed (enable) or codes are regenerated.
struct TOTPRecoveryCodesResponse: Content {
    let recoveryCodes: [String]
}
