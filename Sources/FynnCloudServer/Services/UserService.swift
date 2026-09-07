import Fluent
import Redis
import Vapor

struct UserService {
    let db: any Database
    let subscriptionService: SubscriptionService
    let redis: any RedisClient

    struct CreateInput {
        var username: String
        var email: String
        /// `nil` provisions an SSO-only account with no local password.
        var password: String?
        var displayName: String? = nil
        var tierID: Int? = nil
        var isFirstUserCheck: Bool = false
    }

    enum OptionalField<T> {
        case ignore
        case set(T)
    }

    func createUser(input: CreateInput) async throws -> User {
        let username = input.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let email = input.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !username.isEmpty && !email.isEmpty else {
            throw Abort(.badRequest, reason: "Username and email cannot be empty").localized(
                LocalizationKeys.Error.Auth.MissingParams)
        }

        if try await User.query(on: db).filter(\.$username == username).first() != nil {
            throw Abort(.conflict, reason: "Username is already taken").localized(
                LocalizationKeys.Error.Auth.UserExists)
        }

        if try await User.query(on: db).filter(\.$email == email).first() != nil {
            throw Abort(.conflict, reason: "Email is already registered").localized(
                LocalizationKeys.Error.Auth.EmailExists)
        }

        var isFirstUser = false
        if input.isFirstUserCheck {
            let count = try await User.query(on: db).count()
            isFirstUser = (count == 0)
        }

        // Enforce subscription user limit (skip for the first-user bootstrap)
        if !isFirstUser {
            if let maxUsers = await subscriptionService.effectiveMaxUsers() {
                let currentCount = try await User.query(on: db).count()
                if currentCount >= maxUsers {
                    let hasSub = await subscriptionService.hasSubscription()
                    let reason = hasSub
                        ? "User limit reached. Your subscription allows a maximum of \(maxUsers) users."
                        : "User limit reached. A subscription key is required to register more than \(maxUsers) users."
                    throw Abort(.forbidden, reason: reason)
                }
            }
        }

        let passwordHash: String
        if let password = input.password {
            try PasswordValidator.validate(password: password)
            passwordHash = try Bcrypt.hash(password)
        } else {
            passwordHash = ""  // SSO-only account: no local password
        }

        let selectedTierID: Int? = input.tierID

        let trimmedDisplayName = input.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalDisplayName =
            (trimmedDisplayName != nil && !trimmedDisplayName!.isEmpty)
            ? trimmedDisplayName! : username

        let user = User(
            username: username,
            email: email,
            passwordHash: passwordHash,
            displayName: finalDisplayName,
            tierID: selectedTierID
        )
        try await user.save(on: db)

        if isFirstUser {
            var adminGroup = try await Group.query(on: db)
                .filter(\.$systemKey == "admin")
                .first()
            if adminGroup == nil {
                adminGroup = try await Group.query(on: db)
                    .filter(\.$isAdmin == true)
                    .first()
            }
            if let adminGroup {
                try await user.$groups.attach(adminGroup, on: db)
            }
        }

        try await user.$groups.load(on: db)
        try await user.$tier.load(on: db)
        return user
    }

    func updateUser(
        user: User,
        displayName: OptionalField<String?> = .ignore,
        email: OptionalField<String> = .ignore,
        password: OptionalField<String> = .ignore,
        tierID: OptionalField<Int?> = .ignore
    ) async throws -> User {
        if case .set(let newDisplayName) = displayName {
            if let name = newDisplayName {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                user.displayName = trimmed.isEmpty ? nil : trimmed
            } else {
                user.displayName = nil
            }
        }

        if case .set(let newEmail) = email {
            let trimmedEmail = newEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !trimmedEmail.isEmpty && trimmedEmail != user.email {
                let existing = try await User.query(on: db)
                    .filter(\.$email == trimmedEmail)
                    .filter(\.$id != user.requireID())
                    .first()
                if existing != nil {
                    throw Abort(.conflict, reason: "Email is already registered").localized(
                        LocalizationKeys.Error.Auth.EmailExists)
                }
                user.email = trimmedEmail
            }
        }

        if case .set(let newPassword) = password {
            try PasswordValidator.validate(password: newPassword)
            user.passwordHash = try Bcrypt.hash(newPassword)
        }

        if case .set(let newTierID) = tierID {
            user.$tier.id = newTierID
        }

        try await user.save(on: db)
        try await user.$groups.load(on: db)
        try await user.$tier.load(on: db)
        return user
    }

    func changePassword(
        user: User,
        currentPassword: String,
        newPassword: String
    ) async throws {
        guard try user.verify(password: currentPassword) else {
            throw Abort(.badRequest, reason: "Current password is incorrect").localized(
                LocalizationKeys.Error.Auth.Credentials)
        }

        try PasswordValidator.validate(password: newPassword)
        user.passwordHash = try Bcrypt.hash(newPassword)
        try await user.save(on: db)
    }

    func deleteUser(user: User, fileService: FileService) async throws {
        try await user.$groups.load(on: db)
        if user.groups.contains(where: { $0.isAdmin }) {
            let otherAdminCount = try await UserGroup.query(on: db)
                .join(Group.self, on: \UserGroup.$group.$id == \Group.$id)
                .filter(Group.self, \.$isAdmin == true)
                .filter(\.$user.$id != user.requireID())
                .count()

            if otherAdminCount == 0 {
                throw Abort(.conflict, reason: "Cannot delete the last admin user")
            }
        }

        let userID = try user.requireID()

        let revokedGrantIDs = try await OAuthGrant.query(on: db).filter(\.$user.$id == userID).all(\.$id)
        try await OAuthGrant.query(on: db).filter(\.$user.$id == userID).delete()
        await GrantValidityCache.invalidate(grantIDs: revokedGrantIDs, on: redis)
        await SessionActivityService.remove(grantIDs: revokedGrantIDs, on: redis)

        try await UserIdentity.query(on: db).filter(\.$user.$id == userID).delete()
        try await SyncLog.query(on: db).filter(\.$user.$id == userID).delete()
        do {
            try await SyncCursor.query(on: db).filter(\.$user.$id == userID).delete()
        } catch {
            // sync_cursors table is only created on PostgreSQL in RewriteSyncInfrastructure
        }
        try await ShareLink.query(on: db).filter(\.$creator.$id == userID).delete()
        try await UserGroup.query(on: db).filter(\.$user.$id == userID).delete()
        try await UserFavorite.query(on: db).filter(\.$user.$id == userID).delete()

        // Delete user storage data & file metadata
        try await fileService.deleteAllUserData(userID: userID)

        try await user.delete(on: db)
    }

    // MARK: - Effective Groups & Permissions

    /// Returns the IDs of all groups a user effectively belongs to, including
    /// explicit group memberships (via `user_groups`) and virtual system groups
    /// (such as the "All Users" system group).
    func getEffectiveGroupIDs(for userID: UUID, on specificDB: (any Database)? = nil) async throws -> [Int] {
        let activeDB = specificDB ?? self.db
        return try await Self.getEffectiveGroupIDs(for: userID, on: activeDB)
    }

    /// Static version for callers that have a Database instance without a full UserService context.
    static func getEffectiveGroupIDs(for userID: UUID, on database: any Database) async throws -> [Int] {
        let userGroupIDs = try await UserGroup.query(on: database)
            .filter(\.$user.$id == userID)
            .all()
            .map { $0.$group.id }

        let allUsersGroup = try await Group.query(on: database)
            .filter(\.$systemKey == "all_users")
            .first()

        var groupIDs = userGroupIDs
        if let allUsersID = allUsersGroup?.id, !groupIDs.contains(allUsersID) {
            groupIDs.append(allUsersID)
        }
        return groupIDs
    }

    /// Returns all Group models a user effectively belongs to, including
    /// explicit group memberships (via `user_groups`) and virtual system groups
    /// (such as the "All Users" system group).
    func getEffectiveGroups(for userID: UUID, on specificDB: (any Database)? = nil) async throws -> [Group] {
        let activeDB = specificDB ?? self.db
        return try await Self.getEffectiveGroups(for: userID, on: activeDB)
    }

    /// Static version for callers that have a Database instance without a full UserService context.
    static func getEffectiveGroups(for userID: UUID, on database: any Database) async throws -> [Group] {
        let userGroupIDs = try await UserGroup.query(on: database)
            .filter(\.$user.$id == userID)
            .all()
            .map { $0.$group.id }

        return try await Group.query(on: database)
            .group(.or) { orGroup in
                if !userGroupIDs.isEmpty {
                    orGroup.filter(\.$id ~~ userGroupIDs)
                }
                orGroup.filter(\.$systemKey == "all_users")
            }
            .all()
    }

    // MARK: - Registration Policy

    /// Whether a new user may self-register. Always true while no users exist yet (admin bootstrap),
    /// otherwise governed by the `RegistrationEnabled` setting.
    func isRegistrationAllowed(settings: SettingsService) async throws -> Bool {
        try await Self.isRegistrationAllowed(on: self.db, settings: settings)
    }

    /// Static version for callers that have a Database instance without a full UserService context.
    static func isRegistrationAllowed(on database: any Database, settings: SettingsService) async throws -> Bool {
        if try await settings.get(AppSettings.RegistrationEnabled.self) { return true }
        return try await User.query(on: database).count() == 0
    }
}

