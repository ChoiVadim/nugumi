// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Nugumi",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Nugumi", targets: ["Nugumi"]),
        .executable(name: "NugumiToolWorker", targets: ["NugumiToolWorker"])
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
            name: "Nugumi",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                "CSQLCipher",
                "NugumiToolAgentCore",
                "NugumiToolIPC"
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "NugumiToolIPC",
            dependencies: ["NugumiToolAgentCore"]
        ),
        .target(name: "NugumiToolAgentCore"),
        .target(
            name: "CToolSandbox",
            path: "Sources/CToolSandbox",
            publicHeadersPath: "include"
        ),
        .target(
            name: "NugumiToolWorkerCore",
            dependencies: [
                "CToolSandbox",
                "NugumiToolAgentCore",
                "NugumiToolIPC"
            ]
        ),
        .executableTarget(
            name: "NugumiToolWorker",
            dependencies: [
                "NugumiToolAgentCore",
                "NugumiToolIPC",
                "NugumiToolWorkerCore"
            ],
            resources: [.copy("Resources/tool_worker_probe.py")]
        ),
        .testTarget(
            name: "NugumiTests",
            dependencies: ["Nugumi"]
        ),
        .testTarget(
            name: "NugumiToolIPCTests",
            dependencies: ["NugumiToolIPC"]
        ),
        .testTarget(
            name: "NugumiToolAgentCoreTests",
            dependencies: ["NugumiToolAgentCore"]
        ),
        .testTarget(
            name: "NugumiToolWorkerCoreTests",
            dependencies: [
                "CToolSandbox",
                "NugumiToolAgentCore",
                "NugumiToolWorkerCore",
                "NugumiToolIPC"
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
