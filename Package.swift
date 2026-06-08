// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenScope",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TokenScope", targets: ["TokenScopeApp"]),
        .executable(name: "TokenScopeCoreTestsRunner", targets: ["TokenScopeCoreTestsRunner"]),
        .executable(name: "TokenScopeSmoke", targets: ["TokenScopeSmoke"]),
        .library(name: "TokenScopeCore", targets: ["TokenScopeCore"])
    ],
    targets: [
        .target(
            name: "TokenScopeCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "TokenScopeApp",
            dependencies: ["TokenScopeCore"]
        ),
        .executableTarget(
            name: "TokenScopeCoreTestsRunner",
            dependencies: ["TokenScopeCore"]
        ),
        .executableTarget(
            name: "TokenScopeSmoke",
            dependencies: ["TokenScopeCore"]
        ),
        .testTarget(
            name: "TokenScopeTests",
            dependencies: ["TokenScopeCore"]
        )
    ]
)
