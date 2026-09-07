import Fluent
import Vapor

struct LoginDTO: Content {
    var username: String
    var password: String
}

struct RegisterDTO: Content {
    var username: String
    var password: String
    var confirmPassword: String
    var email: String
    var displayName: String?
}

struct SetupDTO: Content {
    var username: String
    var password: String
    var confirmPassword: String
    var email: String
    var displayName: String?
    var appName: String?
    var primaryColor: String?
    var registrationEnabled: Bool?
}

struct LoginWithOAuthDTO: Content {
    var username: String
    var password: String
    var codeChallenge: String
    var clientId: String
    var state: String?
    var redirectURI: String?
    /// A TOTP code (or recovery code) supplied on the second login step when 2FA is enabled.
    var totpCode: String?
}

struct AuthorizeDTO: Content {
    let clientId: String
    let codeChallenge: String
    let redirectURI: String?
    let state: String?
}

struct AuthorizeResponse: Content {
    let callbackURL: String
    let code: String?
    /// When true, credentials were valid but a TOTP code is still required to finish login.
    var totpRequired: Bool = false
}

struct LoginResponse: Content {
    let accessToken: String
    let refreshToken: String
    let user: User.Public
}

struct RefreshDTO: Content {
    let refreshToken: String
}

struct ExchangeDTO: Content {
    let code: String
    let code_verifier: String
    let clientId: String
}

struct OAuthCodePayload: Codable, Sendable {
    let userID: UUID
    let codeChallenge: String
    let clientID: String
    let state: String?
}

struct SessionResponse: Content {
    let id: UUID
    let clientID: String
    let userAgent: String?
    let ipAddress: String?
    let createdAt: Date?
    let lastUsedAt: Date?
    let isCurrent: Bool
}

struct SessionActivityBuffer: Codable, Sendable {
    let grantID: UUID
    let timestamp: Int64
    let ipAddress: String?
}

