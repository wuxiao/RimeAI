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
        .library(
            name: "RimeAIVoicePerformanceHelperBridge",
            targets: ["RimeAIVoicePerformanceHelperBridge"]
        ),
        .library(
            name: "RimeAIVoicePerformanceCollector",
            targets: ["RimeAIVoicePerformanceCollector"]
        ),
        .library(
            name: "RimeAIVoicePerformanceControlCore",
            targets: ["RimeAIVoicePerformanceControlCore"]
        ),
        .library(
            name: "RimeAIVoicePerformanceControlDarwin",
            targets: ["RimeAIVoicePerformanceControlDarwin"]
        ),
        .library(
            name: "RimeAIVoicePerformanceTracerDarwin",
            targets: ["RimeAIVoicePerformanceTracerDarwin"]
        ),
        .library(
            name: "RimeAIVoicePerformanceTracerProcessDarwin",
            targets: ["RimeAIVoicePerformanceTracerProcessDarwin"]
        ),
        .library(
            name: "RimeAIVoicePerformanceTracerCollectorProcess",
            targets: ["RimeAIVoicePerformanceTracerCollectorProcess"]
        ),
        .library(
            name: "RimeAIVoicePerformanceTracerDriverProcess",
            targets: ["RimeAIVoicePerformanceTracerDriverProcess"]
        ),
        .library(
            name: "RimeAIVoicePerformanceTracerHelperProcess",
            targets: ["RimeAIVoicePerformanceTracerHelperProcess"]
        ),
        .executable(
            name: "rimeai-voice-performance-tracer",
            targets: [
                "RimeAIVoicePerformanceTracerCollectorExecutable"
            ]
        ),
        .executable(
            name: "rimeai-voice-performance-driver",
            targets: [
                "RimeAIVoicePerformanceTracerDriverExecutable"
            ]
        ),
        .executable(
            name: "rimeai-voice-performance-helper",
            targets: [
                "RimeAIVoicePerformanceTracerHelperExecutable"
            ]
        ),
        .executable(
            name: "rimeai-voice-performance-collector",
            targets: ["RimeAIVoicePerformanceCollectorCLI"]
        ),
        .executable(
            name: "rimeai-voice-eval-driver",
            targets: ["RimeAIVoiceEvaluationDriverCLI"]
        ),
    ],
    targets: [
        .target(
            name: "RimeAIVoiceArtifactCore"
        ),
        .target(
            name: "RimeAIInputCore",
            dependencies: ["RimeAIVoiceArtifactCore"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security"),
            ]
        ),
        .binaryTarget(
            name: "RimeAIMacRuntime",
            path: "macos/Native/RimeAIMacRuntime.xcframework"
        ),
        .binaryTarget(
            name: "SherpaOnnxMacOS",
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.6-macos-static.xcframework.zip",
            checksum: "ef8fa1ae6a7764b8d80a79ab66a49d553b40af2df7dd18b08b8559cdca3a1b1e"
        ),
        .binaryTarget(
            name: "OnnxruntimeMacOS",
            url: "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.27.1/onnxruntime-macos-static-xcframework-1.27.1.xcframework.zip",
            checksum: "89769c25a63985e2ab7a12e72215c173c5078e49dc4a2273cb84b75e587d7b96"
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
            dependencies: ["RimeAIInputCore", "RimeAIVoiceHelperEngine"],
            path: "Sources/RimeAIVoiceHelper",
            exclude: ["Engine"],
            sources: ["main.swift"]
        ),
        .target(
            name: "RimeAIVoiceHelperEngine",
            dependencies: [
                "RimeAIInputCore",
                "RimeAIVoiceArtifactCore",
                "SherpaOnnxMacOS",
                "OnnxruntimeMacOS",
            ],
            path: "Sources/RimeAIVoiceHelper/Engine",
            linkerSettings: [
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Foundation"),
                .linkedFramework("CoreML"),
                .linkedFramework("Security"),
                .linkedLibrary("c++"),
            ]
        ),
        .target(
            name: "RimeAIVoicePerformanceHelperBridge",
            dependencies: [
                "RimeAIInputCore",
                "RimeAIVoiceArtifactCore",
                "RimeAIVoiceHelperEngine",
                "RimeAIVoicePerformanceControlCore",
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "RimeAIVoicePerformanceCollector",
            dependencies: [
                "RimeAIVoiceArtifactCore",
                "RimeAIVoicePerformanceControlCore",
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("IOKit"),
            ]
        ),
        .target(
            name: "RimeAIVoicePerformanceControlCore"
        ),
        .target(
            name: "RimeAIVoicePerformanceControlDarwin",
            dependencies: ["RimeAIVoicePerformanceControlCore"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedLibrary("bsm"),
            ]
        ),
        .target(
            name: "RimeAIVoicePerformanceTracerDarwin",
            dependencies: [
                "RimeAIVoicePerformanceCollector",
                "RimeAIVoicePerformanceControlDarwin",
            ]
        ),
        .target(
            name: "RimeAIVoicePerformanceTracerProcessDarwin",
            dependencies: ["RimeAIVoicePerformanceControlCore"],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "RimeAIVoicePerformanceTracerCollectorProcess",
            dependencies: [
                "RimeAIVoicePerformanceCollector",
                "RimeAIVoicePerformanceControlCore",
                "RimeAIVoicePerformanceTracerDarwin",
                "RimeAIVoicePerformanceTracerProcessDarwin",
            ]
        ),
        .target(
            name: "RimeAIVoicePerformanceTracerDriverProcess",
            dependencies: [
                "RimeAIVoicePerformanceControlCore",
                "RimeAIVoicePerformanceControlDarwin",
                "RimeAIVoicePerformanceTracerProcessDarwin",
            ],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "RimeAIVoicePerformanceTracerHelperProcess",
            dependencies: [
                "RimeAIInputCore",
                "RimeAIVoicePerformanceControlCore",
                "RimeAIVoicePerformanceControlDarwin",
                "RimeAIVoicePerformanceHelperBridge",
                "RimeAIVoicePerformanceTracerProcessDarwin",
            ]
        ),
        .executableTarget(
            name: "RimeAIVoicePerformanceTracerCollectorExecutable",
            dependencies: [
                "RimeAIVoicePerformanceTracerCollectorProcess"
            ]
        ),
        .executableTarget(
            name: "RimeAIVoicePerformanceTracerDriverExecutable",
            dependencies: [
                "RimeAIVoicePerformanceTracerDriverProcess"
            ]
        ),
        .executableTarget(
            name: "RimeAIVoicePerformanceTracerHelperExecutable",
            dependencies: [
                "RimeAIVoicePerformanceTracerHelperProcess"
            ]
        ),
        .executableTarget(
            name: "RimeAIVoicePerformanceCollectorCLI",
            dependencies: ["RimeAIVoicePerformanceCollector"]
        ),
        .target(
            name: "RimeAIVoiceEvaluationDriver",
            dependencies: [
                "RimeAIInputCore",
                "RimeAIVoiceArtifactCore",
                "RimeAIVoiceHelperEngine",
                "RimeAIVoicePerformanceHelperBridge",
            ]
        ),
        .executableTarget(
            name: "RimeAIVoiceEvaluationDriverCLI",
            dependencies: ["RimeAIVoiceEvaluationDriver"]
        ),
        .testTarget(
            name: "RimeAIInputCoreTests",
            dependencies: [
                "RimeAIInputCore",
                "RimeAIVoiceArtifactCore",
                "RimeBridgeC",
            ]
        ),
        .testTarget(
            name: "RimeAIVoiceArtifactCoreTests",
            dependencies: ["RimeAIVoiceArtifactCore"]
        ),
        .testTarget(
            name: "RimeAIVoiceHelperEngineTests",
            dependencies: [
                "RimeAIInputCore",
                "RimeAIVoiceArtifactCore",
                "RimeAIVoiceHelperEngine",
            ]
        ),
        .testTarget(
            name: "RimeAIVoicePerformanceHelperBridgeTests",
            dependencies: [
                "RimeAIInputCore",
                "RimeAIVoiceArtifactCore",
                "RimeAIVoiceHelperEngine",
                "RimeAIVoicePerformanceControlCore",
                "RimeAIVoicePerformanceHelperBridge",
            ],
            path: "tests/RimeAIVoicePerformanceHelperBridgeTests"
        ),
        .testTarget(
            name: "RimeAIVoicePerformanceCollectorTests",
            dependencies: [
                "RimeAIVoicePerformanceCollector",
                "RimeAIVoicePerformanceControlCore",
            ],
            path: "tests/RimeAIVoicePerformanceCollectorTests"
        ),
        .testTarget(
            name: "RimeAIVoicePerformanceControlCoreTests",
            dependencies: ["RimeAIVoicePerformanceControlCore"],
            path: "tests/RimeAIVoicePerformanceControlCoreTests"
        ),
        .testTarget(
            name: "RimeAIVoicePerformanceControlDarwinTests",
            dependencies: ["RimeAIVoicePerformanceControlDarwin"],
            path: "tests/RimeAIVoicePerformanceControlDarwinTests"
        ),
        .testTarget(
            name: "RimeAIVoicePerformanceTracerDarwinTests",
            dependencies: [
                "RimeAIVoicePerformanceCollector",
                "RimeAIVoicePerformanceControlCore",
                "RimeAIVoicePerformanceControlDarwin",
                "RimeAIVoicePerformanceTracerDarwin",
            ],
            path: "tests/RimeAIVoicePerformanceTracerDarwinTests"
        ),
        .testTarget(
            name: "RimeAIVoicePerformanceTracerProcessDarwinTests",
            dependencies: [
                "RimeAIVoicePerformanceControlCore",
                "RimeAIVoicePerformanceTracerProcessDarwin",
            ],
            path: "tests/RimeAIVoicePerformanceTracerProcessDarwinTests"
        ),
        .testTarget(
            name: "RimeAIVoicePerformanceTracerCollectorProcessTests",
            dependencies: [
                "RimeAIVoicePerformanceCollector",
                "RimeAIVoicePerformanceControlCore",
                "RimeAIVoicePerformanceTracerCollectorProcess",
                "RimeAIVoicePerformanceTracerProcessDarwin",
            ],
            path: "tests/RimeAIVoicePerformanceTracerCollectorProcessTests"
        ),
        .testTarget(
            name: "RimeAIVoicePerformanceTracerDriverProcessTests",
            dependencies: [
                "RimeAIVoicePerformanceControlCore",
                "RimeAIVoicePerformanceControlDarwin",
                "RimeAIVoicePerformanceTracerDriverProcess",
                "RimeAIVoicePerformanceTracerProcessDarwin",
            ],
            path: "tests/RimeAIVoicePerformanceTracerDriverProcessTests"
        ),
        .testTarget(
            name: "RimeAIVoicePerformanceTracerHelperProcessTests",
            dependencies: [
                "RimeAIVoicePerformanceControlCore",
                "RimeAIVoicePerformanceControlDarwin",
                "RimeAIVoicePerformanceTracerHelperProcess",
                "RimeAIVoicePerformanceTracerProcessDarwin",
            ],
            path: "tests/RimeAIVoicePerformanceTracerHelperProcessTests"
        ),
        .testTarget(
            name: "RimeAIVoiceEvaluationDriverTests",
            dependencies: [
                "RimeAIInputCore",
                "RimeAIVoiceEvaluationDriver",
                "RimeAIVoiceHelperEngine",
                "RimeAIVoicePerformanceHelperBridge",
            ],
            path: "tests/RimeAIVoiceEvaluationDriverTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
