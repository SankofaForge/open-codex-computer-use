import Foundation
import XCTest
@testable import OpenComputerUseWorkflowKit

final class WorkflowMCPServerTests: XCTestCase {
    func testRunReturnsRunningAndStatusEventuallyCompletes() throws {
        let root = try temporaryRoot()
        let dispatcher = RecordingDispatcher()
        let server = try WorkflowMCPServer(configuration: WorkflowConfiguration(workspaceRoot: root.path, backends: []), dispatcher: dispatcher)
        let response = try XCTUnwrap(object(server.handle(line: call("workflow_run", ["runId": "run-1", "workspaceRoot": root.path, "taskProfile": "evidence-only"]))))
        XCTAssertEqual(result(response)["status"] as? String, "running")
        let completed = try waitForStatus(server, runId: "run-1", expected: "complete")
        XCTAssertEqual(completed["status"] as? String, "complete")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".workflow/checkpoints/run-1.json").path))
        XCTAssertTrue(dispatcher.contexts.contains { $0.inputs["previousResults"] != nil })
    }

    func testCancelIsIdempotentAndPropagatesToDispatcher() throws {
        let root = try temporaryRoot()
        let dispatcher = RecordingDispatcher(delay: 0.2)
        let server = try WorkflowMCPServer(configuration: WorkflowConfiguration(workspaceRoot: root.path, backends: []), dispatcher: dispatcher)
        _ = server.handle(line: call("workflow_run", ["runId": "run-2", "workspaceRoot": root.path, "taskProfile": "evidence-only"]))
        let first = try XCTUnwrap(object(server.handle(line: call("workflow_cancel", ["runId": "run-2"]))))
        XCTAssertEqual(result(first)["status"] as? String, "cancelled")
        let second = try XCTUnwrap(object(server.handle(line: call("workflow_cancel", ["runId": "run-2"]))))
        XCTAssertEqual(result(second)["status"] as? String, "cancelled")
        XCTAssertGreaterThan(dispatcher.cancelCount, 0)
    }

    func testUnsupportedControlVersionIsRejected() throws {
        let server = try WorkflowMCPServer(configuration: WorkflowConfiguration(workspaceRoot: ".", backends: []), dispatcher: RecordingDispatcher())
        let response = try XCTUnwrap(object(server.handle(line: call("workflow_status", ["runId": "run-3", "schemaVersion": "workflow-control.v1"]))))
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testCheckpointDoesNotPersistInputSecrets() throws {
        let root = try temporaryRoot()
        let server = try WorkflowMCPServer(configuration: WorkflowConfiguration(workspaceRoot: root.path, backends: []), dispatcher: RecordingDispatcher())
        _ = server.handle(line: call("workflow_run", ["runId": "run-secret", "workspaceRoot": root.path, "taskProfile": "evidence-only", "apiKey": "do-not-persist"]))
        let checkpoint = try String(contentsOf: root.appendingPathComponent(".workflow/checkpoints/run-secret.json"), encoding: .utf8)
        XCTAssertFalse(checkpoint.contains("do-not-persist"))
        XCTAssertFalse(checkpoint.contains("apiKey"))
    }

    private func waitForStatus(_ server: WorkflowMCPServer, runId: String, expected: String) throws -> [String: Any] {
        for _ in 0..<100 {
            if let response = object(server.handle(line: call("workflow_status", ["runId": runId]))), let value = result(response)["status"] as? String, value == expected { return result(response) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("workflow did not reach (expected) status")
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

    private func result(_ response: [String: Any]) -> [String: Any] { response["result"] as? [String: Any] ?? [:] }
}

private final class RecordingDispatcher: WorkflowStageDispatcher, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var contexts: [WorkflowStageContext] = []
    private(set) var cancelCount = 0
    private let delay: TimeInterval

    init(delay: TimeInterval = 0) { self.delay = delay }

    func dispatch(stage: WorkflowStage, arguments: [String: Any]) throws -> [String: Any] {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.lock()
        contexts.append(WorkflowStageContext(runId: arguments["runId"] as? String ?? "", workspaceRoot: arguments["workspaceRoot"] as? String ?? "", taskProfile: arguments["taskProfile"] as? String ?? "", inputs: arguments))
        lock.unlock()
        return ["stage": stage.rawValue, "status": "complete", "value": stage.rawValue]
    }

    func cancel() {
        lock.lock()
        cancelCount += 1
        lock.unlock()
    }
}
