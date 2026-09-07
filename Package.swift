// swift-tools-version:6.0
import PackageDescription

// A tiny system-library target exposing <ldap.h> so we can read binary LDAP attributes
// (e.g. Active Directory objectGUID) losslessly via ldap_get_values_len. SwiftDirector's
// String(cString:) value decoding corrupts such binary values, so this is read separately.
func cldapShimTarget() -> Target {
    #if os(Linux)
    return .systemLibrary(
        name: "CLDAPShim",
        path: "Sources/CLDAPShimLinux",
        providers: [.apt(["libldap2-dev"])]
    )
    #else
    #if arch(arm64) || arch(arm)
    let openldapPath = "/opt/homebrew/opt/openldap"
    #else
    let openldapPath = "/usr/local/opt/openldap"
    #endif
    return .target(
        name: "CLDAPShim",
        path: "Sources/CLDAPShim",
        cSettings: [
            .unsafeFlags(["-I\(openldapPath)/include"])
        ],
        linkerSettings: [
            .unsafeFlags(["-L\(openldapPath)/lib"]),
            .linkedLibrary("ldap"),
            .linkedLibrary("lber"),
        ]
    )
    #endif
}

let package = Package(
    name: "FynnCloudServer",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.4"),
        // 🗄 An ORM for SQL and NoSQL databases.
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        // 🪶 Fluent driver for SQLite.
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.9.0"),
        // 🐘 Fluent driver for Postgres.
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.12.0"),
        // 📝 JWT for JWT authentication.
        .package(url: "https://github.com/vapor/jwt.git", from: "5.1.2"),
        // AWS SDK for Swift
        .package(url: "https://github.com/soto-project/soto.git", from: "7.12.0"),
        // 🔵 Non-blocking, event-driven networking for Swift. Used for custom executors
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // 📮 Queues - scheduled jobs with Redis driver
        .package(url: "https://github.com/vapor/queues-redis-driver.git", from: "1.1.2"),
        // 🔑 WebAuthn / Passkeys
        .package(url: "https://github.com/swift-server/swift-webauthn.git", exact: "1.0.0-beta.1"),
    ],
    targets: [
        cldapShimTarget(),
        .executableTarget(
            name: "FynnCloudServer",
            dependencies: [
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "JWT", package: "jwt"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "SotoS3", package: "soto"),
                .product(name: "QueuesRedisDriver", package: "queues-redis-driver"),
                .product(name: "WebAuthn", package: "swift-webauthn"),
                "CLDAPShim",
            ],
            path: "Sources/FynnCloudServer",
            resources: [
                .copy("../../Resources/templates"),
            ],
            swiftSettings: swiftSettings,
        ),
        .testTarget(
            name: "FynnCloudServerTests",
            dependencies: [
                .target(name: "FynnCloudServer"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
            path: "Tests/FynnCloudServerTests",
            swiftSettings: swiftSettings
        ),
    ]
)

var swiftSettings: [SwiftSetting] {
    [
        .enableUpcomingFeature("ExistentialAny")
    ]
}
