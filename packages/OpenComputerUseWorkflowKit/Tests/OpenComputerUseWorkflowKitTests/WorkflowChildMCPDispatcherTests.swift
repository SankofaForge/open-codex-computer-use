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

    func testRejectsMissingBackendBeforeLaunchingAProcess() throws {
        let dispatcher = try ConfiguredChildMCPStageDispatcher(configuration: WorkflowConfiguration(workspaceRoot: ".", backends: [
            WorkflowBackendConfiguration(kind: .designInspiration, command: "/definitely/missing", declaredTools: ["design_search_references"]),
        ]))

        XCTAssertThrowsError(try dispatcher.dispatch(stage: .captureSiteMotion, arguments: [:])) { error in
            XCTAssertEqual(error as? WorkflowStageDispatchError, .missingBackend(.browserUseCapture, .captureSiteMotion))
        }
    }

    func testDispatchesCaptureStagesThroughBrowserUseBackend() throws {
        let dispatcher = try ConfiguredChildMCPStageDispatcher(configuration: browserUseConfiguration(), environment: ["WORKFLOW_MCP_FAKE_WORKFLOW": "1"])
        defer { dispatcher.shutdown() }
        XCTAssertEqual(try dispatcher.dispatch(stage: .checkCaptureGPU, arguments: [:])["backend"] as? String, "browser-use-capture")
        XCTAssertEqual(try dispatcher.dispatch(stage: .captureSiteMotion, arguments: [:])["backend"] as? String, "browser-use-capture")
    }

    func testBrowserUseBackendRequiresBothBoundedTools() {
        XCTAssertThrowsError(try WorkflowBackendConfiguration(kind: .browserUseCapture, command: "browser-use-capture-mcp", declaredTools: ["check_capture_gpu"]).validate())
    }

    func testRejectsMissingDeclaredTool() throws {
        let dispatcher = try ConfiguredChildMCPStageDispatcher(configuration: configuration(tools: ["echo"]))
        XCTAssertThrowsError(try dispatcher.dispatch(stage: .searchReferences, arguments: [:])) { error in
            XCTAssertEqual(error as? WorkflowStageDispatchError, .missingTool(.designInspiration, "design_search_references", .searchReferences))
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
        WorkflowConfiguration(workspaceRoot: ".", backends: [WorkflowBackendConfiguration(
            kind: .browserUseCapture,
            command: try fakeBackendURL().path,
            permittedEnvironmentVariables: ["WORKFLOW_MCP_FAKE_WORKFLOW", "BROWSER_USE_CHROMIUM_PATH"],
            declaredTools: ["check_capture_gpu", "capture_site_motion"]
        )])
    }

    private func fakeBackendURL() throws -> URL {
        let workingDirectoryCandidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/out/Products/Debug/WorkflowMCPFakeBackend")
        if FileManager.default.isExecutableFile(atPath: workingDirectoryCandidate.path) { return workingDirectoryCandidate }
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        while directory.pathComponents.count > 1 {
            let candidate = directory.appendingPathComponent("WorkflowMCPFakeBackend")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            let productsCandidate = directory.appendingPathComponent(".build/out/Products/Debug/WorkflowMCPFakeBackend")
            if FileManager.default.isExecutableFile(atPath: productsCandidate.path) { return productsCandidate }
            directory.deleteLastPathComponent()
        }
        throw NSError(domain: "WorkflowChildMCPDispatcherTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "fake backend executable not found"])
    }
}
