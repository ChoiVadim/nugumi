// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Gizmate",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Gizmate", targets: ["Gizmate"]),
        .executable(name: "GizmateToolWorker", targets: ["GizmateToolWorker"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.7.0")
    ],
    targets: [
        .target(
            name: "CSQLCipher",
            path: "Sources/CSQLCipher",
            publicHeadersPath: "include",
            cSettings: [
                .define("SQLITE_HAS_CODEC"),
                .define("SQLCIPHER_CRYPTO_CC"),
                .define("SQLITE_EXTRA_INIT", to: "sqlcipher_extra_init"),
                .define("SQLITE_EXTRA_SHUTDOWN", to: "sqlcipher_extra_shutdown"),
                .define("SQLITE_TEMP_STORE", to: "2"),
                .define("NDEBUG"),
                .headerSearchPath("include")
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("Foundation")
            ]
        ),
        .executableTarget(
            name: "Gizmate",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                "CSQLCipher",
                "GizmateToolAgentCore",
                "GizmateToolIPC"
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "GizmateToolIPC",
            dependencies: ["GizmateToolAgentCore"]
        ),
        .target(name: "GizmateToolAgentCore"),
        .target(
            name: "CToolSandbox",
            path: "Sources/CToolSandbox",
            publicHeadersPath: "include"
        ),
        .target(
            name: "GizmateToolWorkerCore",
            dependencies: [
                "CToolSandbox",
                "GizmateToolAgentCore",
                "GizmateToolIPC"
            ]
        ),
        .executableTarget(
            name: "GizmateToolWorker",
            dependencies: [
                "GizmateToolAgentCore",
                "GizmateToolIPC",
                "GizmateToolWorkerCore"
            ],
            resources: [.copy("Resources/tool_worker_probe.py")]
        ),
        .testTarget(
            name: "GizmateTests",
            dependencies: ["Gizmate"]
        ),
        .testTarget(
            name: "GizmateToolIPCTests",
            dependencies: ["GizmateToolIPC"]
        ),
        .testTarget(
            name: "GizmateToolAgentCoreTests",
            dependencies: ["GizmateToolAgentCore"]
        ),
        .testTarget(
            name: "GizmateToolWorkerCoreTests",
            dependencies: [
                "CToolSandbox",
                "GizmateToolAgentCore",
                "GizmateToolWorkerCore",
                "GizmateToolIPC"
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
