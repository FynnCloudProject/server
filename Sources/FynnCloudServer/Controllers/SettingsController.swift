import Foundation
import Vapor

/// Admin CRUD for dynamic application settings and branding assets. Validation and env-guarding live in `SettingsService`.
struct SettingsController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let api = routes.grouped("api")

        api.get("branding", "logo", use: getLogo)
        api.get("branding", "icon", use: getIcon)

        let admin = api.grouped(
            UserPayloadAuthenticator(), UserPayload.guardMiddleware(), AdminMiddleware())
        admin.get("settings", use: getSettings)
        admin.put("settings", use: updateSettings)
        admin.post("settings", "branding", "logo", use: uploadLogo)
        admin.delete("settings", "branding", "logo", use: deleteLogo)
        admin.post("settings", "branding", "icon", use: uploadIcon)
        admin.delete("settings", "branding", "icon", use: deleteIcon)
    }

    /// GET /api/settings?keys=a,b,c - callers that only need a subset (e.g. one admin settings
    /// section) can pass a comma-separated `keys` list instead of always resolving every setting.
    /// Unknown keys are silently ignored; omitting `keys` keeps the original resolve-everything behavior.
    func getSettings(req: Request) async throws -> SettingsResponse {
        let settings = req.application.settings
        guard let keysParam = req.query[String.self, at: "keys"],
            !keysParam.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            return try await settings.resolveAll()
        }

        let requestedKeys = Set(
            keysParam.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        var result = SettingsResponse()
        for keyType in AppSettings.all where requestedKeys.contains(keyType.key) {
            result[keyType.key] = try await settings.resolveAny(keyType)
        }
        return result
    }

    func updateSettings(req: Request) async throws -> SettingsResponse {
        let input = try req.content.decode([String: String].self)
        let settings = req.application.settings

        var touchedSSO = false
        var touchedDocumentServerURL: (previous: String?, new: String)? = nil

        for (key, val) in input {
            guard let keyType = AppSettings.find(key) else { continue }
            if key == AppSettings.DocumentServerURL.key {
                let previous = try? await settings.get(AppSettings.DocumentServerURL.self)
                touchedDocumentServerURL = (previous: previous, new: val)
            }
            try await settings.setGuardedAny(keyType, value: val)
            if AppSettings.ssoKeys.contains(key) { touchedSSO = true }
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
        let modifiedKeys = input.keys.filter { AppSettings.find($0) != nil }
        req.logger(subsystem: .admin).info(
            "Admin updated cluster settings",
            metadata: [
                "admin_user_id": .stringConvertible(adminID ?? UUID()),
                "modified_keys": .array(modifiedKeys.map { .string($0) }),
            ]
        )

        // Mirror getSettings: only resolve the keys that were actually sent, so a section save
        // doesn't pull (and re-cache) every other setting on the client.
        var result = SettingsResponse()
        for key in modifiedKeys {
            guard let keyType = AppSettings.find(key) else { continue }
            result[key] = try await settings.resolveAny(keyType)
        }
        return result
    }

    // MARK: - Branding Operations

    func getLogo(req: Request) async throws -> Response {
        let settings = req.application.settings
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
        let settings = req.application.settings
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
        let settings = req.application.settings
        try await settings.setGuarded(AppSettings.CustomLogoUpdatedAt.self, value: timestamp)
        try await settings.setGuarded(AppSettings.CustomLogoMimeType.self, value: mimeType)

        return try await settings.resolveAll()
    }

    func deleteLogo(req: Request) async throws -> SettingsResponse {
        let storage = req.storageService
        do {
            try await storage.deleteBrandingAsset(.logo)
        } catch {
            req.logger(subsystem: .storage).warning("Failed to delete branding logo file: \(error)")
        }

        let settings = req.application.settings
        try await settings.setGuarded(AppSettings.CustomLogoUpdatedAt.self, value: "")
        try await settings.setGuarded(AppSettings.CustomLogoMimeType.self, value: "")

        return try await settings.resolveAll()
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
        let settings = req.application.settings
        try await settings.setGuarded(AppSettings.CustomIconUpdatedAt.self, value: timestamp)
        try await settings.setGuarded(AppSettings.CustomIconMimeType.self, value: mimeType)

        return try await settings.resolveAll()
    }

    func deleteIcon(req: Request) async throws -> SettingsResponse {
        let storage = req.storageService
        do {
            try await storage.deleteBrandingAsset(.icon)
        } catch {
            req.logger(subsystem: .storage).warning("Failed to delete branding icon file: \(error)")
        }

        let settings = req.application.settings
        try await settings.setGuarded(AppSettings.CustomIconUpdatedAt.self, value: "")
        try await settings.setGuarded(AppSettings.CustomIconMimeType.self, value: "")

        return try await settings.resolveAll()
    }
}
