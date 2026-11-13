// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "CcinnStarRocks",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MySQLWire", targets: ["MySQLWire"]),
        .library(name: "StarRocksKit", targets: ["StarRocksKit"]),
        .library(name: "CcinnStarRocksKit", targets: ["CcinnStarRocksKit"]),
        .executable(name: "CcinnStarRocks", targets: ["CcinnStarRocks"]),
    ],
    targets: [
        // MySQL client/server protocol: framing, handshake, auth, text result sets. No I/O.
        .target(name: "MySQLWire", swiftSettings: settings),
        // Transport, connections, pool, queries and StarRocks-aware metadata/operations.
        .target(name: "StarRocksKit", dependencies: ["MySQLWire"], swiftSettings: settings),
        // UI-independent app logic: profiles, SQL lexer/completion, charts, export.
        .target(name: "CcinnStarRocksKit", dependencies: ["StarRocksKit"], swiftSettings: settings),
        // SwiftUI application.
        .executableTarget(name: "CcinnStarRocks", dependencies: ["StarRocksKit", "CcinnStarRocksKit"], swiftSettings: settings),

        .testTarget(name: "MySQLWireTests", dependencies: ["MySQLWire"], swiftSettings: settings),
        .testTarget(name: "StarRocksKitTests", dependencies: ["MySQLWire", "StarRocksKit"], swiftSettings: settings),
        .testTarget(name: "CcinnStarRocksKitTests", dependencies: ["StarRocksKit", "CcinnStarRocksKit"], swiftSettings: settings),
        .testTarget(name: "IntegrationTests", dependencies: ["StarRocksKit", "CcinnStarRocksKit"], swiftSettings: settings),
    ],
    swiftLanguageModes: [.v6]
)
