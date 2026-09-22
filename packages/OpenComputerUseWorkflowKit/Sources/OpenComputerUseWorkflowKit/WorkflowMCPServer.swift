import Foundation

public protocol WorkflowStageDispatcher {
    func dispatch(stage: WorkflowStage, arguments: [String: Any]) throws -> [String: Any]
    func cancel()
    func cancel(runId: String)
}

public extension WorkflowStageDispatcher {
    func cancel() {}
    func cancel(runId: String) { cancel() }
}

public struct StubWorkflowStageDispatcher: WorkflowStageDispatcher {
    public init() {}
    public func dispatch(stage: WorkflowStage, arguments: [String: Any]) throws -> [String: Any] {
        ["stage": stage.rawValue, "status": "complete", "implemented": false]
    }
}

private struct WorkflowRunRecord {
    let runId: String
    let workspaceRoot: URL
    let taskProfile: String
    let inputs: [String: Any]
    var status: WorkflowRunStatus
    var stage: WorkflowStage
    var completedStages: [WorkflowStage]
    var previousResults: [WorkflowStage: [String: Any]]
    var latest: [String: Any]
}

private final class WorkflowRunManager: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.opencomputeruse.workflow.run-manager")
    private var records: [String: WorkflowRunRecord] = [:]
    private let dispatcher: WorkflowStageDispatcher
    let defaultWorkspaceRoot: URL

    init(dispatcher: WorkflowStageDispatcher, defaultWorkspaceRoot: URL) {
        self.dispatcher = dispatcher
        self.defaultWorkspaceRoot = defaultWorkspaceRoot
    }

    func start(runId: String, workspaceRoot: URL, taskProfile: String, inputs: [String: Any]) -> [String: Any] {
        queue.sync {
            if let existing = records[runId] { return existing.latest }
            let record = WorkflowRunRecord(runId: runId, workspaceRoot: workspaceRoot, taskProfile: taskProfile, inputs: inputs, status: .running, stage: .preflight, completedStages: [], previousResults: [:], latest: workflowEnvelope(runId: runId, stage: .preflight, status: .running, outputs: [:]))
            records[runId] = record
            writeCheckpoint(record)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.execute(runId: runId) }
            return record.latest
        }
    }

    func status(runId: String) -> [String: Any] {
        queue.sync { records[runId]?.latest ?? workflowEnvelope(runId: runId, stage: .preflight, status: .blocked, outputs: [:], blockedReason: "Unknown workflow run.") }
    }

    func resume(runId: String, workspaceRoot: URL) -> [String: Any] {
        queue.sync {
            guard var record = records[runId] ?? loadCheckpoint(runId: runId, workspaceRoot: workspaceRoot) else {
                return workflowEnvelope(runId: runId, stage: .preflight, status: .blocked, outputs: [:], blockedReason: "Workflow inputs are unavailable for recovery.")
            }
            guard record.status != .complete else { return record.latest }
            record.status = .running
            record.latest = workflowEnvelope(runId: runId, stage: record.stage, status: .running, outputs: [:])
            records[runId] = record
            writeCheckpoint(record)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.execute(runId: runId) }
            return record.latest
        }
    }

    func cancel(runId: String, reason: String?) -> [String: Any] {
        queue.sync {
            guard var record = records[runId] else { return workflowEnvelope(runId: runId, stage: .preflight, status: .cancelled, outputs: [:], blockedReason: reason ?? "Cancelled.") }
            guard record.status == .running else { return record.latest }
            record.status = .cancelled
            record.latest = workflowEnvelope(runId: runId, stage: record.stage, status: .cancelled, outputs: [:], blockedReason: reason ?? "Cancelled.")
            records[runId] = record
            dispatcher.cancel(runId: runId)
            writeCheckpoint(record)
            return record.latest
        }
    }

    func dispatchOne(stage: WorkflowStage, context: WorkflowStageContext) throws -> [String: Any] {
        try dispatcher.dispatch(stage: stage, arguments: context.arguments(for: stage))
    }

    private func execute(runId: String) {
        while true {
            guard let record = queue.sync(execute: { records[runId] }), record.status == .running else { return }
            guard let stage = WorkflowStage.allCases.first(where: { !record.completedStages.contains($0) }) else {
                guard record.completedStages.contains(.validate) else {
                    finish(runId: runId, status: .blocked, stage: record.stage, output: workflowEnvelope(runId: runId, stage: record.stage, status: .blocked, outputs: [:], blockedReason: "workflow_validate did not complete"))
                    return
                }
                finish(runId: runId, status: .complete, stage: .validate, output: workflowEnvelope(runId: runId, stage: .validate, status: .complete, outputs: record.previousResults[.validate] ?? [:]))
                return
            }
            let context = WorkflowStageContext(runId: record.runId, workspaceRoot: record.workspaceRoot.path, taskProfile: record.taskProfile, inputs: record.inputs, previousResults: record.previousResults)
            do {
                let output = try dispatcher.dispatch(stage: stage, arguments: context.arguments(for: stage))
                let status = try validatedStageStatus(output, stage: stage)
                if status != "complete" {
                    finish(runId: runId, status: WorkflowRunStatus(rawValue: status) ?? .blocked, stage: stage, output: output)
                    return
                }
                queue.sync {
                    guard var current = records[runId], current.status == .running else { return }
                    current.stage = stage
                    current.completedStages.append(stage)
                    current.previousResults[stage] = output
                    current.latest = workflowEnvelope(runId: runId, stage: stage, status: .running, outputs: output)
                    records[runId] = current
                    writeCheckpoint(current)
                }
            } catch let error as WorkflowContractError {
                finish(runId: runId, status: .blocked, stage: stage, output: workflowEnvelope(runId: runId, stage: stage, status: .blocked, outputs: [:], blockedReason: error.message, error: WorkflowErrorRecord(code: error.code, message: error.message)))
                return
            } catch let error as WorkflowStageDispatchError {
                let record: WorkflowErrorRecord
                switch error {
                case .backend(let backendError): record = backendError
                case .missingBackend(let kind, let failedStage): record = WorkflowErrorRecord(code: .backendUnavailable, message: "No \(kind.rawValue) backend is configured for \(failedStage.rawValue).")
                case .missingTool(let kind, let tool, let failedStage): record = WorkflowErrorRecord(code: .backendUnavailable, message: "\(kind.rawValue) does not declare \(tool) for \(failedStage.rawValue).")
                }
                let invalidEvidenceCodes: Set<WorkflowErrorCode> = [
                    .invalidEvidence,
                    .unsupportedSchema,
                    .artifactOutsideWorkspace,
                    .artifactMissing,
                    .artifactEmpty,
                    .artifactSizeMismatch,
                    .artifactHashMismatch,
                    .incompleteMatrix,
                    .openDesignRequired,
                    .assetRouteBlocked,
                ]
                let terminalStatus: WorkflowRunStatus = invalidEvidenceCodes.contains(record.code) ? .blocked : .partial
                finish(runId: runId, status: terminalStatus, stage: stage, output: workflowEnvelope(runId: runId, stage: stage, status: terminalStatus, outputs: [:], blockedReason: terminalStatus == .blocked ? record.message : nil, error: record))
                return
            } catch {
                finish(runId: runId, status: .partial, stage: stage, output: workflowEnvelope(runId: runId, stage: stage, status: .partial, outputs: [:], error: WorkflowErrorRecord(code: .backendFailure, message: String(describing: error))))
                return
            }
        }
    }

    private func validatedStageStatus(_ output: [String: Any], stage: WorkflowStage) throws -> String {
        guard let status = output["status"] as? String else {
            if stage == .validate {
                guard output["manifestPath"] is String else { throw WorkflowContractError(.invalidEvidence, "workflow_validate must return manifestPath") }
                throw WorkflowContractError(.invalidEvidence, "workflow_validate must return an explicit status")
            }
            return "complete"
        }
        guard ["complete", "partial", "blocked"].contains(status) else { throw WorkflowContractError(.invalidEvidence, "\(stage.rawValue) returned an unsupported status") }
        return status
    }

    private func finish(runId: String, status: WorkflowRunStatus, stage: WorkflowStage, output: Any) {
        queue.sync {
            guard var record = records[runId], record.status == .running else { return }
            record.status = status
            record.stage = stage
            record.latest = output as? [String: Any] ?? workflowEnvelope(runId: runId, stage: stage, status: status, outputs: [:])
            records[runId] = record
            writeCheckpoint(record)
        }
    }

    private func writeCheckpoint(_ record: WorkflowRunRecord) {
        let directory = record.workspaceRoot.appendingPathComponent(".workflow/checkpoints", isDirectory: true)
        let file = directory.appendingPathComponent("\(record.runId).json")
        let payload: [String: Any] = [
            "schemaVersion": WorkflowContractVersion.control,
            "runId": record.runId,
            "workspaceRoot": record.workspaceRoot.path,
            "taskProfile": record.taskProfile,
            "inputs": redactForCheckpoint(record.inputs),
            "stage": record.stage.rawValue,
            "status": record.status.rawValue,
            "completedStages": record.completedStages.map(\.rawValue),
            "previousResults": redactForCheckpoint(record.previousResults.reduce(into: [String: Any]()) { $0[$1.key.rawValue] = $1.value }),
            "latest": redactForCheckpoint(record.latest),
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appendingPathComponent(".\(record.runId).tmp-\(UUID().uuidString)")
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            try FileManager.default.moveItem(at: temporary, to: file)
        } catch { }
    }

    private func loadCheckpoint(runId: String, workspaceRoot: URL) -> WorkflowRunRecord? {
        guard let data = try? Data(contentsOf: workspaceRoot.appendingPathComponent(".workflow/checkpoints/\(runId).json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schemaVersion"] as? String == WorkflowContractVersion.control,
              let taskProfile = object["taskProfile"] as? String,
              let stageName = object["stage"] as? String,
              let stage = WorkflowStage(rawValue: stageName),
              let statusName = object["status"] as? String,
              let status = WorkflowRunStatus(rawValue: statusName),
              let completedNames = object["completedStages"] as? [String]
        else { return nil }
        let completed = completedNames.compactMap(WorkflowStage.init(rawValue:))
        let inputs = object["inputs"] as? [String: Any] ?? [:]
        let previous = (object["previousResults"] as? [String: Any] ?? [:]).reduce(into: [WorkflowStage: [String: Any]]()) { result, entry in
            if let stage = WorkflowStage(rawValue: entry.key), let value = entry.value as? [String: Any] { result[stage] = value }
        }
        return WorkflowRunRecord(runId: runId, workspaceRoot: workspaceRoot, taskProfile: taskProfile, inputs: inputs, status: status, stage: stage, completedStages: completed, previousResults: previous, latest: object["latest"] as? [String: Any] ?? workflowEnvelope(runId: runId, stage: stage, status: status, outputs: [:]))
    }

    private func redactForCheckpoint(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                let key = entry.key.lowercased()
                let sensitiveKey = key.contains("secret") || key.contains("token") || key.contains("password") || key.contains("api_key") || key.contains("apikey") || key == "cookie" || key == "authorization"
                if !sensitiveKey { result[entry.key] = redactForCheckpoint(entry.value) }
            }
        }
        if let array = value as? [Any] { return array.map(redactForCheckpoint) }
        return value
    }
}

public final class WorkflowMCPServer {
    public static let toolNames = ["workflow_preflight", "workflow_search_references", "workflow_prepare_references", "workflow_extract_tokens", "workflow_check_capture_gpu", "workflow_capture_site_motion", "workflow_submit_motion_analysis", "workflow_extract_frames", "workflow_handoff_open_design", "workflow_resolve_asset_routes", "workflow_validate", "workflow_run", "workflow_status", "workflow_resume", "workflow_cancel"]
    private let manager: WorkflowRunManager

    public init(configuration: WorkflowConfiguration, dispatcher: WorkflowStageDispatcher? = nil) throws {
        manager = WorkflowRunManager(dispatcher: try dispatcher ?? ConfiguredChildMCPStageDispatcher(configuration: configuration), defaultWorkspaceRoot: URL(fileURLWithPath: configuration.workspaceRoot))
    }

    public func run() throws {
        while let line = readLine(strippingNewline: true) {
            if let response = handle(line: line), let data = (response + "\n").data(using: .utf8) { FileHandle.standardOutput.write(data) }
        }
    }

    public func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8), let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return error(nil, -32700, "Invalid JSON-RPC payload") }
        let id = payload["id"] ?? NSNull()
        let method = payload["method"] as? String
        let params = payload["params"] as? [String: Any] ?? [:]
        do {
            switch method {
            case "initialize": return try result(id, ["protocolVersion": "2025-03-26", "serverInfo": ["name": "open-computer-use-workflow", "version": "2"], "capabilities": ["tools": ["listChanged": false]]])
            case "notifications/initialized": return nil
            case "ping": return try result(id, [:])
            case "tools/list": return try result(id, ["tools": Self.toolSchemas()])
            case "tools/call": return try call(id, params)
            default: return error(id, -32601, "Method not found: \(method ?? "")")
            }
        } catch let caught { return self.error(id, -32000, String(describing: caught)) }
    }

    private func call(_ id: Any, _ params: [String: Any]) throws -> String {
        guard let name = params["name"] as? String, Self.toolNames.contains(name) else { return error(id, -32602, "Unknown workflow tool") }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        if let version = arguments["schemaVersion"] as? String, version != WorkflowContractVersion.control { return error(id, -32602, "Unsupported workflow control protocol version: \(version)") }
        let runId = arguments["runId"] as? String ?? UUID().uuidString
        switch name {
        case "workflow_run":
            let root = URL(fileURLWithPath: arguments["workspaceRoot"] as? String ?? ".")
            return try result(id, manager.start(runId: runId, workspaceRoot: root, taskProfile: arguments["taskProfile"] as? String ?? "evidence-only", inputs: arguments))
        case "workflow_status": return try result(id, manager.status(runId: runId))
        case "workflow_resume":
            let root = URL(fileURLWithPath: arguments["workspaceRoot"] as? String ?? manager.defaultWorkspaceRoot.path)
            return try result(id, manager.resume(runId: runId, workspaceRoot: root))
        case "workflow_cancel": return try result(id, manager.cancel(runId: runId, reason: arguments["reason"] as? String))
        default:
            let stage = WorkflowStage(rawValue: String(name.dropFirst(9))) ?? .validate
            let context = WorkflowStageContext(runId: runId, workspaceRoot: arguments["workspaceRoot"] as? String ?? ".", taskProfile: arguments["taskProfile"] as? String ?? "evidence-only", inputs: arguments)
            return try result(id, manager.dispatchOne(stage: stage, context: context))
        }
    }

    private static func toolSchemas() -> [[String: Any]] {
        toolNames.map { name in
            let required: [String] = name == "workflow_run" ? ["workspaceRoot", "taskProfile"] : ["workflow_status", "workflow_resume", "workflow_cancel"].contains(name) ? ["runId"] : []
            return ["name": name, "description": "Design-inspiration workflow operation", "inputSchema": ["type": "object", "properties": ["runId": ["type": "string"], "workspaceRoot": ["type": "string"], "taskProfile": ["type": "string"], "schemaVersion": ["type": "string"], "reason": ["type": "string"]], "required": required, "additionalProperties": true]]
        }
    }

    private func result(_ id: Any, _ value: [String: Any]) throws -> String { try encode(["jsonrpc": "2.0", "id": id, "result": value]) }
    private func error(_ id: Any?, _ code: Int, _ message: String) -> String { (try? encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])) ?? "" }
    private func encode(_ value: [String: Any]) throws -> String { String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)! }
}

private func workflowEnvelope(runId: String, stage: WorkflowStage, status: WorkflowRunStatus, outputs: [String: Any], blockedReason: String? = nil, error: WorkflowErrorRecord? = nil) -> [String: Any] {
    var value: [String: Any] = ["schemaVersion": WorkflowContractVersion.control, "runId": runId, "stage": stage.rawValue, "status": status.rawValue, "outputs": outputs, "manifestPath": NSNull(), "gaps": [], "blockedReason": blockedReason ?? NSNull()]
    if let error { value["error"] = ["code": error.code.rawValue, "message": error.message, "backend": error.backend as Any] }
    return value
}
