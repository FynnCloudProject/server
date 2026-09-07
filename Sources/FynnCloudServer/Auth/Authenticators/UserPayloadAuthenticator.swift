import Crypto
import Fluent
import JWT
import Redis
import Vapor

/// Compares two secrets in constant time (digest equality in swift-crypto is constant-time),
/// so a mismatch can't be located byte-by-byte via response timing.
private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    SHA256.hash(data: Data(lhs.utf8)) == SHA256.hash(data: Data(rhs.utf8))
}

struct UserPayloadAuthenticator: AsyncRequestAuthenticator {
    func authenticate(request: Request) async throws {
        let token =
            request.headers.bearerAuthorization?.token
            ?? request.cookies["accessToken"]?.string
            ?? request.query[String.self, at: "accessToken"]

        if let token = token {
            do {
                // Verify the JWT signature and expiration
                let payload = try await request.jwt.verify(token, as: UserPayload.self)

                // Verify the session still exists. A Redis cache hit skips the Postgres round trip on
                // this hot path; a miss (including any Redis error) always falls back to the real
                // check, so a cache failure can never make a revoked grant look valid.
                if await GrantValidityCache.cachedValid(grantID: payload.grantID, on: request.redis) == nil {
                    guard try await OAuthGrant.find(payload.grantID, on: request.db) != nil else {
                        request.logger(subsystem: .auth).warning("Token valid, but Grant \(payload.grantID) was revoked")
                        return
                    }
                    GrantValidityCache.markValid(grantID: payload.grantID, on: request.redis)
                }
                request.auth.login(payload)

                // Record active session activity (grantID, timestamp & IP) in Redis
                SessionActivityService.record(grantID: payload.grantID, on: request)

                request.logger(subsystem: .auth).debug(
                    "User authenticated successfully via Grant",
                    metadata: [
                        "userID": .string(payload.subject.value),
                        "grantID": .string(payload.grantID.uuidString),
                    ]
                )
                return
            } catch {
                request.logger(subsystem: .auth).debug("Token verification failed", metadata: ["error": .string("\(error)")])
            }
        }

        // Fallback: Trusted Header Authentication (Reverse Proxy Auth)
        let trustedConfig = request.ssoConfig.trustedHeader
        guard trustedConfig.enabled,
            let emailHeaderName = trustedConfig.emailHeader,
            let email = request.headers.first(name: emailHeaderName)?.trimmingCharacters(
                in: .whitespacesAndNewlines),
            !email.isEmpty
        else {
            return
        }

        // Security check: a shared proxy secret is mandatory. Without it, anyone who can reach
        // this port - not just the reverse proxy - could impersonate any user by sending the header.
        guard let secret = trustedConfig.secret, !secret.isEmpty else {
            request.logger(subsystem: .auth).error(
                "Trusted header authentication is enabled but TRUSTED_HEADER_SECRET is not set; refusing to authenticate")
            return
        }
        let proxySecret =
            request.headers.first(name: "X-Auth-Secret")
            ?? request.headers.first(name: "X-Proxy-Secret")
        guard let proxySecret, constantTimeEquals(proxySecret, secret) else {
            request.logger(subsystem: .auth).warning(
                "Trusted header authentication rejected: missing or invalid proxy secret")
            return
        }

        let displayName: String? = {
            guard let nameHeader = trustedConfig.nameHeader,
                let val = request.headers.first(name: nameHeader)?.trimmingCharacters(
                    in: .whitespacesAndNewlines),
                !val.isEmpty
            else {
                return nil
            }
            return val
        }()

        let groups: [String] = {
            guard let groupsHeader = trustedConfig.groupsHeader,
                let raw = request.headers.first(name: groupsHeader)
            else {
                return []
            }
            return raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }()

        let rawRole: String? = {
            guard let roleHeader = trustedConfig.roleHeader,
                let val = request.headers.first(name: roleHeader)?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).lowercased(),
                !val.isEmpty
            else {
                return nil
            }
            return val
        }()

        do {
            let identity = ExternalIdentity(
                provider: "trusted_header",
                subject: email.lowercased(),
                username: displayName ?? String(email.prefix(while: { $0 != "@" })),
                email: email.lowercased(),
                emailVerified: true,
                displayName: displayName,
                groups: groups
            )

            let user = try await request.ssoService.resolveUser(identity)
            let userID = try user.requireID()

            // Reconcile role if role header is present
            if let rawRole = rawRole {
                if rawRole == "admin" && !user.isAdmin {
                    if let adminGroup = try await Group.query(on: request.db)
                        .filter(\.$isAdmin == true)
                        .first(),
                        let adminGroupID = adminGroup.id
                    {
                        let hasPivot =
                            try await UserGroup.query(on: request.db)
                            .filter(\.$user.$id == userID)
                            .filter(\.$group.$id == adminGroupID)
                            .first() != nil
                        if !hasPivot {
                            try await UserGroup(
                                userID: userID, groupID: adminGroupID, source: "trusted_header"
                            ).create(on: request.db)
                            try await user.$groups.load(on: request.db)
                            request.logger(subsystem: .auth).info(
                                "SSO trusted header: elevated user \(user.username) to admin via group \(adminGroup.name)"
                            )
                        }
                    }
                } else if rawRole == "user" && user.isAdmin {
                    // Detach trusted_header admin groups
                    let adminPivots = try await UserGroup.query(on: request.db)
                        .filter(\.$user.$id == userID)
                        .filter(\.$source == "trusted_header")
                        .with(\.$group)
                        .all()
                        .filter { $0.group.isAdmin }

                    if !adminPivots.isEmpty {
                        let totalAdmins = try await UserGroup.query(on: request.db)
                            .join(Group.self, on: \UserGroup.$group.$id == \Group.$id)
                            .filter(Group.self, \.$isAdmin == true)
                            .count()
                        if totalAdmins > 1 {
                            for pivot in adminPivots {
                                try await pivot.delete(on: request.db)
                            }
                            try await user.$groups.load(on: request.db)
                            request.logger(subsystem: .auth).info(
                                "SSO trusted header: demoted user \(user.username) to standard user"
                            )
                        } else {
                            request.logger(subsystem: .auth).warning(
                                "SSO trusted header: prevented demoting last remaining admin \(user.username)"
                            )
                        }
                    }
                }
            }

            let payload = UserPayload(
                subject: .init(value: userID.uuidString),
                expiration: .init(value: Date().addingTimeInterval(3600)),
                grantID: UUID(),
                jti: .init(value: UUID().uuidString)
            )

            request.auth.login(payload)

            request.logger(subsystem: .auth).debug(
                "User authenticated successfully via Trusted Header",
                metadata: [
                    "userID": .string(userID.uuidString),
                    "email": .string(email),
                ]
            )
        } catch {
            request.logger(subsystem: .auth).error("Failed to authenticate user from trusted headers: \(error)")
        }
    }
}
