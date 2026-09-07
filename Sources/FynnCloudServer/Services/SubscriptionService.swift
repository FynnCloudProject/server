import Fluent
import JWT
import Redis
import Vapor

enum SubscriptionError: AbortError, LocalizedError {
    case noActiveSubscription
    case expired

    var status: HTTPResponseStatus { .forbidden }

    var reason: String {
        switch self {
        case .noActiveSubscription:
            return "No active subscription found."
        case .expired:
            return "The subscription key has expired."
        }
    }

    var errorDescription: String? { self.reason }
}

actor SubscriptionService {
    /// Default maximum user limit when no subscription key is configured.
    static let defaultMaxUsers = 10

    /// 7-day grace period for expired subscriptions.
    private static let subscriptionLeeway: TimeInterval = 7 * 24 * 60 * 60

    /// Redis Pub/Sub channel for subscription updates across FynnCloud replicas.
    private static var invalidationChannel: RedisChannelName { "subscription:invalidate" }

    /// Unique identifier for this process instance to ignore its own broadcasts.
    private let instanceID = UUID().uuidString

    private let envSubscriptionKey: String?
    private let keys: JWTKeyCollection
    private let database: any Database

    private var activeSubscription: SubscriptionKey?
    private var activeToken: String?
    private var isLoaded = false
    private var loadedFromEnv = false

    init(envSubscriptionKey: String?, keys: JWTKeyCollection, database: any Database) {
        self.envSubscriptionKey = envSubscriptionKey
        self.keys = keys
        self.database = database
    }

    // MARK: - Cache Loading

    /// Ensures the subscription token is loaded and verified in memory.
    private func loadIfNeeded() async throws {
        guard !isLoaded else { return }

        // 1. Check environment variable token first (highest priority)
        if let envToken = envSubscriptionKey {
            self.activeSubscription = try await keys.verify(envToken, as: SubscriptionKey.self)
            self.activeToken = envToken
            self.loadedFromEnv = true
        }
        else if let record = try await SubscriptionRecord.query(on: self.database).first() {
            self.activeSubscription = try await keys.verify(record.token, as: SubscriptionKey.self)
            self.activeToken = record.token
        }

        self.isLoaded = true
    }

    // MARK: - Public Subscription State API

    /// Gets the active subscription payload, verifying it hasn't expired.
    func get() async throws -> SubscriptionKey {
        try await loadIfNeeded()

        guard let subscription = activeSubscription else {
            throw SubscriptionError.noActiveSubscription
        }

        let gracePeriodEnd = subscription.expiration.value.addingTimeInterval(Self.subscriptionLeeway)
        guard Date() <= gracePeriodEnd else {
            throw SubscriptionError.expired
        }

        return subscription
    }

    /// Returns `true` if an active, non-expired subscription key is currently configured.
    func hasSubscription() async -> Bool {
        return (try? await get()) != nil
    }

    /// Returns the effective maximum user limit:
    /// - Returns `subscription.maxUsers` if a valid subscription key is active (`nil` means unlimited).
    /// - Returns `Self.defaultMaxUsers` (`10`) if no active subscription key is configured.
    func effectiveMaxUsers() async -> Int? {
        if let subscription = try? await get() {
            return subscription.maxUsers
        }
        return Self.defaultMaxUsers
    }

    /// Returns detailed metadata about the active subscription for admin responses.
    func info() async throws
        -> (payload: SubscriptionKey, token: String, managedByEnvironment: Bool)?
    {
        try await loadIfNeeded()
        guard let payload = activeSubscription, let token = activeToken else {
            return nil
        }
        return (payload, token, loadedFromEnv)
    }

    /// Checks if the subscription key is hardcoded via environment variable.
    func isManagedByEnvironment() -> Bool {
        return envSubscriptionKey != nil
    }

    // MARK: - Updates & Persistence

    /// Cryptographically verifies and saves a new subscription key.
    func update(token: String, redis: any RedisClient) async throws {
        try await loadIfNeeded()

        guard envSubscriptionKey == nil else {
            throw Abort(
                .conflict,
                reason:
                    "The subscription key is managed by an environment variable and cannot be changed via the web interface."
            )
        }

        let validSubscription = try await keys.verify(token, as: SubscriptionKey.self)

        if let existing = try await SubscriptionRecord.query(on: self.database).first() {
            existing.token = token
            try await existing.save(on: self.database)
        } else {
            try await SubscriptionRecord(token: token).create(on: self.database)
        }

        self.activeSubscription = validSubscription
        self.activeToken = token

        _ = try await redis.publish(instanceID, to: Self.invalidationChannel).get()
    }

    // MARK: - Distributed Cache Invalidation

    /// Subscribes to Redis Pub/Sub invalidation channel across server nodes.
    func startListening(redis: any RedisClient, logger: Logger) async {
        do {
            try await redis.subscribe(
                to: Self.invalidationChannel,
                messageReceiver: { [weak self] _, message in
                    guard let self, let originID = message.string else { return }
                    Task { await self.handleInvalidation(from: originID) }
                }
            ).get()
        } catch {
            logger.scoped(to: .system).error(
                "SubscriptionService failed to subscribe to Redis invalidations",
                metadata: ["error": .string("\(error)")]
            )
        }
    }

    private func handleInvalidation(from originID: String) {
        guard originID != instanceID else { return }

        self.activeSubscription = nil
        self.activeToken = nil
        self.isLoaded = false
    }
}

// MARK: - Vapor Framework Integration

extension Application {
    private struct SubscriptionServiceKey: StorageKey {
        typealias Value = SubscriptionService
    }

    var subscription: SubscriptionService {
        get {
            guard let service = self.storage[SubscriptionServiceKey.self] else {
                fatalError(
                    "SubscriptionService not configured. Call app.subscription = ... in configure.swift"
                )
            }
            return service
        }
        set {
            self.storage[SubscriptionServiceKey.self] = newValue
        }
    }
}

extension Request {
    var subscription: SubscriptionService {
        self.application.subscription
    }
}
