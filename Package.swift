// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Keyestro",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Keyestro", targets: ["KeyestroApp"]),
        .library(name: "KeyestroDomain", targets: ["KeyestroDomain"]),
        .library(name: "KeyestroCore", targets: ["KeyestroCore"]),
        .executable(name: "keyestro-extension-test", targets: ["KeyestroExtensionTest"]),
        .executable(name: "launcher-extension-test", targets: ["KeyestroExtensionTest"]),
        .executable(name: "keyestro-swift-extension-example", targets: ["KeyestroSwiftExtensionExample"]),
        .executable(name: "keyestro-benchmark", targets: ["KeyestroBenchmark"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.5")
    ],
    targets: [
        .target(
            name: "KeyestroDomain",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "KeyestroCore",
            dependencies: ["KeyestroDomain"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "KeyestroApp",
            dependencies: [
                "KeyestroDomain",
                "KeyestroCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [.process("Resources")],
            swiftSettings: swiftSettings,
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .executableTarget(
            name: "KeyestroExtensionTest",
            dependencies: ["KeyestroDomain", "KeyestroCore"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "KeyestroSwiftExtensionExample",
            path: "Examples/Extensions/SwiftExample",
            exclude: ["extension.json"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "KeyestroBenchmark",
            dependencies: ["KeyestroDomain", "KeyestroCore"],
            swiftSettings: swiftSettings,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "KeyestroDomainTests",
            dependencies: ["KeyestroDomain"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "KeyestroCoreTests",
            dependencies: ["KeyestroDomain", "KeyestroCore"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "KeyestroAppTests",
            dependencies: ["KeyestroApp", "KeyestroDomain", "KeyestroCore"],
            swiftSettings: swiftSettings
        ),
    ]
)

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .unsafeFlags(["-warnings-as-errors"], .when(configuration: .release)),
]
