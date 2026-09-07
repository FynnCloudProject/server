import Fluent
import Vapor

struct LDAPGroupCatalogSyncResult: Content {
    let provider: String
    let discovered: Int
    let created: Int
    let existingManaged: Int
    let skippedManual: Int
}

/// Imports LDAP group *catalog* into local groups without waiting for user login.
/// Membership reconciliation still happens on login.
struct LDAPGroupCatalogSyncService {
    let app: Application
    let db: any Database
    let logger: Logger

    func run() async throws -> LDAPGroupCatalogSyncResult {
        let ssoConfig = app.ssoConfig
        let config = ssoConfig.ldap

        guard config.enabled else {
            throw Abort(.conflict, reason: "LDAP is disabled")
        }

        let discoveredGroups = try await fetchGroupNames(config: config)
        var created = 0
        var existingManaged = 0
        var skippedManual = 0

        for groupName in discoveredGroups {
            let localName = ssoConfig.groupPrefix + groupName

            if let existing = try await Group.query(on: db).filter(\.$name == localName).first() {
                if existing.source == "manual" {
                    skippedManual += 1
                } else {
                    existingManaged += 1
                }
                continue
            }

            let group = Group(name: localName, source: "ldap")
            do {
                try await group.create(on: db)
                created += 1
            } catch {
                // Handle create races deterministically.
                if let existing = try await Group.query(on: db).filter(\.$name == localName).first() {
                    if existing.source == "manual" {
                        skippedManual += 1
                    } else {
                        existingManaged += 1
                    }
                } else {
                    throw error
                }
            }
        }

        logger.scoped(to: .sso).info(
            "SSO LDAP group pre-sync completed",
            metadata: [
                "discovered": .stringConvertible(discoveredGroups.count),
                "created": .stringConvertible(created),
                "existing_managed": .stringConvertible(existingManaged),
                "skipped_manual": .stringConvertible(skippedManual),
            ]
        )

        return LDAPGroupCatalogSyncResult(
            provider: "ldap",
            discovered: discoveredGroups.count,
            created: created,
            existingManaged: existingManaged,
            skippedManual: skippedManual
        )
    }

    private func fetchGroupNames(config: LDAPProviderConfig) async throws -> [String] {
        let eventLoop = app.eventLoopGroup.next()
        return try await app.threadPool.runIfActive(eventLoop: eventLoop) {
            try fetchGroupNamesBlocking(config: config)
        }.get()
    }

    private func fetchGroupNamesBlocking(config: LDAPProviderConfig) throws -> [String] {
        let client = try LDAPClient(config: config)
        defer { client.close() }

        if let bindDN = config.bindDN, let bindPassword = config.bindPassword,
            !bindDN.isEmpty, !bindPassword.isEmpty
        {
            try client.bind(dn: bindDN, password: bindPassword)
        } else {
            try client.bind(dn: nil, password: nil)
        }

        let base = (config.groupBaseDN ?? config.baseDN).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return [] }

        let filter = LDAPClient.discoveryFilter(from: config.groupFilter)
        let entries = try client.search(
            baseDN: base,
            scope: .subtree,
            filter: filter
        )

        let names = Set(
            entries.compactMap { LDAPClient.groupName(fromDN: $0.dn) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        return names.sorted()
    }
}
