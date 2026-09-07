import Foundation
import JWT
import Vapor

// MARK: - Native EuroOffice (DocsAPI) Service

/// Builds the EuroOffice DocsAPI editor configuration and handles the shared-secret JWT signing /
/// callback verification used by the native (non-WOPI) integration.
struct EuroOfficeService {
    let client: any Client
    let logger: Logger
    /// Shared secret with the document server. Empty means JWT signing/verification is disabled.
    let jwtSecret: String

    // MARK: - Extension mapping

    /// Maps a file extension to the EuroOffice editor family. `nil` = not editable.
    static func documentType(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "docx", "doc", "odt", "txt", "md": return "word"
        case "xlsx", "xls", "ods": return "cell"
        case "pptx", "ppt", "odp": return "slide"
        default: return nil
        }
    }

    /// Co-editing session identity: stable per file + content version, within the EuroOffice charset
    /// (`0-9 a-z A-Z -._=`) and length limit (<= 128). Changes when the stored content changes so a
    /// new session starts after an out-of-band edit.
    static func documentKey(fileID: UUID, version: String) -> String {
        let raw = "\(fileID.uuidString)_\(version)"
        let allowed = Set("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-._=")
        let sanitized = String(raw.map { allowed.contains($0) ? $0 : "_" })
        return String(sanitized.prefix(128))
    }

    // MARK: - JWT

    private func keys() async -> JWTKeyCollection {
        let collection = JWTKeyCollection()
        await collection.add(hmac: HMACKey(from: jwtSecret), digestAlgorithm: .sha256)
        return collection
    }

    /// Signs the config (with `token` absent) and returns the JWT the document server validates.
    func signConfig(_ config: EuroOfficeConfig) async throws -> String {
        var unsigned = config
        unsigned.token = nil
        return try await keys().sign(unsigned)
    }

    /// Verifies the callback JWT the document server embeds when JWT is enabled.
    func verifyCallback(_ token: String) async throws -> OfficeCallbackPayload {
        try await keys().verify(token, as: OfficeCallbackPayload.self)
    }

    // MARK: - Config builder

    /// Builds a fully-signed DocsAPI config for the given file/session.
    func buildConfig(
        fileID: UUID,
        fileName: String,
        ext: String,
        version: String,
        canWrite: Bool,
        userID: UUID,
        userFriendlyName: String,
        userAvatarURL: String?,
        fileToken: String,
        publicBaseURL: String
    ) async throws -> EuroOfficeConfig {
        guard let documentType = Self.documentType(forExtension: ext) else {
            throw Abort(.unsupportedMediaType, reason: "This file type cannot be opened in the editor.")
        }

        let base = publicBaseURL.hasSuffix("/") ? String(publicBaseURL.dropLast()) : publicBaseURL
        let encodedToken = fileToken.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? fileToken

        var config = EuroOfficeConfig(
            document: .init(
                fileType: ext.lowercased(),
                key: Self.documentKey(fileID: fileID, version: version),
                title: fileName,
                url: "\(base)/api/office/download?token=\(encodedToken)",
                permissions: .init(edit: canWrite, download: true, print: true)
            ),
            documentType: documentType,
            editorConfig: .init(
                mode: canWrite ? "edit" : "view",
                lang: "en",
                callbackUrl: "\(base)/api/office/callback?token=\(encodedToken)",
                user: .init(id: userID.uuidString, name: userFriendlyName, image: userAvatarURL),
                // forcesave off: persist only when the session ends (status 2) so the content hash -
                // and therefore the co-editing document `key` - stays stable while users collaborate.
                customization: .init(forcesave: false, close: .init(visible: true)),
                coEditing: .init(mode: "fast", change: canWrite)
            ),
            token: nil
        )

        if !jwtSecret.isEmpty {
            config.token = try await signConfig(config)
        }
        return config
    }
}

// MARK: - Request Convenience

extension Request {
    /// EuroOffice service scoped with the shared JWT secret (resolved from dynamic settings by the caller).
    func euroOfficeService(jwtSecret: String) -> EuroOfficeService {
        EuroOfficeService(client: self.client, logger: self.logger, jwtSecret: jwtSecret)
    }
}

// MARK: - Percent Encoding

extension CharacterSet {
    /// Query-value-safe set: alphanumerics plus unreserved marks (matches WopiService's encoding).
    fileprivate static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
