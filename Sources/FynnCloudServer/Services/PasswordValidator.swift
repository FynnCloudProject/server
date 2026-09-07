import Vapor

struct PasswordValidator {
    static func validate(password: String) throws {
        guard password.count >= 8 else {
            throw Abort(.badRequest, reason: "Password must be at least 8 characters long")
                .localized(
                    LocalizationKeys.Error.Auth.PasswordTooShort)
        }

        guard password.range(of: "[A-Z]", options: .regularExpression) != nil else {
            throw Abort(.badRequest, reason: "Password must contain at least one uppercase letter")
                .localized(
                    LocalizationKeys.Error.Auth.PasswordMissingUppercase)
        }

        guard password.range(of: "[a-z]", options: .regularExpression) != nil else {
            throw Abort(.badRequest, reason: "Password must contain at least one lowercase letter")
                .localized(
                    LocalizationKeys.Error.Auth.PasswordMissingLowercase)
        }

        guard password.range(of: "[0-9]", options: .regularExpression) != nil else {
            throw Abort(.badRequest, reason: "Password must contain at least one digit").localized(
                LocalizationKeys.Error.Auth.PasswordMissingNumber)
        }

        guard password.range(of: "[^a-zA-Z0-9]", options: .regularExpression) != nil else {
            throw Abort(.badRequest, reason: "Password must contain at least one special character")
                .localized(LocalizationKeys.Error.Auth.PasswordMissingSpecialCharacter)
        }
    }
}
