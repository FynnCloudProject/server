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
}

struct LoginWithOAuthDTO: Content {
    let username: String
    let password: String
    let codeChallenge: String
    let clientId: String
    let state: String?
    let redirectURI: String?
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
    let code: UUID
    let code_verifier: String
    let clientId: String
}
