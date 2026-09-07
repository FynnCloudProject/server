import Vapor

// MARK: - User Request DTOs

struct UpdateProfileRequest: Content {
    var displayName: String?
    var email: String?
}

struct ChangePasswordRequest: Content {
    var currentPassword: String
    var newPassword: String
}

struct UploadAvatarRequest: Content {
    var avatar: File
}

struct AdminCreateUserRequest: Content {
    var username: String
    var email: String
    var password: String
    var displayName: String?
}

struct AdminUpdateUserRequest: Content {
    var displayName: String?
    var email: String?
    var password: String?
    var tierID: Int?
}

struct SetTierRequest: Content {
    var tierID: Int?
}

struct GroupRequest: Content {
    var name: String
    var isAdmin: Bool?
}

struct TierRequest: Content {
    var name: String
    var limitBytes: Int64
}
