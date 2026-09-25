import Foundation
import XCTest
@testable import OpenComputerUseWorkflowKit

final class WorkflowMCPServerTests: XCTestCase {
    func testNonvisualRunUsesControlOnlyProfileAndAtomicCheckpoint() throws {
        let root = try temporaryRoot()
        let dispatcher = RecordingDispatcher()
        let server = try WorkflowMCPServer(configuration: WorkflowConfiguration(workspaceRoot: root.path, backends: []), dispatcher: dispatcher)
        let runID = UUID().uuidString.lowercased()
        let response = try XCTUnwrap(object(server.handle(line: call("workflow_run", ["runId": runID, "workspaceRoot": root.path, "taskProfile": "nonvisual", "profileReason": "Documentation-only change."]))))
        let toolResult = response["result"] as? [String: Any]
        let content = toolResult?["content"] as? [[String: Any]]
        XCTAssertFalse(toolResult?["isError"] as? Bool ?? true)
        XCTAssertEqual(content?.first?["type"] as? String, "text")
        XCTAssertNotNil(content?.first?["text"] as? String)
        XCTAssertEqual(result(response)["status"] as? String, "running")
        let complete = try waitForStatus(server, runId: runID, expected: "complete")
        XCTAssertEqual(complete["status"] as? String, "complete")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".workflow/checkpoints/\(runID).json").path))
        XCTAssertEqual(dispatcher.stages, [.preflight])
    }

    func testWorkflowRunRejectsNonUUIDAndWorkspaceOverride() throws {
        let root = try temporaryRoot()
        let server = try WorkflowMCPServer(configuration: WorkflowConfiguration(workspaceRoot: root.path, backends: []), dispatcher: RecordingDispatcher())
        let invalidID = object(server.handle(line: call("workflow_run", ["runId": "run-1", "workspaceRoot": root.path, "taskProfile": "nonvisual", "profileReason": "No visual work."])))
        XCTAssertNotEqual(result(invalidID ?? [:])["status"] as? String, "running")
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let mismatch = object(server.handle(line: call("workflow_run", ["runId": UUID().uuidString, "workspaceRoot": other.path, "taskProfile": "nonvisual", "profileReason": "No visual work."])))
        XCTAssertNotEqual(result(mismatch ?? [:])["status"] as? String, "running")
    }

    func testNonvisualRequiresReasonAndNoReference() throws {
        let root = try temporaryRoot()
        let server = try WorkflowMCPServer(configuration: WorkflowConfiguration(workspaceRoot: root.path, backends: []), dispatcher: RecordingDispatcher())
        let noReason = object(server.handle(line: call("workflow_run", ["runId": UUID().uuidString, "workspaceRoot": root.path, "taskProfile": "nonvisual"])))
        XCTAssertNotEqual(result(noReason ?? [:])["status"] as? String, "running")
        let withReference = object(server.handle(line: call("workflow_run", ["runId": UUID().uuidString, "workspaceRoot": root.path, "taskProfile": "nonvisual", "profileReason": "No visual work.", "reference": ["url": "https://example.com"]])))
        XCTAssertNotEqual(result(withReference ?? [:])["status"] as? String, "running")
    }

    func testCancelIsIdempotentAndPropagatesToDispatcher() throws {
        let root = try temporaryRoot()
        let dispatcher = RecordingDispatcher(delay: 0.2)
        let server = try WorkflowMCPServer(configuration: WorkflowConfiguration(workspaceRoot: root.path, backends: []), dispatcher: dispatcher)
        let runID = UUID().uuidString.lowercased()
        _ = server.handle(line: call("workflow_run", ["runId": runID, "workspaceRoot": root.path, "taskProfile": "nonvisual", "profileReason": "No visual work."]))
        let first = try XCTUnwrap(object(server.handle(line: call("workflow_cancel", ["runId": runID]))))
        XCTAssertEqual(result(first)["status"] as? String, "cancelled")
        let second = try XCTUnwrap(object(server.handle(line: call("workflow_cancel", ["runId": runID]))))
        XCTAssertEqual(result(second)["status"] as? String, "cancelled")
        XCTAssertGreaterThan(dispatcher.cancelCount, 0)
    }

    func testUnsupportedControlVersionIsRejected() throws {
        let server = try WorkflowMCPServer(configuration: WorkflowConfiguration(workspaceRoot: ".", backends: []), dispatcher: RecordingDispatcher())
        let response = try XCTUnwrap(object(server.handle(line: call("workflow_status", ["runId": UUID().uuidString, "schemaVersion": "workflow-control.v1"]))))
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testCheckpointDoesNotPersistInputSecrets() throws {
        let root = try temporaryRoot()
        let server = try WorkflowMCPServer(configuration: WorkflowConfiguration(workspaceRoot: root.path, backends: []), dispatcher: RecordingDispatcher())
        let runID = UUID().uuidString.lowercased()
        _ = server.handle(line: call("workflow_run", ["runId": runID, "workspaceRoot": root.path, "taskProfile": "nonvisual", "profileReason": "No visual work.", "apiKey": "do-not-persist"]))
        let checkpoint = try String(contentsOf: root.appendingPathComponent(".workflow/checkpoints/\(runID).json"), encoding: .utf8)
        XCTAssertFalse(checkpoint.contains("do-not-persist"))
        XCTAssertFalse(checkpoint.contains("apiKey"))
    }

    private func waitForStatus(_ server: WorkflowMCPServer, runId: String, expected: String) throws -> [String: Any] {
        for _ in 0..<100 {
            if let response = object(server.handle(line: call("workflow_status", ["runId": runId]))), let value = result(response)["status"] as? String, value == expected { return result(response) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("workflow did not reach expected status")
        return [:]
    }

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func call(_ name: String, _ arguments: [String: Any]) -> String {
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
        return String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
    }

    private func object(_ response: String?) -> [String: Any]? {
        guard let response, let data = response.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func result(_ response: [String: Any]) -> [String: Any] {
        guard
            let toolResult = response["result"] as? [String: Any],
            let content = toolResult["content"] as? [[String: Any]],
            let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
            let data = text.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data),
            let value = decoded as? [String: Any]
        else { return [:] }
        return value
    }
}

private final class RecordingDispatcher: WorkflowStageDispatcher, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var stages: [WorkflowStage] = []
    private(set) var cancelCount = 0
    private let delay: TimeInterval

    init(delay: TimeInterval = 0) { self.delay = delay }

    func dispatch(stage: WorkflowStage, arguments: [String: Any]) throws -> [String: Any] {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.lock()
        stages.append(stage)
        lock.unlock()
        return ["stage": stage.rawValue, "status": "complete"]
    }

    func cancel() {
        lock.lock()
        cancelCount += 1
        lock.unlock()
    }
}
