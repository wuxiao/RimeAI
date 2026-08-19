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
        .executable(
            name: "rimeai-voice-helper",
            targets: ["RimeAIVoiceHelper"]
        ),
    ],
    targets: [
        .target(
            name: "RimeAIInputCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .binaryTarget(
            name: "RimeAIMacRuntime",
            path: "macos/Native/RimeAIMacRuntime.xcframework"
        ),
        .target(
            name: "RimeBridgeC",
            dependencies: ["RimeAIMacRuntime"],
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-std=c++17"]),
            ]
        ),
        .executableTarget(
            name: "RimeCandidateService",
            dependencies: ["RimeBridgeC"]
        ),
        .executableTarget(
            name: "RimeAIVoiceHelper",
            dependencies: ["RimeAIInputCore"],
            linkerSettings: [
                .linkedFramework("Speech"),
                .linkedFramework("AVFAudio"),
            ]
        ),
        .testTarget(
            name: "RimeAIInputCoreTests",
            dependencies: ["RimeAIInputCore", "RimeBridgeC"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
