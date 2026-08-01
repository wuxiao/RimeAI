// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "RimeAINative",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "RimeAIInputCore",
            targets: ["RimeAIInputCore"]
        ),
        .executable(
            name: "rime-candidate-service",
            targets: ["RimeCandidateService"]
        ),
    ],
    targets: [
        .target(
            name: "RimeAIInputCore"
        ),
        .systemLibrary(
            name: "CLibRime",
            pkgConfig: "rime",
            providers: [
                .brew(["librime"]),
            ]
        ),
        .target(
            name: "RimeBridgeC",
            dependencies: ["CLibRime"],
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-std=c++17"]),
            ]
        ),
        .executableTarget(
            name: "RimeCandidateService",
            dependencies: ["RimeBridgeC"]
        ),
        .testTarget(
            name: "RimeAIInputCoreTests",
            dependencies: ["RimeAIInputCore"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
