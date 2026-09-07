import Foundation
import Redis
import Vapor

#if canImport(FoundationXML)
    import FoundationXML
#endif


/// Handles EuroOffice discovery (mapping file extensions to editor URLs) and the Redis-backed
/// WOPI lock store used to prevent concurrent-edit data loss.
struct WopiService {
    let client: any Client
    let redis: any RedisClient
    let logger: Logger

    /// A single `<action>` entry from the EuroOffice `/hosting/discovery` document.
    struct DiscoveryAction: Sendable {
        let app: String
        let name: String
        let ext: String
        let urlsrc: String
    }

    // MARK: - Discovery Cache Invalidation

    /// Clears cached EuroOffice discovery documents when the configured document server URL changes.
    ///
    /// Discovery cache keys are URL-scoped (`wopi:discovery:<base>`), so we evict both old and new
    /// bases to avoid stale mappings when admins switch endpoints or quickly switch back.
    static func invalidateDiscoveryCache(
        redis: any RedisClient,
        previousBaseURL: String?,
        newBaseURL: String?,
        logger: Logger? = nil
    ) async {
        var bases = Set<String>()

        if let previousBaseURL {
            let normalizedPrevious = normalizeDocumentServerBase(previousBaseURL)
            if !normalizedPrevious.isEmpty {
                bases.insert(normalizedPrevious)
            }
        }

        if let newBaseURL {
            let normalizedNew = normalizeDocumentServerBase(newBaseURL)
            if !normalizedNew.isEmpty {
                bases.insert(normalizedNew)
            }
        }

        for base in bases {
            let cacheKey = RedisKey("wopi:discovery:\(base)")
            do {
                _ = try await redis.delete(cacheKey).get()
            } catch {
                logger?.warning("Failed to invalidate WOPI discovery cache for key \(cacheKey): \(error)")
            }
        }
    }

    private static func normalizeDocumentServerBase(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    // MARK: - Discovery

    /// Fetches and caches (Redis, 1h TTL) the EuroOffice discovery document and returns the parsed actions.
    func discoveryActions(euroOfficeBaseURL: String) async throws -> [DiscoveryAction] {
        let base = euroOfficeBaseURL.hasSuffix("/") ? String(euroOfficeBaseURL.dropLast()) : euroOfficeBaseURL
        let cacheKey = RedisKey("wopi:discovery:\(base)")

        let xml: String
        if let cached = try? await redis.get(cacheKey, as: String.self).get() {
            xml = cached
        } else {
            let uri = URI(string: "\(base)/hosting/discovery")
            let response = try await client.get(uri)
            guard response.status == .ok, var body = response.body,
                let fetched = body.readString(length: body.readableBytes)
            else {
                throw Abort(.badGateway, reason: "EuroOffice discovery could not be reached.")
            }
            xml = fetched
            _ = try? await redis.set(cacheKey, to: xml).get()
            _ = try? await redis.expire(cacheKey, after: .seconds(3600)).get()
        }

        return parseDiscovery(xml)
    }

    /// Builds the browser-facing editor URL for the given extension and action, with `WOPISrc` appended.
    /// The returned URL intentionally does NOT contain the access token - the UI submits it via a POST form.
    func editorURL(
        forExtension ext: String,
        preferWrite: Bool,
        euroOfficeBaseURL: String,
        wopiSrc: String
    ) async throws -> String {
        let actions = try await discoveryActions(euroOfficeBaseURL: euroOfficeBaseURL)
        let lowerExt = ext.lowercased()
        let candidates = actions.filter { $0.ext.lowercased() == lowerExt }
        guard !candidates.isEmpty else {
            throw Abort(.unsupportedMediaType, reason: "EuroOffice cannot edit .\(lowerExt) files.")
        }

        let preferredNames = preferWrite ? ["edit", "view", "embedview"] : ["view", "embedview", "edit"]
        let action = preferredNames.lazy.compactMap { name in
            candidates.first { $0.name == name }
        }.first ?? candidates[0]

        // Strip discovery placeholder tokens like <ui=UI_LLCC&> that the host is expected to remove.
        let cleaned = action.urlsrc.replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression)

        let encodedSrc = wopiSrc.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? wopiSrc
        if cleaned.hasSuffix("?") || cleaned.hasSuffix("&") {
            return cleaned + "WOPISrc=\(encodedSrc)"
        }
        let separator = cleaned.contains("?") ? "&" : "?"
        return cleaned + separator + "WOPISrc=\(encodedSrc)"
    }

    private func parseDiscovery(_ xml: String) -> [DiscoveryAction] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let delegate = DiscoveryParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.actions
    }

    // MARK: - Lock Store (Redis)

    private func lockKey(_ fileID: UUID) -> RedisKey { RedisKey("wopi:lock:\(fileID.uuidString)") }

    /// WOPI locks expire after 30 minutes per the protocol; refreshed on activity.
    private static let lockTTLSeconds: Int64 = 1800

    func currentLock(fileID: UUID) async throws -> String? {
        try await redis.get(lockKey(fileID), as: String.self).get()
    }

    func setLock(fileID: UUID, lock: String) async throws {
        _ = try await redis.set(lockKey(fileID), to: lock).get()
        _ = try? await redis.expire(lockKey(fileID), after: .seconds(Self.lockTTLSeconds)).get()
    }

    func refreshLock(fileID: UUID) async throws {
        _ = try? await redis.expire(lockKey(fileID), after: .seconds(Self.lockTTLSeconds)).get()
    }

    func deleteLock(fileID: UUID) async throws {
        _ = try await redis.delete(lockKey(fileID)).get()
    }
}

// MARK: - Discovery XML Parser

private final class DiscoveryParserDelegate: NSObject, XMLParserDelegate {
    var actions: [WopiService.DiscoveryAction] = []
    private var currentApp: String = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        if elementName == "app" {
            currentApp = attributeDict["name"] ?? ""
        } else if elementName == "action" {
            guard let name = attributeDict["name"],
                let ext = attributeDict["ext"],
                let urlsrc = attributeDict["urlsrc"]
            else { return }
            actions.append(
                WopiService.DiscoveryAction(app: currentApp, name: name, ext: ext, urlsrc: urlsrc))
        }
    }
}

// MARK: - Percent Encoding

extension CharacterSet {
    /// Query-value-safe set: alphanumerics plus a few unreserved marks, matching typical WOPISrc encoding.
    fileprivate static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}

// MARK: - Request Convenience

extension Request {
    var wopiService: WopiService {
        WopiService(client: self.client, redis: self.redis, logger: self.logger)
    }
}
