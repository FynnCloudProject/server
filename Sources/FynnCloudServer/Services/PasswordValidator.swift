import Vapor

struct PasswordValidator {
    static func validate(password: String) throws {
        // Minimum 8 characters
        guard password.count >= 8 else {
            throw Abort(.badRequest, reason: "Password must be at least 8 characters long")
                .localized(
                    LocalizationKeys.Auth.Error.PasswordTooShort)
        }

        // At least 1 uppercase letter
        guard password.range(of: "[A-Z]", options: .regularExpression) != nil else {
            throw Abort(.badRequest, reason: "Password must contain at least one uppercase letter")
                .localized(
                    LocalizationKeys.Auth.Error.PasswordMissingUppercase)
        }

        // At least 1 lowercase letter
        guard password.range(of: "[a-z]", options: .regularExpression) != nil else {
            throw Abort(.badRequest, reason: "Password must contain at least one lowercase letter")
                .localized(
                    LocalizationKeys.Auth.Error.PasswordMissingLowercase)
        }

        // At least 1 digit
        guard password.range(of: "[0-9]", options: .regularExpression) != nil else {
            throw Abort(.badRequest, reason: "Password must contain at least one digit").localized(
                LocalizationKeys.Auth.Error.PasswordMissingNumber)
        }

        // At least 1 special character
        guard password.range(of: "[^a-zA-Z0-9]", options: .regularExpression) != nil else {
            throw Abort(.badRequest, reason: "Password must contain at least one special character")
                .localized(LocalizationKeys.Auth.Error.PasswordMissingSpecialCharacter)
        }
    }
}
