// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FynnCloudServer",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        // 🗄 An ORM for SQL and NoSQL databases.
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        // 🪶 Fluent driver for SQLite.
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.6.0"),
        // 🐘 Fluent driver for Postgres.
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.12.0"),
        // 📝 JWT for JWT authentication.
        .package(url: "https://github.com/vapor/jwt.git", from: "5.1.2"),
        // AWS SDK for Swift
        .package(url: "https://github.com/soto-project/soto.git", from: "7.12.0"),
        // 🔵 Non-blocking, event-driven networking for Swift. Used for custom executors
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // LDAP
        .package(url: "https://github.com/sersoft-gmbh/SwiftDirector", from: "0.0.17"),
    ],
    targets: [
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
                .product(name: "SwiftDirector", package: "SwiftDirector"),
            ],
            path: "Sources/FynnCloudServer",
            swiftSettings: swiftSettings
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
