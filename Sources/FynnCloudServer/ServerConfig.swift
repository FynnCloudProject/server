import FluentPostgresDriver
import Vapor

enum ServerConfigError: Error, CustomStringConvertible {
    case missingEncryptionKey

    var description: String {
        switch self {
        case .missingEncryptionKey:
            return "ENCRYPTION_KEY environment variable is required but not set."
        }
    }
}

struct ServerConfig: Sendable {
    enum DatabaseStrategy: Sendable {
        case postgres(SQLPostgresConfiguration)
        case sqlite(String)
    }

    enum StorageDriver: Sendable {
        case s3(bucket: String)
        case local(path: String)
    }

    enum TailwindColor: String, CaseIterable, Sendable {
        case slate, gray, zinc, neutral, stone, red, orange, amber,
            yellow, lime, green, emerald, teal, cyan, sky, blue,
            indigo, violet, purple, fuchsia, pink, rose
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
    let aws: AWSConfig
    let frontendURL: String
    let appVersion: String
    let isJwtSecretDefault: Bool
    let subscriptionKey: String?
    let rateLimitEnabled: Bool
    let rateLimitAuth: Int
    let rateLimitShare: Int
    let rateLimitAPI: Int

    static func load(for app: Application) throws -> ServerConfig {
        guard let encryptionKey = Environment.get("ENCRYPTION_KEY"),
            !encryptionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            app.logger.critical(
                "ENCRYPTION_KEY is not set. It is required to encrypt 2FA secrets at rest and must be a fixed, permanent value. Generate one with `openssl rand -base64 32`."
            )
            throw ServerConfigError.missingEncryptionKey
        }

        let maxChunkSizeStr = Environment.get("MAX_CHUNK_SIZE") ?? "100mb"
        let maxChunkSize = ByteCount(stringLiteral: maxChunkSizeStr)
        let maxBodySize = ByteCount(
            stringLiteral: Environment.get("MAX_BODY_SIZE") ?? maxChunkSizeStr)

        let frontendURL = Environment.get("FRONTEND_URL") ?? "https://localhost"

        let dbStrategy: DatabaseStrategy
        if let url = Environment.get("DATABASE_URL").flatMap(URL.init),
            let pgConfig = try? SQLPostgresConfiguration(url: url)
        {
            dbStrategy = .postgres(pgConfig)
        } else {
            dbStrategy = .sqlite(Environment.get("SQLITE_PATH") ?? "db.sqlite")
        }

        let storage: StorageDriver
        if let bucket = Environment.get("S3_BUCKET") {
            storage = .s3(bucket: bucket)
        } else {
            let path =
                Environment.get("STORAGE_PATH") ?? "\(app.directory.workingDirectory)Storage/"
            storage = .local(path: path)
        }

        let jwtSecretEnv = Environment.get("JWT_SECRET")
        let resolvedJwtSecret = jwtSecretEnv ?? [UInt8].random(count: 32).base64

        return ServerConfig(
            database: dbStrategy,
            storage: storage,
            maxBodySize: maxBodySize,
            maxChunkSize: maxChunkSize,
            jwtSecret: resolvedJwtSecret,
            encryptionKey: encryptionKey,
            corsAllowedOrigins: (Environment.get("CORS_ALLOWED_ORIGINS") ?? frontendURL)
                .split(separator: ",").map(String.init),
            redisURL: Environment.get("REDIS_URL") ?? "redis://127.0.0.1:6379",
            aws: AWSConfig(
                accessKey: Environment.get("AWS_ACCESS_KEY_ID") ?? "",
                secretKey: Environment.get("AWS_SECRET_ACCESS_KEY") ?? "",
                region: Environment.get("AWS_REGION") ?? "us-east-1",
                endpoint: Environment.get("AWS_ENDPOINT") ?? "https://s3.amazonaws.com"
            ),
            frontendURL: frontendURL,
            appVersion: "0.0.1",
            isJwtSecretDefault: jwtSecretEnv == nil,
            subscriptionKey: (Environment.get("APP_SUBSCRIPTION_KEY")
                ?? Environment.get("APP_LICENSE_KEY"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 },
            rateLimitEnabled: Environment.get("RATE_LIMIT_ENABLED").flatMap(Bool.init) ?? false,
            rateLimitAuth: Int(Environment.get("RATE_LIMIT_AUTH") ?? "10") ?? 10,
            rateLimitShare: Int(Environment.get("RATE_LIMIT_SHARE") ?? "60") ?? 60,
            rateLimitAPI: Int(Environment.get("RATE_LIMIT_API") ?? "300") ?? 300
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
