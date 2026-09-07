import Fluent
import Vapor

struct LDAPUserCatalogSyncResult: Content {
    let provider: String
    let discovered: Int
    /// New identity links created (provisioned account or linked to an existing one by email).
    let provisioned: Int
    /// Existing identity links refreshed (profile/groups reconciled).
    let updated: Int
    /// Entries that could not be synced (e.g. missing email, subscription user limit).
    let skipped: Int
}

/// Proactively provisions/links LDAP users into local accounts without waiting for login, mirroring
/// Nextcloud's directory pre-sync. It reuses `SSOService.resolveUser`, so provisioning, email
/// linking, and group reconciliation behave exactly as they do on a real login.
struct LDAPUserCatalogSyncService {
    let app: Application
    let db: any Database
    let logger: Logger

    func run() async throws -> LDAPUserCatalogSyncResult {
        let ssoConfig = app.ssoConfig
        let config = ssoConfig.ldap

        guard config.enabled else {
            throw Abort(.conflict, reason: "LDAP is disabled")
        }

        let identities = try await fetchIdentities(config: config)

        let userService = UserService(db: db, subscriptionService: app.subscription, redis: app.redis)
        let sso = SSOService(
            db: db,
            userService: userService,
            logger: logger,
            groupMap: ssoConfig.groupMap,
            groupImportEnabled: ssoConfig.groupImport,
            groupAutoMatch: ssoConfig.groupAutoMatch,
            groupPrefix: ssoConfig.groupPrefix
        )

        var provisioned = 0
        var updated = 0
        var skipped = 0

        for identity in identities {
            let alreadyLinked =
                try await UserIdentity.query(on: db)
                .filter(\.$provider == identity.provider)
                .filter(\.$subject == identity.subject)
                .first() != nil

            do {
                _ = try await sso.resolveUser(identity)
                if alreadyLinked { updated += 1 } else { provisioned += 1 }
            } catch {
                skipped += 1
                logger.scoped(to: .sso).warning(
                    "LDAP user pre-sync skipped user",
                    metadata: [
                        "username": .string(identity.username),
                        "error": .string("\(error)"),
                    ]
                )
            }
        }

        logger.scoped(to: .sso).info(
            "SSO LDAP user pre-sync completed",
            metadata: [
                "discovered": .stringConvertible(identities.count),
                "provisioned": .stringConvertible(provisioned),
                "updated": .stringConvertible(updated),
                "skipped": .stringConvertible(skipped),
            ]
        )

        return LDAPUserCatalogSyncResult(
            provider: "ldap",
            discovered: identities.count,
            provisioned: provisioned,
            updated: updated,
            skipped: skipped
        )
    }

    private func fetchIdentities(config: LDAPProviderConfig) async throws -> [ExternalIdentity] {
        let eventLoop = app.eventLoopGroup.next()
        return try await app.threadPool.runIfActive(eventLoop: eventLoop) {
            try LDAPIdentityProvider.enumerateIdentities(config: config, providerID: "ldap")
        }.get()
    }
}
