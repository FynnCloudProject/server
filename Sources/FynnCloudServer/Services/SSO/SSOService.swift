import Fluent
import Vapor

/// Maps a verified `ExternalIdentity` (from any SSO provider) to a local `User`.
///
/// This is the only SSO component that touches persistence. Resolution order:
///  1. Existing `(provider, subject)` link - authoritative.
///  2. Link by verified email to an existing local account (only when the provider
///     asserts the email is verified - otherwise account-takeover risk).
///  3. Just-in-time provisioning of a new, password-less local account.
struct SSOService {
    let db: any Database
    let userService: UserService
    let logger: Logger
    /// External group/role -> local group `systemKey` or `name`. Empty disables group mapping.
    let groupMap: [String: String]
    /// When true, auto-create a local group per external group and mirror membership.
    let groupImportEnabled: Bool
    /// When true, attach the user to any pre-existing plain local group whose
    /// name/systemKey matches an external group.
    let groupAutoMatch: Bool
    /// Prefix applied to imported group names.
    let groupPrefix: String
    /// When true, auto-create a local user account on first SSO login if no account exists yet.
    let autoProvision: Bool

    init(
        db: any Database,
        userService: UserService,
        logger: Logger,
        groupMap: [String: String] = [:],
        groupImportEnabled: Bool = false,
        groupAutoMatch: Bool = false,
        groupPrefix: String = "",
        autoProvision: Bool = true
    ) {
        self.db = db
        self.userService = userService
        self.logger = logger
        self.groupMap = groupMap
        self.groupImportEnabled = groupImportEnabled
        self.groupAutoMatch = groupAutoMatch
        self.groupPrefix = groupPrefix
        self.autoProvision = autoProvision
    }

    /// Resolve (and lazily provision/link) the local `User` for an external identity.
    /// The returned user has `groups` and `tier` loaded.
    func resolveUser(_ identity: ExternalIdentity) async throws -> User {
        let user: User

        if let link = try await UserIdentity.query(on: db)
            .filter(\.$provider == identity.provider)
            .filter(\.$subject == identity.subject)
            .with(\.$user)
            .first()
        {
            user = link.user
            try await syncProfile(user, from: identity)
        }
        // 2. Link by verified email to an existing local account.
        else if identity.emailVerified,
            let email = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
            !email.isEmpty,
            let existing = try await User.query(on: db).filter(\.$email == email).first()
        {
            try await UserIdentity(
                userID: existing.requireID(),
                provider: identity.provider,
                subject: identity.subject
            ).save(on: db)
            logger.scoped(to: .sso).info(
                "SSO identity linked to existing user",
                metadata: [
                    "provider": .string(identity.provider),
                    "subject": .string(identity.subject),
                    "email": .string(email),
                ]
            )
            try await syncProfile(existing, from: identity)
            user = existing
        } else {
            guard autoProvision else {
                logger.scoped(to: .sso).warning(
                    "SSO user auto-provisioning is disabled; rejected login",
                    metadata: [
                        "provider": .string(identity.provider),
                        "subject": .string(identity.subject),
                    ]
                )
                throw Abort(
                    .forbidden,
                    reason:
                        "SSO user auto-provisioning is disabled. Please contact your administrator."
                )
            }
            user = try await provision(identity)
        }

        try await reconcileGroups(user, identity: identity)
        return try await withRelations(user)
    }

    // MARK: - Private

    private func provision(_ identity: ExternalIdentity) async throws -> User {
        guard
            let email = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
            !email.isEmpty
        else {
            throw Abort(
                .unauthorized,
                reason: "SSO identity is missing an email address; cannot provision an account.")
        }

        let base =
            identity.username.isEmpty
            ? String(email.prefix(while: { $0 != "@" }))
            : identity.username
        let username = try await availableUsername(base: base)

        let user = try await userService.createUser(
            input: .init(
                username: username,
                email: email,
                password: nil,  // SSO-only account: no local password
                displayName: identity.displayName
            )
        )

        try await UserIdentity(
            userID: user.requireID(),
            provider: identity.provider,
            subject: identity.subject
        ).save(on: db)

        logger.scoped(to: .sso).info(
            "Provisioned new SSO user",
            metadata: [
                "username": .string(username),
                "provider": .string(identity.provider),
                "subject": .string(identity.subject),
            ]
        )
        return user
    }

    /// Find a free username derived from `base`, appending a numeric suffix on collision.
    private func availableUsername(base: String) async throws -> String {
        let sanitized =
            base
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let root = sanitized.isEmpty ? "user" : sanitized

        var candidate = root
        var suffix = 0
        while true {
            if try await User.query(on: db).filter(\.$username == candidate).first() == nil {
                return candidate
            }
            suffix += 1
            candidate = "\(root)\(suffix)"
        }
    }

    /// Keep the local profile in sync with the provider on each login. The username is deliberately
    /// **not** synced: it is assigned once at provision time and is a stable local identifier
    /// (used for WebDAV logins, sharing and mentions), so a directory rename must not rewrite it.
    private func syncProfile(_ user: User, from identity: ExternalIdentity) async throws {
        guard
            let displayName = identity.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !displayName.isEmpty,
            user.displayName != displayName
        else { return }

        user.displayName = displayName
        try await user.save(on: db)
    }

    /// Reconciles the user's group memberships for this login's provider. Builds the set of local
    /// groups the provider should grant (import-managed + auto-matched + elevation-mapped), attaches
    /// missing ones tagged with the provider as `source`, and detaches only memberships **this
    /// provider** previously granted that are no longer present - never touching `manual` assignments
    /// or another provider's rows. The last admin is never demoted.
    private func reconcileGroups(_ user: User, identity: ExternalIdentity) async throws {
        guard groupImportEnabled || groupAutoMatch || !groupMap.isEmpty else { return }

        let userID = try user.requireID()
        let provider = identity.provider
        let externalGroups = identity.groups
        var desired = Set<Int>()

        // Import: one managed group per external group (created if missing).
        if groupImportEnabled {
            for name in Set(externalGroups.map { groupPrefix + $0 }) {
                if let group = try await findOrCreateManagedGroup(named: name, source: provider),
                    let id = group.id
                {
                    desired.insert(id)
                }
            }
        }

        // Auto-match: pre-existing groups by name/systemKey.
        if groupAutoMatch, !externalGroups.isEmpty {
            let names = Set(externalGroups)
            let candidates = try await Group.query(on: db)
                .group(.or) { or in
                    for name in names {
                        or.filter(\.$name == name)
                        or.filter(\.$systemKey == name)
                    }
                }
                .all()
            for group in candidates {
                if let id = group.id { desired.insert(id) }
            }
        }

        // Manual group assignment map
        if !groupMap.isEmpty {
            let desiredKeys = Set(externalGroups.compactMap { groupMap[$0] })
            if !desiredKeys.isEmpty {
                let mapped = try await Group.query(on: db)
                    .group(.or) { or in
                        for key in desiredKeys {
                            or.filter(\.$systemKey == key)
                            or.filter(\.$name == key)
                        }
                    }
                    .all()
                for group in mapped { if let id = group.id { desired.insert(id) } }
            }
        }

        let pivots = try await UserGroup.query(on: db).filter(\.$user.$id == userID).all()
        let memberGroupIDs = Set(pivots.map { $0.$group.id })

        // Attach newly-entitled groups, tagged with this provider as the source.
        for groupID in desired where !memberGroupIDs.contains(groupID) {
            try await UserGroup(userID: userID, groupID: groupID, source: provider).create(on: db)
        }

        // Detach only this provider's now-stale memberships (never manual/other-provider rows).
        let stale = pivots.filter { $0.source == provider && !desired.contains($0.$group.id) }
        guard !stale.isEmpty else { return }

        let adminGroupIDs = Set(
            try await Group.query(on: db)
                .filter(\.$id ~~ stale.map { $0.$group.id })
                .filter(\.$isAdmin == true)
                .all()
                .compactMap { $0.id })

        for pivot in stale {
            let groupID = pivot.$group.id
            if adminGroupIDs.contains(groupID) {
                let adminCount = try await UserGroup.query(on: db)
                    .filter(\.$group.$id == groupID)
                    .count()
                if adminCount <= 1 { continue }  // never demote the last admin
            }
            try await pivot.delete(on: db)
        }
    }

    /// Returns the managed group with `name`, creating it if absent and tagging it with the SSO
    /// `source` (provider id). Returns `nil` if a *manual* group already owns that name, so import
    /// never hijacks an admin/tier group.
    private func findOrCreateManagedGroup(named name: String, source: String) async throws -> Group?
    {
        if let existing = try await Group.query(on: db).filter(\.$name == name).first() {
            return existing.source != "manual" ? existing : nil
        }
        let group = Group(name: name, source: source)
        do {
            try await group.create(on: db)
            return group
        } catch {
            // Likely a concurrent create hit the unique(name) constraint - re-read.
            guard let existing = try await Group.query(on: db).filter(\.$name == name).first()
            else { throw error }
            return existing.source != "manual" ? existing : nil
        }
    }

    private func withRelations(_ user: User) async throws -> User {
        try await user.$groups.load(on: db)
        try await user.$tier.load(on: db)
        return user
    }
}
