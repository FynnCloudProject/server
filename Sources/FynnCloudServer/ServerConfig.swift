import FluentPostgresDriver
import Vapor

enum ServerConfigError: Error, CustomStringConvertible {
    case missingEncryptionKey
    case missingJWTSecret
    case missingStorageConfiguration(String)

    var description: String {
        switch self {
        case .missingEncryptionKey:
            return "ENCRYPTION_KEY environment variable is required but not set."
        case .missingJWTSecret:
            return
                "JWT_SECRET environment variable is required in release/production mode but not set."
        case .missingStorageConfiguration(let reason):
            return "Invalid storage configuration: \(reason)"
        }
    }
}

struct ServerConfig: Sendable {
    enum DatabaseStrategy: Sendable {
        case postgres(SQLPostgresConfiguration)
        case sqlite(String)
    }

    enum StorageDriver: Sendable {
        case s3(bucket: String, aws: AWSConfig)
        case local(path: String)
    }

    struct AWSConfig: Sendable {
        let accessKey: String
        let secretKey: String
        let region: String
        let endpoint: String
    }

    let database: DatabaseStrategy
    let storage: StorageDriver
    let maxBodySize: ByteCount
    let maxChunkSize: ByteCount
    let jwtSecret: String
    /// Dedicated secret for encrypting data at rest (TOTP seeds). Required at startup and must be
    /// permanent: rotating or losing it makes existing encrypted seeds undecryptable, forcing
    /// affected users to re-enroll 2FA. Kept separate from `jwtSecret` so the two can be managed
    /// independently.
    let encryptionKey: String
    let corsAllowedOrigins: [String]
    let redisURL: String
    let frontendURL: String
    let appVersion: String
    let isJwtSecretDefault: Bool
    let subscriptionKey: String?

    /// Colocated AWS configuration if S3 storage is enabled.
    var aws: AWSConfig? {
        if case .s3(_, let awsConfig) = storage {
            return awsConfig
        }
        return nil
    }

    // MARK: - Dynamic Settings Delegation (Backwards Compatibility)

    var rateLimitEnabled: Bool {
        AppSettings.RateLimitEnabled.envValue.flatMap(Bool.init)
            ?? AppSettings.RateLimitEnabled.defaultValue
    }

    var rateLimitAuth: Int {
        AppSettings.RateLimitAuth.envValue.flatMap(Int.init)
            ?? AppSettings.RateLimitAuth.defaultValue
    }

    var rateLimitShare: Int {
        AppSettings.RateLimitShare.envValue.flatMap(Int.init)
            ?? AppSettings.RateLimitShare.defaultValue
    }

    var rateLimitAPI: Int {
        AppSettings.RateLimitAPI.envValue.flatMap(Int.init) ?? AppSettings.RateLimitAPI.defaultValue
    }
}

extension Environment {
    /// Returns the first non-empty value found among the provided environment keys, or `nil`.
    public static func first(matching keys: [String]) -> String? {
        for key in keys {
            if let val = Environment.get(key)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !val.isEmpty
            {
                return val
            }
        }
        return nil
    }
}

extension ServerConfig {
    static func load(for app: Application) throws -> ServerConfig {
        guard
            let encryptionKey = Environment.first(matching: [
                "SECURITY_ENCRYPTION_KEY", "APP_ENCRYPTION_KEY", "ENCRYPTION_KEY",
            ])
        else {
            app.logger.critical(
                "SECURITY_ENCRYPTION_KEY (or ENCRYPTION_KEY) is not set. It is required to encrypt 2FA secrets at rest and must be a fixed, permanent value. Generate one with `openssl rand -base64 32`."
            )
            throw ServerConfigError.missingEncryptionKey
        }

        let maxChunkSizeStr =
            Environment.first(matching: ["STORAGE_MAX_CHUNK_SIZE", "MAX_CHUNK_SIZE"]) ?? "100mb"
        let maxChunkSize = ByteCount(stringLiteral: maxChunkSizeStr)
        let maxBodySize = ByteCount(
            stringLiteral: Environment.first(matching: [
                "MAX_BODY_SIZE", "SERVER_MAX_BODY_SIZE", "STORAGE_MAX_BODY_SIZE",
            ]) ?? maxChunkSizeStr)

        let frontendURL =
            Environment.first(matching: ["APP_FRONTEND_URL", "SERVER_FRONTEND_URL", "FRONTEND_URL"])
            ?? "https://localhost"

        let dbStrategy: DatabaseStrategy
        if let url = Environment.first(matching: ["DATABASE_URL"]).flatMap(URL.init),
            let pgConfig = try? SQLPostgresConfiguration(url: url)
        {
            dbStrategy = .postgres(pgConfig)
        } else {
            dbStrategy = .sqlite(
                Environment.first(matching: ["DATABASE_SQLITE_PATH", "SQLITE_PATH"]) ?? "db.sqlite")
        }

        let storage: StorageDriver
        if let bucket = Environment.first(matching: ["STORAGE_S3_BUCKET", "S3_BUCKET"]),
            !bucket.isEmpty
        {
            let awsConfig = AWSConfig(
                accessKey: Environment.first(matching: [
                    "STORAGE_AWS_ACCESS_KEY_ID", "AWS_ACCESS_KEY_ID",
                ]) ?? "",
                secretKey: Environment.first(matching: [
                    "STORAGE_AWS_SECRET_ACCESS_KEY", "AWS_SECRET_ACCESS_KEY",
                ]) ?? "",
                region: Environment.first(matching: ["STORAGE_AWS_REGION", "AWS_REGION"])
                    ?? "us-east-1",
                endpoint: Environment.first(matching: [
                    "STORAGE_AWS_ENDPOINT", "AWS_ENDPOINT", "S3_ENDPOINT",
                ]) ?? "https://s3.amazonaws.com"
            )
            storage = .s3(bucket: bucket, aws: awsConfig)
        } else {
            let path =
                Environment.first(matching: ["STORAGE_PATH", "LOCAL_STORAGE_PATH"])
                ?? "\(app.directory.workingDirectory)Storage/"
            storage = .local(path: path)
        }

        let jwtSecretEnv = Environment.first(matching: ["AUTH_JWT_SECRET", "JWT_SECRET"])
        let resolvedJwtSecret: String
        let isJwtSecretDefault: Bool

        if let secret = jwtSecretEnv, !secret.isEmpty {
            resolvedJwtSecret = secret
            isJwtSecretDefault = false
        } else {
            if app.environment == .production || app.environment.isRelease {
                app.logger.critical(
                    "AUTH_JWT_SECRET (or JWT_SECRET) environment variable is required in release/production mode but not set."
                )
                throw ServerConfigError.missingJWTSecret
            }
            app.logger.warning(
                "AUTH_JWT_SECRET (or JWT_SECRET) is not set. Generating an ephemeral secret for this session. Set AUTH_JWT_SECRET in production."
            )
            resolvedJwtSecret = [UInt8].random(count: 32).base64
            isJwtSecretDefault = true
        }

        return ServerConfig(
            database: dbStrategy,
            storage: storage,
            maxBodySize: maxBodySize,
            maxChunkSize: maxChunkSize,
            jwtSecret: resolvedJwtSecret,
            encryptionKey: encryptionKey,
            corsAllowedOrigins: (Environment.first(matching: [
                "SERVER_CORS_ALLOWED_ORIGINS", "CORS_ALLOWED_ORIGINS",
            ]) ?? frontendURL)
            .split(separator: ",").map(String.init),
            redisURL: Environment.first(matching: ["REDIS_URL"]) ?? "redis://127.0.0.1:6379",
            frontendURL: frontendURL,
            appVersion: "0.0.1",
            isJwtSecretDefault: isJwtSecretDefault,
            subscriptionKey: Environment.first(matching: ["SUBSCRIPTION_KEY", "APP_LICENSE_KEY"])
        )
    }
}

extension Application {
    private struct ConfigKey: StorageKey { typealias Value = ServerConfig }

    var config: ServerConfig {
        get {
            guard let config = storage[ConfigKey.self] else {
                fatalError("ServerConfig accessed before configure(_:) set it.")
            }
            return config
        }
        set { storage[ConfigKey.self] = newValue }
    }
}
