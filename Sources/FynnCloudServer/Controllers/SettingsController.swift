import Foundation
import Vapor

/// Controller for application settings and branding assets.
/// Presentation boundary handles group filtering, public vs admin scoping, and secret redaction.
struct SettingsController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api")

        // Public branding asset streams
        api.get("branding", "logo", use: getLogo)
        api.get("branding", "icon", use: getIcon)

        // Public settings endpoints (unauthenticated; returns only visibility == .public)
        api.get("settings", "public", use: getPublicSettings)
        api.get("public", "settings", use: getPublicSettings)

        // Admin settings endpoints (requires authenticated administrator)
        let adminAuth = api.grouped(
            UserPayloadAuthenticator(), UserPayload.guardMiddleware(), AdminMiddleware())
        adminAuth.get("settings", use: getAdminSettings)
        adminAuth.put("settings", use: updateSettings)
        adminAuth.post("settings", "branding", "logo", use: uploadLogo)
        adminAuth.delete("settings", "branding", "logo", use: deleteLogo)
        adminAuth.post("settings", "branding", "icon", use: uploadIcon)
        adminAuth.delete("settings", "branding", "icon", use: deleteIcon)

        // Also alias under /api/admin/settings for RESTful scoping
        let adminPrefixed = api.grouped("admin").grouped(
            UserPayloadAuthenticator(), UserPayload.guardMiddleware(), AdminMiddleware())
        adminPrefixed.get("settings", use: getAdminSettings)
        adminPrefixed.put("settings", use: updateSettings)
    }

    // MARK: - Presentation Layer Projections

    private func projectToDTO(keyType: any AnySettingKey.Type, rawManaged: ManagedSetting<String>) -> SettingDTO {
        let isConfigured: Bool
        if rawManaged.isManagedByEnv {
            isConfigured = true
        } else {
            isConfigured = !rawManaged.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        let exposedValue: String?
        if keyType.visibility == .secret {
            exposedValue = nil // Masked/redacted in read APIs
        } else {
            exposedValue = rawManaged.value
        }

        return SettingDTO(
            key: keyType.key,
            value: exposedValue,
            isManagedByEnv: rawManaged.isManagedByEnv,
            isConfigured: isConfigured,
            visibility: keyType.visibility,
            group: keyType.group,
            envVar: keyType.envKeys.first,
            envKeys: keyType.envKeys
        )
    }

    private func filterCandidates(
        from base: [any AnySettingKey.Type],
        req: Request
    ) throws -> (candidates: [any AnySettingKey.Type], requestedKeys: Set<String>?) {
        var candidates = base

        let groupParam = req.query[String.self, at: "group"] ?? req.query[String.self, at: "groups"]
        if let groupParam = groupParam, !groupParam.trimmingCharacters(in: .whitespaces).isEmpty {
            let groupNames = groupParam.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var groups = Set<SettingGroup>()
            for name in groupNames {
                guard let group = SettingGroup(rawValue: name) else {
                    throw Abort(.badRequest, reason: "Invalid setting group: \(name)")
                }
                groups.insert(group)
            }
            candidates = candidates.filter { groups.contains($0.group) }
        }

        var requestedKeys: Set<String>? = nil
        if let keysParam = req.query[String.self, at: "keys"],
            !keysParam.trimmingCharacters(in: .whitespaces).isEmpty
        {
            let rawSet = Set(keysParam.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            requestedKeys = rawSet
            let mappedKeys = Set(rawSet.map { AppSettings.legacyKeyAliases[$0] ?? $0 })
            candidates = candidates.filter { mappedKeys.contains($0.key) }
        }

        return (candidates, requestedKeys)
    }

    private func projectCandidates(
        _ candidates: [any AnySettingKey.Type],
        requestedKeys: Set<String>? = nil,
        settings: SettingsService
    ) async throws -> SettingsResponse {
        guard !candidates.isEmpty else { return SettingsResponse() }

        let resolved = try await settings.resolveKeys(candidates)
        var result = SettingsResponse()
        result.reserveCapacity(candidates.count + (requestedKeys?.count ?? 0))

        for keyType in candidates {
            guard let rawManaged = resolved[keyType.key] else { continue }
            let dto = projectToDTO(keyType: keyType, rawManaged: rawManaged)
            result[keyType.key] = dto

            for (legacyAlias, canonical) in AppSettings.legacyKeyAliases
            where canonical == keyType.key && (requestedKeys?.contains(legacyAlias) ?? true) {
                result[legacyAlias] = SettingDTO(
                    key: legacyAlias,
                    value: dto.value,
                    isManagedByEnv: dto.isManagedByEnv,
                    isConfigured: dto.isConfigured,
                    visibility: dto.visibility,
                    group: dto.group,
                    envVar: dto.envVar,
                    envKeys: dto.envKeys
                )
            }
        }

        return result
    }

    private func resolveAndProjectAll(settings: SettingsService) async throws -> SettingsResponse {
        try await projectCandidates(AppSettings.all, settings: settings)
    }

    // MARK: - Setting Endpoints

    /// GET /api/settings/public - Unauthenticated public endpoint returning only `.public` settings.
    /// Supports optional `?group=` and `?keys=` filtering.
    func getPublicSettings(req: Request) async throws -> SettingsResponse {
        let (candidates, requestedKeys) = try filterCandidates(
            from: AppSettings.all.filter { $0.visibility == .public },
            req: req
        )
        return try await projectCandidates(candidates, requestedKeys: requestedKeys, settings: req.settings)
    }

    /// GET /api/admin/settings (or GET /api/settings) - Admin endpoint returning settings with secret redaction.
    /// Supports `?group=sso` for coarse backend query partition, and `?keys=keyA,keyB` for dashboard views.
    func getAdminSettings(req: Request) async throws -> SettingsResponse {
        let (candidates, requestedKeys) = try filterCandidates(
            from: AppSettings.all,
            req: req
        )
        return try await projectCandidates(candidates, requestedKeys: requestedKeys, settings: req.settings)
    }

    /// PUT /api/admin/settings (or PUT /api/settings) - Admin mutation endpoint.
    /// Preserves existing values if a client submits an empty or null string for a `.secret`.
    func updateSettings(req: Request) async throws -> SettingsResponse {
        let input = try req.content.decode([String: String?].self)
        let settings = req.settings

        var touchedSSO = false
        var touchedDocumentServerURL: (previous: String?, new: String)? = nil
        var modifiedKeyTypes: [any AnySettingKey.Type] = []

        for (key, rawValOpt) in input {
            guard let keyType = AppSettings.find(key) else { continue }
            let val = rawValOpt ?? ""

            // Safe secret update: empty or whitespace string does not overwrite existing secret
            if keyType.visibility == .secret && val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                modifiedKeyTypes.append(keyType)
                continue
            }

            if keyType.key == AppSettings.DocsServerUrl.key {
                let previous = try? await settings.get(AppSettings.DocsServerUrl.self)
                touchedDocumentServerURL = (previous: previous, new: val)
            }

            try await settings.setGuardedAny(keyType, value: val)
            modifiedKeyTypes.append(keyType)
            if keyType.group == .sso { touchedSSO = true }
        }

        // Invalidate WOPI discovery cache if document server URL changed
        if let (previousURL, newURL) = touchedDocumentServerURL {
            await WopiService.invalidateDiscoveryCache(
                redis: req.redis,
                previousBaseURL: previousURL,
                newBaseURL: newURL,
                logger: req.logger
            )
        }

        // Rebuild the provider registry so SSO edits take effect without a restart.
        if touchedSSO {
            await reloadSSOProviders(req.application)
        }

        let adminID = try? req.auth.require(UserPayload.self).getID()
        req.logger(subsystem: .admin).info(
            "Admin updated cluster settings",
            metadata: [
                "admin_user_id": .stringConvertible(adminID ?? UUID()),
                "modified_keys": .array(modifiedKeyTypes.map { .string($0.key) }),
            ]
        )

        // Return projected DTOs for modified keys (mirroring getSettings)
        return try await projectCandidates(
            modifiedKeyTypes,
            requestedKeys: Set(input.keys),
            settings: settings
        )
    }

    // MARK: - Branding Operations

    func getLogo(req: Request) async throws -> Response {
        let settings = req.settings
        let updatedAt = try await settings.get(AppSettings.CustomLogoUpdatedAt.self)
        guard !updatedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.notFound, reason: "No custom logo configured")
        }

        let mimeTypeStr = try await settings.get(AppSettings.CustomLogoMimeType.self)
        let effectiveMime = mimeTypeStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "image/png" : mimeTypeStr
        let storage = req.storageService
        guard (try? await storage.brandingAssetExists(.logo)) == true else {
            throw Abort(.notFound, reason: "Custom logo file not found")
        }
        let response = try await storage.brandingAssetResponse(.logo)
        response.apply(.versionedImmutable, contentType: effectiveMime)
        return response
    }

    func getIcon(req: Request) async throws -> Response {
        let settings = req.settings
        let updatedAt = try await settings.get(AppSettings.CustomIconUpdatedAt.self)
        guard !updatedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.notFound, reason: "No custom icon configured")
        }

        let mimeTypeStr = try await settings.get(AppSettings.CustomIconMimeType.self)
        let effectiveMime = mimeTypeStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "image/png" : mimeTypeStr
        let storage = req.storageService
        guard (try? await storage.brandingAssetExists(.icon)) == true else {
            throw Abort(.notFound, reason: "Custom icon file not found")
        }
        let response = try await storage.brandingAssetResponse(.icon)
        response.apply(.versionedImmutable, contentType: effectiveMime)
        return response
    }

    func uploadLogo(req: Request) async throws -> SettingsResponse {
        let body = try req.content.decode(UploadBrandingLogoRequest.self)
        let file = body.logo

        guard file.data.readableBytes <= 5 * 1024 * 1024 else {
            throw Abort(.payloadTooLarge, reason: "Logo image must be smaller than 5 MB")
        }

        let rawContentType = file.contentType?.description.lowercased() ?? ""
        let isSVG = rawContentType.contains("svg") || file.filename.lowercased().hasSuffix(".svg")
        let isPNG = rawContentType.contains("png")
        let isJPEG = rawContentType.contains("jpeg") || rawContentType.contains("jpg")
        let isWebP = rawContentType.contains("webp")

        guard isSVG || isPNG || isJPEG || isWebP else {
            throw Abort(.badRequest, reason: "Logo must be an image (SVG, PNG, JPEG, WebP)")
        }

        let processedBuffer: ByteBuffer
        let mimeType: String
        if isSVG {
            processedBuffer = try SVGProcessor.sanitize(buffer: file.data)
            mimeType = "image/svg+xml"
        } else {
            processedBuffer = file.data
            mimeType = isPNG ? "image/png" : (isWebP ? "image/webp" : "image/jpeg")
        }

        let storage = req.storageService
        try await storage.storeBrandingAsset(
            .logo,
            buffer: processedBuffer,
            contentType: mimeType
        )

        let timestamp = String(Int(Date().timeIntervalSince1970))
        let settings = req.settings
        try await settings.setGuarded(AppSettings.CustomLogoUpdatedAt.self, value: timestamp)
        try await settings.setGuarded(AppSettings.CustomLogoMimeType.self, value: mimeType)

        return try await resolveAndProjectAll(settings: settings)
    }

    func deleteLogo(req: Request) async throws -> SettingsResponse {
        let storage = req.storageService
        do {
            try await storage.deleteBrandingAsset(.logo)
        } catch {
            req.logger(subsystem: .storage).warning("Failed to delete branding logo file: \(error)")
        }

        let settings = req.settings
        try await settings.setGuarded(AppSettings.CustomLogoUpdatedAt.self, value: "")
        try await settings.setGuarded(AppSettings.CustomLogoMimeType.self, value: "")

        return try await resolveAndProjectAll(settings: settings)
    }

    func uploadIcon(req: Request) async throws -> SettingsResponse {
        let body = try req.content.decode(UploadBrandingIconRequest.self)
        let file = body.icon

        guard file.data.readableBytes <= 5 * 1024 * 1024 else {
            throw Abort(.payloadTooLarge, reason: "Icon image must be smaller than 5 MB")
        }

        let rawContentType = file.contentType?.description.lowercased() ?? ""
        let isSVG = rawContentType.contains("svg") || file.filename.lowercased().hasSuffix(".svg")
        let isPNG = rawContentType.contains("png")
        let isJPEG = rawContentType.contains("jpeg") || rawContentType.contains("jpg")
        let isWebP = rawContentType.contains("webp")

        guard isSVG || isPNG || isJPEG || isWebP else {
            throw Abort(.badRequest, reason: "Icon must be an image (SVG, PNG, JPEG, WebP)")
        }

        let processedBuffer: ByteBuffer
        let mimeType: String
        if isSVG {
            processedBuffer = try SVGProcessor.sanitize(buffer: file.data)
            mimeType = "image/svg+xml"
        } else {
            processedBuffer = file.data
            mimeType = isPNG ? "image/png" : (isWebP ? "image/webp" : "image/jpeg")
        }

        let storage = req.storageService
        try await storage.storeBrandingAsset(
            .icon,
            buffer: processedBuffer,
            contentType: mimeType
        )

        let timestamp = String(Int(Date().timeIntervalSince1970))
        let settings = req.settings
        try await settings.setGuarded(AppSettings.CustomIconUpdatedAt.self, value: timestamp)
        try await settings.setGuarded(AppSettings.CustomIconMimeType.self, value: mimeType)

        return try await resolveAndProjectAll(settings: settings)
    }

    func deleteIcon(req: Request) async throws -> SettingsResponse {
        let storage = req.storageService
        do {
            try await storage.deleteBrandingAsset(.icon)
        } catch {
            req.logger(subsystem: .storage).warning("Failed to delete branding icon file: \(error)")
        }

        let settings = req.settings
        try await settings.setGuarded(AppSettings.CustomIconUpdatedAt.self, value: "")
        try await settings.setGuarded(AppSettings.CustomIconMimeType.self, value: "")

        return try await resolveAndProjectAll(settings: settings)
    }
}
