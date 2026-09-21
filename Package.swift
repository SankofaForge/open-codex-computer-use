// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OpenComputerUse",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "OpenComputerUseKit",
            targets: ["OpenComputerUseKit"]
        ),
        .library(
            name: "OpenComputerUseWorkflowKit",
            targets: ["OpenComputerUseWorkflowKit"]
        ),
        .executable(
            name: "OpenComputerUse",
            targets: ["OpenComputerUse"]
        ),
        .executable(
            name: "OpenComputerUseFixture",
            targets: ["OpenComputerUseFixture"]
        ),
        .executable(
            name: "OpenComputerUseSmokeSuite",
            targets: ["OpenComputerUseSmokeSuite"]
        ),
        .executable(
            name: "CursorMotion",
            targets: ["CursorMotion"]
        ),
        .executable(
            name: "StandaloneCursor",
            targets: ["StandaloneCursor"]
        ),
    ],
    targets: [
        .target(
            name: "OpenComputerUseKit",
            path: "packages/OpenComputerUseKit/Sources/OpenComputerUseKit"
        ),
        .target(
            name: "OpenComputerUseWorkflowKit",
            path: "packages/OpenComputerUseWorkflowKit/Sources/OpenComputerUseWorkflowKit"
        ),
        .executableTarget(
            name: "OpenComputerUse",
            dependencies: ["OpenComputerUseKit", "OpenComputerUseWorkflowKit"],
            path: "apps/OpenComputerUse/Sources/OpenComputerUse"
        ),
        .executableTarget(
            name: "OpenComputerUseFixture",
            dependencies: ["OpenComputerUseKit"],
            path: "apps/OpenComputerUseFixture/Sources/OpenComputerUseFixture"
        ),
        .executableTarget(
            name: "OpenComputerUseSmokeSuite",
            dependencies: ["OpenComputerUseKit"],
            path: "apps/OpenComputerUseSmokeSuite/Sources/OpenComputerUseSmokeSuite"
        ),
        .executableTarget(
            name: "WorkflowMCPFakeBackend",
            path: "apps/WorkflowMCPFakeBackend/Sources/WorkflowMCPFakeBackend"
        ),
        .executableTarget(
            name: "CursorMotion",
            path: "experiments/CursorMotion/Sources/CursorMotion"
        ),
        .target(
            name: "StandaloneCursorSupport",
            path: "experiments/StandaloneCursor/Sources/StandaloneCursorSupport"
        ),
        .executableTarget(
            name: "StandaloneCursor",
            dependencies: ["StandaloneCursorSupport"],
            path: "experiments/StandaloneCursor/Sources/StandaloneCursor"
        ),
        .testTarget(
            name: "OpenComputerUseKitTests",
            dependencies: ["OpenComputerUseKit"],
            path: "packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests"
        ),
        .testTarget(
            name: "OpenComputerUseWorkflowKitTests",
            dependencies: ["OpenComputerUseWorkflowKit", "WorkflowMCPFakeBackend"],
            path: "packages/OpenComputerUseWorkflowKit/Tests/OpenComputerUseWorkflowKitTests"
        ),
        .testTarget(
            name: "StandaloneCursorSupportTests",
            dependencies: ["StandaloneCursorSupport"],
            path: "experiments/StandaloneCursor/Tests/StandaloneCursorSupportTests"
        ),
    ]
)
