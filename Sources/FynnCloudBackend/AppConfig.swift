import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import Vapor

struct AppConfig: Sendable {
    // MARK: - Sub-Types
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

    // MARK: - Properties
    let database: DatabaseStrategy
    let storage: StorageDriver
    let maxBodySize: ByteCount
    let maxChunkSize: ByteCount
    let jwtSecret: String
    let corsAllowedOrigins: [String]
    let aws: AWSConfig
    let frontendURL: String
    let primaryColor: TailwindColor
    let appName: String
    let appVersion: String

    struct AWSConfig: Sendable {
        let accessKey: String
        let secretKey: String
        let region: String
        let endpoint: String
    }

    // MARK: - Loader
    static func load(for app: Application) -> AppConfig {
        // Parse Sizes
        let maxChunkSizeStr = Environment.get("MAX_CHUNK_SIZE") ?? "100mb"
        let maxChunkSize = ByteCount(stringLiteral: maxChunkSizeStr)
        let maxBodySize = ByteCount(
            stringLiteral: Environment.get("MAX_BODY_SIZE") ?? maxChunkSizeStr)

        // Database Strategy Logic
        let dbStrategy: DatabaseStrategy = {
            if let url = Environment.get("DATABASE_URL").flatMap(URL.init),
                let pgConfig = try? SQLPostgresConfiguration(url: url)
            {
                return .postgres(pgConfig)
            }
            return .sqlite("db.sqlite")
        }()

        // Storage Logic
        let storage: StorageDriver = {
            if let bucket = Environment.get("S3_BUCKET") {
                return .s3(bucket: bucket)
            }
            let path =
                Environment.get("STORAGE_PATH") ?? "\(app.directory.workingDirectory)Storage/"
            return .local(path: path)
        }()

        // Identity & UI
        let color =
            Environment.get("PRIMARY_COLOR")
            .flatMap(TailwindColor.init) ?? .blue

        return AppConfig(
            database: dbStrategy,
            storage: storage,
            maxBodySize: maxBodySize,
            maxChunkSize: maxChunkSize,
            jwtSecret: Environment.get("JWT_SECRET") ?? [UInt8].random(count: 32).base64,
            corsAllowedOrigins: (Environment.get("CORS_ALLOWED_ORIGINS") ?? "https://localhost")
                .split(separator: ",").map(String.init),
            aws: AWSConfig(
                accessKey: Environment.get("AWS_ACCESS_KEY_ID") ?? "",
                secretKey: Environment.get("AWS_SECRET_ACCESS_KEY") ?? "",
                region: Environment.get("AWS_REGION") ?? "us-east-1",
                endpoint: Environment.get("AWS_ENDPOINT") ?? "https://s3.amazonaws.com"
            ),
            frontendURL: Environment.get("FRONTEND_URL") ?? "http://localhost",
            primaryColor: color,
            appName: Environment.get("APP_NAME") ?? "FynnCloud",
            appVersion: "1.0.0"
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
