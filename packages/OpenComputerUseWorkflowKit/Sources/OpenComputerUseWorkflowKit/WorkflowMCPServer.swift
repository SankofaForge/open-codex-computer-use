import Foundation

public protocol WorkflowStageDispatcher { func dispatch(stage: WorkflowStage, arguments: [String: Any]) throws -> [String: Any] }
public struct StubWorkflowStageDispatcher: WorkflowStageDispatcher { public init() {} ; public func dispatch(stage: WorkflowStage, arguments: [String: Any]) throws -> [String: Any] { ["stage": stage.rawValue, "implemented": false] } }

public final class WorkflowMCPServer {
    public static let toolNames = ["workflow_preflight", "workflow_search_references", "workflow_prepare_references", "workflow_extract_tokens", "workflow_check_capture_gpu", "workflow_capture_site_motion", "workflow_submit_motion_analysis", "workflow_extract_frames", "workflow_handoff_open_design", "workflow_resolve_asset_routes", "workflow_validate", "workflow_run", "workflow_cancel"]
    private let dispatcher: WorkflowStageDispatcher; private var cancelled = Set<String>(); private var checkpoints = [String: [String: Any]]()
    public init(configuration: WorkflowConfiguration, dispatcher: WorkflowStageDispatcher? = nil) throws {
        self.dispatcher = try dispatcher ?? ConfiguredChildMCPStageDispatcher(configuration: configuration)
    }
    public func run() throws { while let line = readLine(strippingNewline: true) { if let response = handle(line: line), let data = (response + "\n").data(using: .utf8) { FileHandle.standardOutput.write(data) } } }
    public func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8), let p = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return error(nil, -32700, "Invalid JSON-RPC payload") }
        let id = p["id"] ?? NSNull(); let method = p["method"] as? String; let params = p["params"] as? [String: Any] ?? [:]
        do { switch method {
        case "initialize": return try result(id, ["protocolVersion": "2025-03-26", "serverInfo": ["name": "open-computer-use-workflow", "version": "1"], "capabilities": ["tools": ["listChanged": false]]])
        case "notifications/initialized": return nil
        case "ping": return try result(id, [:])
        case "tools/list": return try result(id, ["tools": Self.toolNames.map { ["name": $0, "description": "Design-inspiration workflow operation", "inputSchema": ["type": "object", "additionalProperties": true]] }])
        case "tools/call": return try call(id, params)
        default: return error(id, -32601, "Method not found: \(method ?? "")") }
        } catch { return error(id, -32000, String(describing: error)) }
    }
    private func call(_ id: Any, _ p: [String: Any]) throws -> String { guard let name = p["name"] as? String, Self.toolNames.contains(name) else { return error(id, -32602, "Unknown workflow tool") }; let a = p["arguments"] as? [String: Any] ?? [:]; let runID = a["runId"] as? String ?? UUID().uuidString
        if name == "workflow_cancel" { cancelled.insert(runID); return try result(id, envelope(runID, "cancel", "partial", ["cancelled"])) }
        if name == "workflow_run" {
            var record = envelope(runID, "preflight", "complete", [])
            for stage in WorkflowStage.allCases {
                if cancelled.contains(runID) { break }
                record = try dispatch(runID: runID, stage: stage, arguments: a)
                checkpoints[runID] = record
                if record["status"] as? String == "blocked" { break }
            }
            return try result(id, record)
        }
        let stage = WorkflowStage(rawValue: String(name.dropFirst(9))) ?? .validate
        let record = try dispatch(runID: runID, stage: stage, arguments: a)
        checkpoints[runID] = record
        return try result(id, record)
    }
    private func dispatch(runID: String, stage: WorkflowStage, arguments: [String: Any]) throws -> [String: Any] {
        do { return envelope(runID, stage.rawValue, "complete", try dispatcher.dispatch(stage: stage, arguments: arguments)) }
        catch let error as WorkflowStageDispatchError {
            switch error {
            case .backend(let record): return envelope(runID, stage.rawValue, "partial", [], error: record)
            case .missingBackend(let kind, let failedStage): return envelope(runID, failedStage.rawValue, "blocked", [], gaps: [WorkflowGap(code: "missing_backend", message: "No \(kind.rawValue) backend is configured.", required: true)], blockedReason: error.localizedDescription)
            case .missingTool(let kind, let tool, let failedStage): return envelope(runID, failedStage.rawValue, "blocked", [], gaps: [WorkflowGap(code: "missing_tool", message: "\(kind.rawValue) does not declare \(tool).", required: true)], blockedReason: error.localizedDescription)
            }
        }
    }
    private func envelope(_ run: String, _ stage: String, _ status: String, _ output: [String: Any], gaps: [WorkflowGap] = [], blockedReason: String? = nil, error: WorkflowErrorRecord? = nil) -> [String: Any] {
        var value: [String: Any] = ["schemaVersion": "workflow-control.v1", "runId": run, "stage": stage, "status": status, "outputs": output, "manifestPath": NSNull(), "gaps": gaps.map { ["code": $0.code, "message": $0.message, "required": $0.required] }, "blockedReason": blockedReason ?? NSNull()]
        if let error { value["error"] = ["code": error.code.rawValue, "message": error.message, "backend": error.backend as Any] }
        return value
    }
    private func result(_ id: Any, _ value: [String: Any]) throws -> String { try encode(["jsonrpc": "2.0", "id": id, "result": value]) }
    private func error(_ id: Any?, _ code: Int, _ message: String) -> String { (try? encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])) ?? "" }
    private func encode(_ value: [String: Any]) throws -> String { String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)! }
}
