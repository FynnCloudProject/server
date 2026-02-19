struct LocalizationKeys {
    struct Auth {
        struct Error {
            static let InvalidCredentials = "auth.error.credentials"
            static let UserExists = "auth.error.userExists"
            static let MissingCode = "auth.callback.error.missingCode"
            static let ExchangeFailed = "auth.callback.error.exchangeFailed"
            static let MissingParams = "auth.authorize.error.missingParams"
            static let InvalidClientId = "auth.authorize.error.invalidClientId"
            static let InvalidResponseType = "auth.authorize.error.invalidResponseType"
            static let InvalidCodeChallengeMethod =
                "auth.authorize.error.invalidCodeChallengeMethod"
            static let EmailExists = "auth.error.emailExists"
            static let PasswordMismatch = "auth.error.passwordMismatch"
            static let PasswordTooWeak = "auth.error.passwordTooWeak"
            static let PasswordTooShort = "auth.error.passwordTooShort"
            static let PasswordMissingSpecialCharacter =
                "auth.error.passwordMissingSpecialCharacter"
            static let PasswordMissingNumber = "auth.error.passwordMissingNumber"
            static let PasswordMissingUppercase = "auth.error.passwordMissingUppercase"
            static let PasswordMissingLowercase = "auth.error.passwordMissingLowercase"

        }
    }

    struct Files {
        struct Error {
            static let RestoreFailed = "files.error.restoreFailed"
            static let UploadFailed = "files.error.uploadFailed"
        }
    }

    struct Common {
        struct Error {
            static let NotFound = "error.notFound"
            static let Unauthorized = "error.unauthorized"
            static let Forbidden = "error.forbidden"
            static let Generic = "error.generic"
            static let InvalidRequest = "error.invalidRequest"
        }
    }

    struct Admin {
        struct Alerts {
            static let JwtSecretDefault = "jwtSecretDefault"
            static let LdapDefaultPassword = "ldapDefaultPassword"
            static let SqliteInProduction = "sqliteInProduction"
            static let CorsAllowAll = "corsAllowAll"
            static let HttpNotHttps = "httpNotHttps"
            static let AppNameDefault = "appNameDefault"
        }
        struct Error {
            static let FetchUsersFailed = "admin.userManagement.fetchError"
        }
    }
}
