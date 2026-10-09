import Foundation
import XCTest
@testable import OpenComputerUseWorkflowKit

final class WorkflowChildMCPDispatcherTests: XCTestCase {
    func testDispatchesConfiguredStageThroughFakeBackend() throws {
        let dispatcher = try ConfiguredChildMCPStageDispatcher(configuration: configuration(), environment: ["WORKFLOW_MCP_FAKE_WORKFLOW": "1"])
        defer { dispatcher.shutdown() }

        let output = try dispatcher.dispatch(stage: .searchReferences, arguments: ["query": "brutalist"])
        XCTAssertEqual(output["backend"] as? String, "design-inspiration")
        XCTAssertEqual(output["tool"] as? String, "design_search_references")
    }

    func testOpenDesignPluginDiscoveryParsesJSONInMCPTextContent() throws {
        let dispatcher = try ConfiguredChildMCPStageDispatcher(configuration: configuration())
        let installedResponse: [String: Any] = [
            "content": [[
                "type": "text",
                "text": "{\"plugins\":[{\"id\":\"od-web-effect-extractor\"}]}",
            ]],
        ]
        let emptyCatalogResponse: [String: Any] = [
            "content": [["type": "text", "text": "{\"plugins\":[]}"]],
        ]

        XCTAssertTrue(dispatcher.pluginAvailable("od-web-effect-extractor", in: installedResponse))
        XCTAssertFalse(dispatcher.pluginAvailable("od-web-effect-extractor", in: emptyCatalogResponse))
        XCTAssertFalse(dispatcher.pluginAvailable("od-web-effect-extractor", in: ["content": [["type": "text", "text": "plugin described as od-web-effect-extractor"]]]))
    }

    func testRejectsMissingBackendBeforeLaunchingAProcess() throws {
        let dispatcher = try ConfiguredChildMCPStageDispatcher(configuration: WorkflowConfiguration(workspaceRoot: ".", backends: [
            WorkflowBackendConfiguration(kind: .designInspiration, command: "/definitely/missing", declaredTools: ["design_search_references"]),
        ]))

        XCTAssertThrowsError(try dispatcher.dispatch(stage: .captureSiteMotion, arguments: [:])) { error in
            XCTAssertEqual(error as? WorkflowStageDispatchError, .missingBackend(.browserUseCapture, .captureSiteMotion))
        }
    }

    func testOpenDesignFailsBeforeLaunchingWhenDaemonURLIsMissingOrBlank() throws {
        let backend = WorkflowBackendConfiguration(
            kind: .openDesign,
            command: "/definitely/missing",
            permittedEnvironmentVariables: ["OD_DAEMON_URL"],
            declaredTools: ["start_run"]
        )
        let invalidEnvironments: [[String: String]] = [[:], ["OD_DAEMON_URL": " \n"]]

        for environment in invalidEnvironments {
            let dispatcher = try ConfiguredChildMCPStageDispatcher(
                configuration: WorkflowConfiguration(workspaceRoot: ".", backends: [backend]),
                environment: environment
            )

            XCTAssertThrowsError(try dispatcher.dispatch(stage: .handoffOpenDesign, arguments: [:])) { error in
                XCTAssertEqual(error as? WorkflowStageDispatchError, .backend(WorkflowErrorRecord(
                    code: .invalidConfiguration,
                    message: "Open Design requires OD_DAEMON_URL in the workflow MCP process environment.",
                    backend: WorkflowBackendKind.openDesign.rawValue
                )))
            }
        }
    }

    func testBrowserUseCapabilityBlocksOnMissingRunnerConfiguration() throws {
        let dispatcher = try ConfiguredChildMCPStageDispatcher(
            configuration: browserUseConfiguration(),
            environment: [:]
        )
        defer { dispatcher.shutdown() }

        let preflight = try dispatcher.dispatch(stage: .preflight, arguments: ["requiresCapture": true])
        XCTAssertEqual(preflight["status"] as? String, "complete")

        let gpuOutput = try dispatcher.dispatch(stage: .checkCaptureGPU, arguments: [:])
        XCTAssertEqual(gpuOutput["backend"] as? String, "browser-use-capture")
        XCTAssertEqual(gpuOutput["tool"] as? String, "check_capture_gpu")
        XCTAssertEqual(gpuOutput["status"] as? String, "blocked")
        let gpuResult = try XCTUnwrap(gpuOutput["result"] as? [String: Any])
        let gpuCapability = try XCTUnwrap(gpuResult["structuredContent"] as? [String: Any])
        XCTAssertEqual(gpuCapability["status"] as? String, "blocked")
        XCTAssertEqual((gpuCapability["capability"] as? [String: Any])?["available"] as? Bool, false)

        let captureOutput = try dispatcher.dispatch(stage: .captureSiteMotion, arguments: [:])
        XCTAssertEqual(captureOutput["backend"] as? String, "browser-use-capture")
        XCTAssertEqual(captureOutput["tool"] as? String, "capture_site_motion")
        XCTAssertEqual(captureOutput["status"] as? String, "blocked")
    }

    func testRejectsMissingDeclaredTool() throws {
        let dispatcher = try ConfiguredChildMCPStageDispatcher(configuration: configuration(tools: ["echo"]))
        XCTAssertThrowsError(try dispatcher.dispatch(stage: .searchReferences, arguments: [:])) { error in
            XCTAssertEqual(error as? WorkflowStageDispatchError, .missingTool(.designInspiration, "design_search_references", .searchReferences))
        }
    }

    func testBrowserUseBackendRequiresItsBoundedToolSurface() throws {
        XCTAssertThrowsError(try WorkflowBackendConfiguration(
            kind: .browserUseCapture,
            command: "browser-use-capture-mcp",
            permittedEnvironmentVariables: browserUseEnvironmentVariables,
            declaredTools: ["check_capture_gpu"]
        ).validate()) { error in
            XCTAssertEqual((error as? WorkflowContractError)?.code, .invalidConfiguration)
        }

        XCTAssertNoThrow(try WorkflowBackendConfiguration(
            kind: .browserUseCapture,
            command: "browser-use-capture-mcp",
            permittedEnvironmentVariables: browserUseEnvironmentVariables,
            declaredTools: ["capture_site_motion", "check_capture_gpu"]
        ).validate())

        XCTAssertThrowsError(try WorkflowBackendConfiguration(
            kind: .browserUseCapture,
            command: "browser-use-capture-mcp",
            permittedEnvironmentVariables: Array(browserUseEnvironmentVariables.dropLast()),
            declaredTools: ["capture_site_motion", "check_capture_gpu"]
        ).validate()) { error in
            XCTAssertEqual((error as? WorkflowContractError)?.code, .invalidConfiguration)
        }
    }

    private func configuration(tools: [String] = ["design_search_references"]) throws -> WorkflowConfiguration {
        WorkflowConfiguration(workspaceRoot: ".", backends: [WorkflowBackendConfiguration(
            kind: .designInspiration,
            command: try fakeBackendURL().path,
            permittedEnvironmentVariables: ["WORKFLOW_MCP_FAKE_WORKFLOW"],
            declaredTools: tools
        )])
    }

    private func browserUseConfiguration() throws -> WorkflowConfiguration {
        WorkflowConfiguration(workspaceRoot: ".", backends: [try browserUseBackend()])
    }

    private func browserUseBackend() throws -> WorkflowBackendConfiguration {
        WorkflowBackendConfiguration(
            kind: .browserUseCapture,
            command: try fakeBackendURL().path,
            arguments: ["--browser-use-fixture"],
            permittedEnvironmentVariables: browserUseEnvironmentVariables,
            declaredTools: ["check_capture_gpu", "capture_site_motion"]
        )
    }

    private func fakeBackendURL() throws -> URL {
        var directory = Bundle(for: Self.self).bundleURL.resolvingSymlinksInPath().deletingLastPathComponent()
        while directory.pathComponents.count > 1 {
            let candidate = directory.appendingPathComponent("WorkflowMCPFakeBackend")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw NSError(domain: "WorkflowChildMCPDispatcherTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "fake backend executable not found"])
    }
}

private let browserUseEnvironmentVariables = [
    "VAST_INSTANCE_ID",
    "VAST_API_KEY",
    "BROWSER_USE_CHROMIUM_PATH",
]
