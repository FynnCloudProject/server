import Fluent
import Vapor

struct UserController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api", "user")
        let protected = api.grouped(UserPayloadAuthenticator(), UserPayload.guardMiddleware())
        protected.get("me", use: me)
        protected.put("profile", use: updateProfile)
        protected.post("password", use: changePassword)
        protected.post("avatar", use: uploadAvatar)
        protected.delete("avatar", use: deleteAvatar)
        protected.get("quotas", use: apiQuotas)
        protected.get(":userID", "avatar", use: getAvatar)

        let admin = routes.grouped("api", "admin")
            .grouped(UserPayloadAuthenticator(), UserPayload.guardMiddleware(), AdminMiddleware())
        admin.get("users", use: listUsers)
        admin.post("users", use: adminCreateUser)
        admin.put("users", ":userID", use: adminUpdateUser)
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
        var pub = try user.toPublic()
        let totp = try await UserTOTP.query(on: req.db)
            .filter(\.$user.$id == user.requireID())
            .filter(\.$isEnabled == true)
            .first()
        pub.twoFactorEnabled = totp != nil
        return pub
    }

    func updateProfile(req: Request) async throws -> User.Public {
        let user = try await req.getFullUser()
        let body = try req.content.decode(UpdateProfileRequest.self)

        let updatedUser = try await req.userService.updateUser(
            user: user,
            displayName: body.displayName != nil ? .set(body.displayName) : .ignore,
            email: body.email != nil ? .set(body.email!) : .ignore
        )
        return try updatedUser.toPublic()
    }

    func changePassword(req: Request) async throws -> HTTPStatus {
        let user = try await req.getFullUser()
        let body = try req.content.decode(ChangePasswordRequest.self)

        try await req.userService.changePassword(
            user: user,
            currentPassword: body.currentPassword,
            newPassword: body.newPassword
        )

        let userID = try user.requireID()
        req.logger(subsystem: .auth).info(
            "User password changed",
            metadata: ["user_id": .stringConvertible(userID)]
        )

        return .noContent
    }

    func uploadAvatar(req: Request) async throws -> User.Public {
        let user = try await req.getFullUser()
        let body = try req.content.decode(UploadAvatarRequest.self)
        let file = body.avatar

        guard file.data.readableBytes <= 5 * 1024 * 1024 else {
            throw Abort(.payloadTooLarge, reason: "Avatar image must be smaller than 5 MB")
        }

        let contentType = file.contentType?.description.lowercased() ?? ""
        let filename = file.filename.lowercased()
        let validTypes = ["image/jpeg", "image/jpg", "image/png", "image/webp", "image/gif"]
        let validExtensions = [".jpg", ".jpeg", ".png", ".webp", ".gif"]

        let isValidType = validTypes.contains { contentType.contains($0) }
        let isValidExt = validExtensions.contains { filename.hasSuffix($0) }

        guard isValidType || isValidExt else {
            throw Abort(.badRequest, reason: "Avatar must be an image (JPEG, PNG, WebP, GIF)")
        }

        let userID = try user.requireID()
        let processedBuffer = try await AvatarProcessor.process(buffer: file.data)
        try await req.storageService.storeAvatar(userID: userID, buffer: processedBuffer)

        user.avatarUpdatedAt = Date()
        try await user.save(on: req.db)
        try await user.$groups.load(on: req.db)
        try await user.$tier.load(on: req.db)
        return try user.toPublic()
    }

    func deleteAvatar(req: Request) async throws -> User.Public {
        let user = try await req.getFullUser()
        let userID = try user.requireID()

        try await req.storageService.deleteAvatar(userID: userID)

        user.avatarUpdatedAt = nil
        try await user.save(on: req.db)
        try await user.$groups.load(on: req.db)
        try await user.$tier.load(on: req.db)
        return try user.toPublic()
    }

    func getAvatar(req: Request) async throws -> Response {
        _ = try req.auth.require(UserPayload.self)
        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest).localized(LocalizationKeys.Error.Http.InvalidRequest)
        }

        let response = try await req.storageService.avatarResponse(userID: userID)
        response.apply(.derived, contentType: "image/jpeg")
        return response
    }

    func apiQuotas(req: Request) async throws -> QuotaDTO {
        let user = try await req.getFullUser()
        let usage = try await req.quotaService.usage(for: try user.requireID())

        // Committed only. Reservations are an internal admission detail: surfacing them would
        // make the bar jump mid-upload and, since a multipart hold outlives the tab, leave
        // phantom usage against no visible file.
        return QuotaDTO(
            used: usage.committed,
            limit: usage.limit,
            tierName: try await effectiveTierName(for: user, on: req))
    }

    /// Name only - the limit itself comes from `QuotaService`, so what is displayed cannot
    /// disagree with what admission enforces. Mirrors its precedence: a tier assigned directly to
    /// the user wins outright, otherwise the most generous group tier applies.
    private func effectiveTierName(for user: User, on req: Request) async throws -> String {
        if let userTierID = user.$tier.id {
            return try await StorageTier.find(userTierID, on: req.db)?.name ?? "No Tier"
        }

        let groups = try await req.userService.getEffectiveGroups(
            for: try user.requireID(), on: req.db)
        var best: StorageTier? = nil
        for group in groups {
            try await group.$tier.load(on: req.db)
            if let tier = group.tier, tier.limitBytes > (best?.limitBytes ?? -1) {
                best = tier
            }
        }
        return best?.name ?? "No Tier"
    }

    func listUsers(req: Request) async throws -> [User.Public] {
        let users = try await User.query(on: req.db)
            .with(\.$groups)
            .with(\.$tier)
            .all()

        // Membership provenance: map userID -> { groupID: source } for SSO-granted memberships.
        let ssoPivots = try await UserGroup.query(on: req.db)
            .filter(\.$source != "manual")
            .all()
        var sources: [UUID: [String: String]] = [:]
        for pivot in ssoPivots {
            sources[pivot.$user.id, default: [:]][String(pivot.$group.id)] = pivot.source
        }

        return try users.map { user in
            var pub = try user.toPublic()
            if let map = sources[try user.requireID()], !map.isEmpty {
                pub.ssoGroupSources = map
            }
            return pub
        }
    }

    func adminCreateUser(req: Request) async throws -> User.Public {
        let body = try req.content.decode(AdminCreateUserRequest.self)

        let user = try await req.userService.createUser(
            input: .init(
                username: body.username,
                email: body.email,
                password: body.password,
                displayName: body.displayName
            )
        )

        let createdID = try user.requireID()
        req.logger(subsystem: .admin).info(
            "Admin created user",
            metadata: [
                "created_user_id": .stringConvertible(createdID),
                "created_username": .string(user.username),
            ]
        )

        return try user.toPublic()
    }

    func adminUpdateUser(req: Request) async throws -> User.Public {
        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest).localized(LocalizationKeys.Error.Http.InvalidRequest)
        }
        guard let user = try await User.find(userID, on: req.db) else {
            throw Abort(.notFound).localized(LocalizationKeys.Error.Http.NotFound)
        }
        let body = try req.content.decode(AdminUpdateUserRequest.self)

        let updatedUser = try await req.userService.updateUser(
            user: user,
            displayName: body.displayName != nil ? .set(body.displayName) : .ignore,
            email: body.email != nil ? .set(body.email!) : .ignore,
            password: body.password != nil ? .set(body.password!) : .ignore,
            tierID: body.tierID != nil ? .set(body.tierID) : .ignore
        )
        return try updatedUser.toPublic()
    }

    func deleteUser(req: Request) async throws -> HTTPStatus {
        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest).localized(LocalizationKeys.Error.Http.InvalidRequest)
        }
        guard let user = try await User.find(userID, on: req.db) else {
            throw Abort(.notFound).localized(LocalizationKeys.Error.Http.NotFound)
        }

        try await req.userService.deleteUser(user: user, fileService: req.fileService)

        req.logger(subsystem: .admin).info(
            "Admin deleted user",
            metadata: [
                "deleted_user_id": .stringConvertible(userID),
                "deleted_username": .string(user.username),
            ]
        )

        return .noContent
    }

    func setUserTier(req: Request) async throws -> User.Public {
        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest).localized(LocalizationKeys.Error.Http.InvalidRequest)
        }
        let body = try req.content.decode(SetTierRequest.self)
        guard
            let user = try await User.query(on: req.db)
                .filter(\.$id == userID)
                .with(\.$groups)
                .first()
        else {
            throw Abort(.notFound).localized(LocalizationKeys.Error.Http.NotFound)
        }
        user.$tier.id = body.tierID
        try await user.save(on: req.db)
        return try user.toPublic()
    }

    func addUserGroup(req: Request) async throws -> User.Public {
        guard let userID = req.parameters.get("userID", as: UUID.self),
            let groupID = req.parameters.get("groupID", as: Int.self)
        else {
            throw Abort(.badRequest).localized(LocalizationKeys.Error.Http.InvalidRequest)
        }
        guard
            let user = try await User.query(on: req.db)
                .filter(\.$id == userID)
                .with(\.$groups)
                .first()
        else {
            throw Abort(.notFound).localized(LocalizationKeys.Error.Http.NotFound)
        }
        guard let group = try await Group.find(groupID, on: req.db) else {
            throw Abort(.notFound).localized(LocalizationKeys.Error.Http.NotFound)
        }
        if group.systemKey != nil && group.systemKey != "admin" {
            throw Abort(.forbidden, reason: "Cannot modify user membership of a system group")
        }
        let alreadyInGroup = user.$groups.value?.contains(where: { $0.id == groupID }) ?? false
        if !alreadyInGroup {
            try await user.$groups.attach(group, on: req.db)
            try await user.$groups.load(on: req.db)

            req.logger(subsystem: .admin).info(
                "Admin added user to group",
                metadata: [
                    "user_id": .stringConvertible(userID),
                    "group_id": .stringConvertible(groupID),
                    "group_name": .string(group.name),
                ]
            )
        }
        return try user.toPublic()
    }

    func removeUserGroup(req: Request) async throws -> User.Public {
        guard let userID = req.parameters.get("userID", as: UUID.self),
            let groupID = req.parameters.get("groupID", as: Int.self)
        else {
            throw Abort(.badRequest).localized(LocalizationKeys.Error.Http.InvalidRequest)
        }
        guard
            let user = try await User.query(on: req.db)
                .filter(\.$id == userID)
                .with(\.$groups)
                .first()
        else {
            throw Abort(.notFound).localized(LocalizationKeys.Error.Http.NotFound)
        }
        guard let group = try await Group.find(groupID, on: req.db) else {
            throw Abort(.notFound).localized(LocalizationKeys.Error.Http.NotFound)
        }
        if group.systemKey != nil && group.systemKey != "admin" {
            throw Abort(.forbidden, reason: "Cannot modify user membership of a system group")
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

        req.logger(subsystem: .admin).info(
            "Admin removed user from group",
            metadata: [
                "user_id": .stringConvertible(userID),
                "group_id": .stringConvertible(groupID),
                "group_name": .string(group.name),
            ]
        )

        return try user.toPublic()
    }

    func listGroups(req: Request) async throws -> [Group.Public] {
        let groups = try await Group.query(on: req.db).with(\.$tier).all()
        return try groups.map { try $0.toPublic() }
    }

    func createGroup(req: Request) async throws -> Group.Public {
        let body = try req.content.decode(GroupRequest.self)
        let trimmedName = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw Abort(.badRequest).localized(LocalizationKeys.Error.Http.InvalidRequest)
        }
        let group = Group(name: trimmedName, isAdmin: body.isAdmin ?? false)
        try await group.create(on: req.db)
        try await group.$tier.load(on: req.db)
        return try group.toPublic()
    }

    func updateGroup(req: Request) async throws -> Group.Public {
        guard let groupID = req.parameters.get("groupID", as: Int.self) else {
            throw Abort(.badRequest).localized(LocalizationKeys.Error.Http.InvalidRequest)
        }
        let body = try req.content.decode(GroupRequest.self)
        guard let group = try await Group.find(groupID, on: req.db) else {
            throw Abort(.notFound).localized(LocalizationKeys.Error.Http.NotFound)
        }

        let trimmedName = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw Abort(.badRequest).localized(LocalizationKeys.Error.Http.InvalidRequest)
        }

        if group.systemKey != nil {
            if trimmedName != group.name {
                throw Abort(.forbidden, reason: "System groups cannot be renamed")
            }
            if group.systemKey == "admin" {
                if let newIsAdmin = body.isAdmin, !newIsAdmin {
                    throw Abort(
                        .forbidden, reason: "System admin group must retain admin permissions")
                }
            } else if group.systemKey == "all_users" {
                if let newIsAdmin = body.isAdmin, newIsAdmin {
                    throw Abort(
                        .forbidden,
                        reason: "The All Users system group cannot be granted admin permissions")
                }
            }
        } else {
            group.name = trimmedName
        }

        if let newIsAdmin = body.isAdmin {
            if group.isAdmin && !newIsAdmin {
                let allUsersCount = try await User.query(on: req.db).count()
                if allUsersCount > 0 {
                    let otherAdminGroups = try await Group.query(on: req.db)
                        .filter(\.$isAdmin == true)
                        .filter(\.$id != group.requireID())
                        .all()
                    let otherAdminGroupIDs = otherAdminGroups.compactMap { $0.id }

                    let remainingAdminUsersCount = try await UserGroup.query(on: req.db)
                        .filter(\.$group.$id ~~ otherAdminGroupIDs)
                        .count()

                    if remainingAdminUsersCount == 0 {
                        throw Abort(
                            .conflict,
                            reason:
                                "Cannot remove admin permissions: at least one admin user must remain"
                        )
                    }
                }
            }
            group.isAdmin = newIsAdmin
        }

        try await group.save(on: req.db)
        try await group.$tier.load(on: req.db)  // Load tier for public dto
        return try group.toPublic()
    }

    func setGroupTier(req: Request) async throws -> Group.Public {
        guard let groupID = req.parameters.get("groupID", as: Int.self) else {
            throw Abort(.badRequest).localized(LocalizationKeys.Error.Http.InvalidRequest)
        }
        let body = try req.content.decode(SetTierRequest.self)
        guard
            let group = try await Group.query(on: req.db)
                .filter(\.$id == groupID)
                .with(\.$tier)
                .first()
        else {
            throw Abort(.notFound).localized(LocalizationKeys.Error.Http.NotFound)
        }
        group.$tier.id = body.tierID
        try await group.save(on: req.db)
        try await group.$tier.load(on: req.db)
        return try group.toPublic()
    }

    func deleteGroup(req: Request) async throws -> HTTPStatus {
        guard let groupID = req.parameters.get("groupID", as: Int.self) else {
            throw Abort(.badRequest).localized(LocalizationKeys.Error.Http.InvalidRequest)
        }
        guard let group = try await Group.find(groupID, on: req.db) else {
            throw Abort(.notFound).localized(LocalizationKeys.Error.Http.NotFound)
        }

        if group.systemKey != nil {
            throw Abort(.conflict, reason: "Cannot delete a system group")
        }

        if group.isAdmin {
            let allUsersCount = try await User.query(on: req.db).count()
            if allUsersCount > 0 {
                let otherAdminGroups = try await Group.query(on: req.db)
                    .filter(\.$isAdmin == true)
                    .filter(\.$id != group.requireID())
                    .all()
                let otherAdminGroupIDs = otherAdminGroups.compactMap { $0.id }

                let remainingAdminUsersCount = try await UserGroup.query(on: req.db)
                    .filter(\.$group.$id ~~ otherAdminGroupIDs)
                    .count()

                if remainingAdminUsersCount == 0 {
                    throw Abort(
                        .conflict,
                        reason: "Cannot delete group: at least one admin user must remain")
                }
            }
        }

        try await group.delete(on: req.db)
        return .noContent
    }

    func listTiers(req: Request) async throws -> [StorageTier] {
        try await StorageTier.query(on: req.db).all()
    }

    func createTier(req: Request) async throws -> StorageTier {
        let body = try req.content.decode(TierRequest.self)
        let tier = StorageTier(name: body.name, limitBytes: body.limitBytes)
        try await tier.save(on: req.db)
        return tier
    }

    func updateTier(req: Request) async throws -> StorageTier {
        guard let tierID = req.parameters.get("tierID", as: Int.self) else {
            throw Abort(.badRequest).localized(LocalizationKeys.Error.Http.InvalidRequest)
        }
        let body = try req.content.decode(TierRequest.self)
        guard let tier = try await StorageTier.find(tierID, on: req.db) else {
            throw Abort(.notFound).localized(LocalizationKeys.Error.Http.NotFound)
        }
        tier.name = body.name
        tier.limitBytes = body.limitBytes
        try await tier.save(on: req.db)
        return tier
    }

    func deleteTier(req: Request) async throws -> HTTPStatus {
        guard let tierID = req.parameters.get("tierID", as: Int.self) else {
            throw Abort(.badRequest).localized(LocalizationKeys.Error.Http.InvalidRequest)
        }
        guard let tier = try await StorageTier.find(tierID, on: req.db) else {
            throw Abort(.notFound).localized(LocalizationKeys.Error.Http.NotFound)
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
