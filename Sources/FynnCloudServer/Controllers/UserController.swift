import Fluent
import Vapor

struct UserController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api", "user")
        let protected = api.grouped(UserPayloadAuthenticator(), UserPayload.guardMiddleware())
        protected.get("me", use: me)
        protected.get("quotas", use: apiQuotas)

        let admin = routes.grouped("api", "admin")
            .grouped(UserPayloadAuthenticator(), UserPayload.guardMiddleware(), AdminMiddleware())
        admin.get("users", use: listUsers)
        admin.post("users", use: adminCreateUser)
        admin.delete("users", ":userID", use: deleteUser)
        admin.put("users", ":userID", "tier", use: setUserTier)
        admin.post("users", ":userID", "groups", ":groupID", use: addUserGroup)
        admin.delete("users", ":userID", "groups", ":groupID", use: removeUserGroup)
        admin.get("groups", use: listGroups)
        admin.post("groups", use: createGroup)
        admin.put("groups", ":groupID", use: updateGroup)
        admin.delete("groups", ":groupID", use: deleteGroup)
        admin.put("groups", ":groupID", "tier", use: setGroupTier)
        admin.get("tiers", use: listTiers)
        admin.post("tiers", use: createTier)
        admin.put("tiers", ":tierID", use: updateTier)
        admin.delete("tiers", ":tierID", use: deleteTier)
    }

    func me(req: Request) async throws -> User.Public {
        let user = try await req.getFullUser()
        return try user.toPublic()
    }

    func apiQuotas(req: Request) async throws -> QuotaDTO {
        let user = try await req.getFullUser()

        var effectiveTier: StorageTier? = nil

        // Start with user's assigned tier if any
        if let userTierID = user.$tier.id {
            effectiveTier = try await StorageTier.find(userTierID, on: req.db)
        }

        // Check all groups for a higher tier
        for group in user.$groups.value ?? [] {
            try await group.$tier.load(on: req.db)
            if let groupTier = group.tier {
                if effectiveTier == nil || groupTier.limitBytes > (effectiveTier?.limitBytes ?? 0) {
                    effectiveTier = groupTier
                }
            }
        }

        return QuotaDTO(
            used: user.currentStorageUsage,
            limit: effectiveTier?.limitBytes ?? 0,
            tierName: effectiveTier?.name ?? "No Tier")
    }

    func listUsers(req: Request) async throws -> [User.Public] {
        let users = try await User.query(on: req.db)
            .with(\.$groups)
            .with(\.$tier)
            .all()
        return try users.map { try $0.toPublic() }
    }

    struct AdminCreateUserRequest: Content {
        var username: String
        var email: String
        var password: String
    }

    func adminCreateUser(req: Request) async throws -> User.Public {
        var body = try req.content.decode(AdminCreateUserRequest.self)
        body.username = body.username.lowercased()

        if try await User.query(on: req.db).filter(\.$username == body.username).first() != nil {
            throw Abort(.conflict, reason: "Username is already taken").localized(
                LocalizationKeys.Auth.Error.UserExists)
        }
        if try await User.query(on: req.db).filter(\.$email == body.email).first() != nil {
            throw Abort(.conflict, reason: "Email is already registered").localized(
                LocalizationKeys.Auth.Error.EmailExists)
        }

        try PasswordValidator.validate(password: body.password)
        let passwordHash = try Bcrypt.hash(body.password)
        let defaultTier = try await StorageTier.query(on: req.db)
            .filter(\.$limitBytes > 0)
            .sort(\.$limitBytes)
            .first()

        let user = User(
            username: body.username, email: body.email, passwordHash: passwordHash,
            tierID: defaultTier?.id)
        try await user.save(on: req.db)
        try await user.$groups.load(on: req.db)
        return try user.toPublic()
    }

    func deleteUser(req: Request) async throws -> HTTPStatus {
        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest).localized(LocalizationKeys.Common.Error.InvalidRequest)
        }
        guard let user = try await User.find(userID, on: req.db) else {
            throw Abort(.notFound).localized(LocalizationKeys.Common.Error.NotFound)
        }

        // Check if user is in admin group
        try await user.$groups.load(on: req.db)
        if let adminGroup = user.groups.first(where: { $0.isAdmin }) {
            // Count users in admin group
            let adminCount = try await UserGroup.query(on: req.db)
                .filter(\.$group.$id == adminGroup.requireID())
                .count()

            if adminCount <= 1 {
                throw Abort(.conflict, reason: "Cannot delete the last admin user")
            }
        }

        try await user.delete(on: req.db)
        return .noContent
    }

    struct SetTierRequest: Content {
        var tierID: Int?
    }

    func setUserTier(req: Request) async throws -> User.Public {
        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest).localized(LocalizationKeys.Common.Error.InvalidRequest)
        }
        let body = try req.content.decode(SetTierRequest.self)
        guard
            let user = try await User.query(on: req.db)
                .filter(\.$id == userID)
                .with(\.$groups)
                .first()
        else {
            throw Abort(.notFound).localized(LocalizationKeys.Common.Error.NotFound)
        }
        user.$tier.id = body.tierID
        try await user.save(on: req.db)
        return try user.toPublic()
    }

    func addUserGroup(req: Request) async throws -> User.Public {
        guard let userID = req.parameters.get("userID", as: UUID.self),
            let groupID = req.parameters.get("groupID", as: Int.self)
        else {
            throw Abort(.badRequest).localized(LocalizationKeys.Common.Error.InvalidRequest)
        }
        guard
            let user = try await User.query(on: req.db)
                .filter(\.$id == userID)
                .with(\.$groups)
                .first()
        else {
            throw Abort(.notFound).localized(LocalizationKeys.Common.Error.NotFound)
        }
        guard let group = try await Group.find(groupID, on: req.db) else {
            throw Abort(.notFound).localized(LocalizationKeys.Common.Error.NotFound)
        }
        let alreadyInGroup = user.$groups.value?.contains(where: { $0.id == groupID }) ?? false
        if !alreadyInGroup {
            try await user.$groups.attach(group, on: req.db)
            try await user.$groups.load(on: req.db)
        }
        return try user.toPublic()
    }

    func removeUserGroup(req: Request) async throws -> User.Public {
        guard let userID = req.parameters.get("userID", as: UUID.self),
            let groupID = req.parameters.get("groupID", as: Int.self)
        else {
            throw Abort(.badRequest).localized(LocalizationKeys.Common.Error.InvalidRequest)
        }
        guard
            let user = try await User.query(on: req.db)
                .filter(\.$id == userID)
                .with(\.$groups)
                .first()
        else {
            throw Abort(.notFound).localized(LocalizationKeys.Common.Error.NotFound)
        }
        guard let group = try await Group.find(groupID, on: req.db) else {
            throw Abort(.notFound).localized(LocalizationKeys.Common.Error.NotFound)
        }

        // Check if removing from an admin group
        if group.isAdmin {
            let adminCount = try await UserGroup.query(on: req.db)
                .filter(\.$group.$id == group.requireID())
                .count()
            if adminCount <= 1 {
                throw Abort(.conflict, reason: "Cannot remove the last user from the admin group")
            }
        }

        try await user.$groups.detach(group, on: req.db)
        try await user.$groups.load(on: req.db)
        return try user.toPublic()
    }

    func listGroups(req: Request) async throws -> [Group.Public] {
        let groups = try await Group.query(on: req.db).with(\.$tier).all()
        return try groups.map { try $0.toPublic() }
    }

    struct GroupRequest: Content {
        var name: String
    }

    func createGroup(req: Request) async throws -> Group.Public {
        let body = try req.content.decode(GroupRequest.self)
        let group = Group(name: body.name)
        try await group.create(on: req.db)
        try await group.$tier.load(on: req.db)
        return try group.toPublic()
    }

    func updateGroup(req: Request) async throws -> Group.Public {
        guard let groupID = req.parameters.get("groupID", as: Int.self) else {
            throw Abort(.badRequest).localized(LocalizationKeys.Common.Error.InvalidRequest)
        }
        let body = try req.content.decode(GroupRequest.self)
        guard let group = try await Group.find(groupID, on: req.db) else {
            throw Abort(.notFound).localized(LocalizationKeys.Common.Error.NotFound)
        }

        group.name = body.name
        try await group.save(on: req.db)
        try await group.$tier.load(on: req.db)  // Load tier for public dto
        return try group.toPublic()
    }

    func setGroupTier(req: Request) async throws -> Group.Public {
        guard let groupID = req.parameters.get("groupID", as: Int.self) else {
            throw Abort(.badRequest).localized(LocalizationKeys.Common.Error.InvalidRequest)
        }
        let body = try req.content.decode(SetTierRequest.self)
        guard
            let group = try await Group.query(on: req.db)
                .filter(\.$id == groupID)
                .with(\.$tier)
                .first()
        else {
            throw Abort(.notFound).localized(LocalizationKeys.Common.Error.NotFound)
        }
        group.$tier.id = body.tierID
        try await group.save(on: req.db)
        try await group.$tier.load(on: req.db)
        return try group.toPublic()
    }

    func deleteGroup(req: Request) async throws -> HTTPStatus {
        guard let groupID = req.parameters.get("groupID", as: Int.self) else {
            throw Abort(.badRequest).localized(LocalizationKeys.Common.Error.InvalidRequest)
        }
        guard let group = try await Group.find(groupID, on: req.db) else {
            throw Abort(.notFound).localized(LocalizationKeys.Common.Error.NotFound)
        }

        if group.isAdmin {
            throw Abort(.conflict, reason: "Cannot delete an admin group")
        }

        try await group.delete(on: req.db)
        return .noContent
    }

    func listTiers(req: Request) async throws -> [StorageTier] {
        try await StorageTier.query(on: req.db).all()
    }

    struct TierRequest: Content {
        var name: String
        var limitBytes: Int64
    }

    func createTier(req: Request) async throws -> StorageTier {
        let body = try req.content.decode(TierRequest.self)
        let tier = StorageTier(name: body.name, limitBytes: body.limitBytes)
        try await tier.save(on: req.db)
        return tier
    }

    func updateTier(req: Request) async throws -> StorageTier {
        guard let tierID = req.parameters.get("tierID", as: Int.self) else {
            throw Abort(.badRequest).localized(LocalizationKeys.Common.Error.InvalidRequest)
        }
        let body = try req.content.decode(TierRequest.self)
        guard let tier = try await StorageTier.find(tierID, on: req.db) else {
            throw Abort(.notFound).localized(LocalizationKeys.Common.Error.NotFound)
        }
        tier.name = body.name
        tier.limitBytes = body.limitBytes
        try await tier.save(on: req.db)
        return tier
    }

    func deleteTier(req: Request) async throws -> HTTPStatus {
        guard let tierID = req.parameters.get("tierID", as: Int.self) else {
            throw Abort(.badRequest).localized(LocalizationKeys.Common.Error.InvalidRequest)
        }
        guard let tier = try await StorageTier.find(tierID, on: req.db) else {
            throw Abort(.notFound).localized(LocalizationKeys.Common.Error.NotFound)
        }
        let usersCount = try await User.query(on: req.db).filter(\.$tier.$id == tierID).count()
        let groupsCount = try await Group.query(on: req.db).filter(\.$tier.$id == tierID).count()
        if usersCount > 0 || groupsCount > 0 {
            throw Abort(.conflict, reason: "Tier is still in use by users or groups")
        }
        try await tier.delete(on: req.db)
        return .noContent
    }
}
