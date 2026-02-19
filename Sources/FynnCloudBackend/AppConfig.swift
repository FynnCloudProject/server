import FluentPostgresDriver
import Vapor

struct AppConfig: Sendable {
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
    let ldapEnabled: Bool
    let ldapConfig: LDAPConfiguration
    let maxBodySize: ByteCount
    let maxChunkSize: ByteCount
    let jwtSecret: String
    let corsAllowedOrigins: [String]
    let aws: AWSConfig
    let frontendURL: String
    let primaryColor: TailwindColor
    let appName: String
    let appVersion: String
    let isJwtSecretDefault: Bool

    static func load(for app: Application) -> AppConfig {
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
        let isJwtSecretDefault = jwtSecretEnv == nil

        return AppConfig(
            database: dbStrategy,
            storage: storage,
            ldapEnabled: Bool(Environment.get("LDAP_ENABLED") ?? "false") ?? false,
            ldapConfig: LDAPConfiguration(
                host: Environment.get("LDAP_HOST") ?? "localhost",
                port: Environment.get("LDAP_PORT").flatMap(UInt16.init),
                useSSL: Environment.get("LDAP_USE_SSL") == "true",
                baseDN: Environment.get("LDAP_BASE_DN") ?? "dc=my-company,dc=com",
                bindDN: Environment.get("LDAP_BIND_DN") ?? "cn=admin,dc=my-company,dc=com",
                password: Environment.get("LDAP_PASSWORD") ?? "JonSn0w"
            ),
            maxBodySize: maxBodySize,
            maxChunkSize: maxChunkSize,
            jwtSecret: jwtSecretEnv ?? [UInt8].random(count: 32).base64,
            corsAllowedOrigins: (Environment.get("CORS_ALLOWED_ORIGINS") ?? frontendURL)
                .split(separator: ",").map(String.init),
            aws: AWSConfig(
                accessKey: Environment.get("AWS_ACCESS_KEY_ID") ?? "",
                secretKey: Environment.get("AWS_SECRET_ACCESS_KEY") ?? "",
                region: Environment.get("AWS_REGION") ?? "us-east-1",
                endpoint: Environment.get("AWS_ENDPOINT") ?? "https://s3.amazonaws.com"
            ),
            frontendURL: frontendURL,
            primaryColor: Environment.get("PRIMARY_COLOR")
                .flatMap(TailwindColor.init) ?? .blue,
            appName: Environment.get("APP_NAME") ?? "FynnCloud",
            appVersion: "0.1.0",
            isJwtSecretDefault: isJwtSecretDefault
        )
    }
}

extension Application {
    private struct ConfigKey: StorageKey { typealias Value = AppConfig }

    var config: AppConfig {
        get { storage[ConfigKey.self] ?? .load(for: self) }
        set { storage[ConfigKey.self] = newValue }
    }
}
