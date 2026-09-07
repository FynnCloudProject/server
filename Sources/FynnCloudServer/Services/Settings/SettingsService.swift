import Foundation
import Fluent
import Redis
import Vapor

/// Central actor for fetching, updating, resolving, and invalidating dynamic application settings.
actor SettingsService {
    private var cache: [String: String]?
    private var cacheLoadedAt: Date?
    private var inFlightLoad: Task<[String: String], any Error>?
    /// Bumped on every mutation/invalidation. A load that completes across a bump is discarded,
    /// since its snapshot predates the change.
    private var generation: UInt64 = 0
    private let ttl: TimeInterval
    private let database: any Database
    private let redis: any RedisClient
    private let logger: Logger
    private let invalidator = SettingsCacheInvalidator()
    private var onRemoteInvalidation: (@Sendable () async -> Void)?

    init(
        database: any Database,
        redis: any RedisClient,
        ttl: TimeInterval = 300.0,
        logger: Logger = Logger(label: "settings")
    ) {
        self.database = database
        self.redis = redis
        self.ttl = ttl
        self.logger = logger
    }

    // MARK: - Cache Management

    /// Clears the local in-memory setting cache.
    func clearCache() {
        cache = nil
        cacheLoadedAt = nil
        inFlightLoad = nil
        generation &+= 1
    }

    private var isCacheValid: Bool {
        guard cache != nil, let cacheLoadedAt else { return false }
        return Date().timeIntervalSince(cacheLoadedAt) < ttl
    }

    private func loadIfNeeded() async throws {
        if isCacheValid { return }

        // If a load task is already in-flight, await its completion to avoid duplicate queries.
        if let existingTask = inFlightLoad {
            let startGeneration = generation
            let loaded = try await existingTask.value
            install(loaded, ifStillAt: startGeneration)
            return
        }

        let db = self.database
        let loadTask = Task<[String: String], any Error> {
            let rows = try await AppSetting.query(on: db).all()
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let key = row.id else { return nil }
                return (key, row.value)
            })
        }

        self.inFlightLoad = loadTask
        let startGeneration = generation

        do {
            let result = try await loadTask.value
            install(result, ifStillAt: startGeneration)
            self.inFlightLoad = nil
        } catch {
            self.inFlightLoad = nil
            throw error
        }
    }

    /// Installs a freshly loaded snapshot unless a write or invalidation landed while it was
    /// in flight - actor reentrancy means the snapshot would otherwise silently revert that change.
    private func install(_ snapshot: [String: String], ifStillAt startGeneration: UInt64) {
        guard generation == startGeneration else { return }
        cache = snapshot
        cacheLoadedAt = Date()
    }

    // MARK: - Database Persistence (Internal)

    private func getRaw(key: String) async throws -> String? {
        try await loadIfNeeded()
        return cache?[key]
    }

    private func setRaw(key: String, value: String) async throws {
        try await loadIfNeeded()

        let record = try await AppSetting.find(key, on: database) ?? AppSetting(key: key, value: value)
        record.value = value
        try await record.save(on: database)

        // Patch in place but leave `cacheLoadedAt` alone: the TTL is the backstop for missed
        // pub/sub invalidations, so writes must not keep pushing the next full reload away.
        cache?[key] = value
        generation &+= 1
        try await publishInvalidation()
    }

    private func deleteRaw(key: String) async throws {
        try await loadIfNeeded()

        if let existing = try await AppSetting.find(key, on: database) {
            try await existing.delete(on: database)
        }

        cache?[key] = nil
        generation &+= 1
        try await publishInvalidation()
    }

    // MARK: - Setting Resolution & Access

    /// Resolves a dynamic setting by type descriptor, returning a `ManagedSetting<String>` wrapper.
    func resolveAny(_ keyType: any AnySettingKey.Type) async throws -> ManagedSetting<String> {
        if let envVal = keyType.envValue {
            return ManagedSetting(value: envVal, isManagedByEnv: true)
        }
        if let dbStr = try await getRaw(key: keyType.key) {
            return ManagedSetting(value: dbStr, isManagedByEnv: false)
        }
        return ManagedSetting(value: keyType.defaultValueString, isManagedByEnv: false)
    }

    /// Resolves a setting with ENV precedence > DB > Default, returning a `ManagedSetting<K.Value>` wrapper.
    func resolve<K: SettingKey>(_ keyType: K.Type) async throws -> ManagedSetting<K.Value> {
        let raw = try await resolveAny(keyType)
        let typedValue = K.Value(raw.value) ?? K.defaultValue
        return ManagedSetting(value: typedValue, isManagedByEnv: raw.isManagedByEnv)
    }

    /// Returns the effective strongly-typed value of a setting (ENV > DB > Default).
    func get<K: SettingKey>(_ keyType: K.Type) async throws -> K.Value {
        try await resolve(keyType).value
    }

    /// Resolves all registered settings as a dictionary `[key: ManagedSetting<String>]`.
    func resolveAll() async throws -> [String: ManagedSetting<String>] {
        var result: [String: ManagedSetting<String>] = [:]
        for keyType in AppSettings.all {
            result[keyType.key] = try await resolveAny(keyType)
        }
        return result
    }

    // MARK: - Guarded Mutations

    /// Updates a dynamic setting by raw key and string value, throwing HTTP 409 Conflict if managed by an environment variable.
    func setGuardedAny(_ keyType: any AnySettingKey.Type, value rawValue: String) async throws {
        let value = try keyType.validate(rawValue)

        if let envValue = keyType.envValue {
            if envValue == value {
                return
            }
            throw Abort(
                .conflict,
                reason: "Setting '\(keyType.key)' is managed by an environment variable and cannot be changed via the web interface."
            )
        }

        try await setRaw(key: keyType.key, value: value)
    }

    /// Updates a setting in the database, throwing HTTP 409 Conflict if managed by an environment variable.
    func setGuarded<K: SettingKey>(_ keyType: K.Type, value: K.Value) async throws {
        try await setGuardedAny(keyType, value: String(describing: value))
    }

    // MARK: - Cross-replica Cache Invalidation

    /// Handles cache invalidation messages originating from remote cluster replicas.
    func handleRemoteInvalidation(originID: String) async {
        guard invalidator.shouldInvalidate(originID: originID) else { return }
        clearCache()
        await onRemoteInvalidation?()
    }

    /// Starts listening for cache invalidation messages from other server replicas via Redis Pub/Sub.
    /// `onRemoteInvalidation` rebuilds config derived from settings (e.g. the SSO provider registry),
    /// which clearing the raw cache alone would leave stale on the other replicas.
    func startListening(
        redis: any RedisClient,
        onRemoteInvalidation: (@Sendable () async -> Void)? = nil
    ) async {
        self.onRemoteInvalidation = onRemoteInvalidation
        do {
            try await redis.subscribe(
                to: SettingsCacheInvalidator.invalidationChannel,
                messageReceiver: { [weak self] _, message in
                    guard let self, let originID = message.string else { return }
                    Task {
                        await self.handleRemoteInvalidation(originID: originID)
                    }
                }
            ).get()
        } catch {
            logger.scoped(to: .system).error(
                "SettingsService failed to subscribe to invalidations",
                metadata: ["error": .string("\(error)")]
            )
        }
    }

    private func publishInvalidation() async throws {
        do {
            _ = try await redis.publish(
                invalidator.instanceID, to: SettingsCacheInvalidator.invalidationChannel).get()
        } catch {
            // Best-effort: the per-replica TTL is the backstop for a lost invalidation.
            logger.scoped(to: .system).warning(
                "Failed to publish settings invalidation",
                metadata: ["error": .string("\(error)")])
        }
    }
}

// MARK: - Vapor Application Extension

extension Application {
    private struct SettingsServiceKey: StorageKey {
        typealias Value = SettingsService
    }

    var optionalSettings: SettingsService? {
        self.storage[SettingsServiceKey.self]
    }

    var settings: SettingsService {
        get {
            guard let service = self.storage[SettingsServiceKey.self] else {
                fatalError("SettingsService not configured. Call app.settings = ... in configure.swift")
            }
            return service
        }
        set {
            self.storage[SettingsServiceKey.self] = newValue
        }
    }
}
