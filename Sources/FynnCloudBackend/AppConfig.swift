import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import SotoCore
import Vapor

struct AppConfig: Sendable {
    // Database & Storage
    enum DatabaseStrategy {
        case postgres(SQLPostgresConfiguration)
        case sqlite(String)
    }
    enum StorageDriver {
        case s3(bucket: String)
        case local(path: String)
    }

    let database: DatabaseStrategy
    let storage: StorageDriver

    // Limits
    let maxBodySize: ByteCount  // Synchronized size for framework & logic
    let maxChunkSize: ByteCount

    // Auth & AWS
    let jwtSecret: String
    let corsAllowedOrigins: [String]
    let awsAccessKey: String
    let awsSecretKey: String
    let awsRegion: String
    let awsEndpoint: String

    let frontendURL: String

    static func load(for app: Application) -> AppConfig {
        // Database Logic
        let dbStrategy: DatabaseStrategy
        if let urlString = Environment.get("DATABASE_URL"), let url = URL(string: urlString),
            let pgConfig = try? SQLPostgresConfiguration(url: url)
        {
            dbStrategy = .postgres(pgConfig)
        } else {
            dbStrategy = .sqlite("db.sqlite")
        }

        // Storage Logic
        let storageDriver: StorageDriver
        if let bucket = Environment.get("S3_BUCKET") {
            storageDriver = .s3(bucket: bucket)
        } else {
            let path =
                Environment.get("STORAGE_PATH") ?? (app.directory.workingDirectory + "Storage/")
            storageDriver = .local(path: path)
        }

        // Body Size Logic (Default to maxChunkSize if not set), if maxChunkSize is not set, default to 100mb
        let maxChunkSizeString = Environment.get("MAX_CHUNK_SIZE") ?? "100mb"
        let maxChunkSize = ByteCount(stringLiteral: maxChunkSizeString)
        let sizeString = Environment.get("MAX_BODY_SIZE") ?? maxChunkSizeString
        let bodySize = ByteCount(stringLiteral: sizeString)

        // Frontend URL, used for OAuth callbacks and for CORS
        let frontendURL = Environment.get("FRONTEND_URL") ?? "http://localhost"

        return AppConfig(
            database: dbStrategy,
            storage: storageDriver,
            maxBodySize: bodySize,
            maxChunkSize: maxChunkSize,
            jwtSecret: Environment.get("JWT_SECRET") ?? [UInt8].random(count: 32).base64,
            corsAllowedOrigins: [
                Environment.get("CORS_ALLOWED_ORIGINS") ?? "http://localhost:3000"
            ],
            awsAccessKey: Environment.get("AWS_ACCESS_KEY_ID") ?? "",
            awsSecretKey: Environment.get("AWS_SECRET_ACCESS_KEY") ?? "",
            awsRegion: Environment.get("AWS_REGION") ?? "us-east-1",
            awsEndpoint: Environment.get("AWS_ENDPOINT") ?? "https://s3.amazonaws.com",
            frontendURL: frontendURL
        )
    }
}

// Vapor Storage Extension
extension Application {
    struct ConfigKey: StorageKey { typealias Value = AppConfig }
    var config: AppConfig {
        get { storage[ConfigKey.self] ?? .load(for: self) }
        set { storage[ConfigKey.self] = newValue }
    }
}
