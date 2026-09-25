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
    var inputs: [String: Any]
    var status: WorkflowRunStatus
    var stage: WorkflowStage
    var completedStages: [WorkflowStage]
    var previousResults: [WorkflowStage: [String: Any]]
    var latest: [String: Any]
    var activeExecutor: Bool
    var pendingActionID: String?
    var approvedActions: Set<String>
}

private final class WorkflowRunManager: @unchecked Sendable {
    static let matrixCells: [[String: String]] = [
        ["cellId": "desktop-full", "viewport": "desktop", "motionMode": "full"],
        ["cellId": "desktop-reduced", "viewport": "desktop", "motionMode": "reduced"],
        ["cellId": "mobile-full", "viewport": "mobile", "motionMode": "full"],
        ["cellId": "mobile-reduced", "viewport": "mobile", "motionMode": "reduced"],
    ]
    private let queue = DispatchQueue(label: "org.opencomputeruse.workflow.run-manager")
    private var records: [String: WorkflowRunRecord] = [:]
    private let dispatcher: WorkflowStageDispatcher
    let defaultWorkspaceRoot: URL

    init(dispatcher: WorkflowStageDispatcher, defaultWorkspaceRoot: URL) {
        self.dispatcher = dispatcher
        self.defaultWorkspaceRoot = defaultWorkspaceRoot
    }

    func start(runId: String, workspaceRoot: URL, taskProfile: String, inputs: [String: Any]) throws -> [String: Any] {
        try validateRunID(runId)
        let workspaceRoot = try validatedWorkspace(workspaceRoot)
        guard let profile = WorkflowTaskProfile(rawValue: taskProfile) else {
            throw WorkflowContractError(.invalidConfiguration, "taskProfile is unsupported")
        }
        try validateRunInputs(profile: profile, inputs: inputs)
        return queue.sync {
            if let existing = records[runId] {
                guard existing.workspaceRoot == workspaceRoot, existing.taskProfile == taskProfile,
                      runInputIdentity(existing.inputs) == runInputIdentity(inputs) else {
                    return workflowEnvelope(runId: runId, stage: .preflight, status: .blocked, outputs: [:], blockedReason: "runId is already bound to different workflow inputs.")
                }
                return existing.latest
            }
            if let checkpoint = loadCheckpoint(runId: runId, workspaceRoot: workspaceRoot) {
                records[runId] = checkpoint
                return checkpoint.latest
            }
            let record = WorkflowRunRecord(runId: runId, workspaceRoot: workspaceRoot, taskProfile: taskProfile, inputs: inputs, status: .running, stage: .preflight, completedStages: [], previousResults: [:], latest: workflowEnvelope(runId: runId, stage: .preflight, status: .running, outputs: [:]), activeExecutor: false, pendingActionID: nil, approvedActions: [])
            records[runId] = record
            writeCheckpoint(record)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.execute(runId: runId) }
            return record.latest
        }
    }

    func status(runId: String) -> [String: Any] {
        guard (try? validateRunID(runId)) != nil else { return workflowEnvelope(runId: runId, stage: .preflight, status: .blocked, outputs: [:], blockedReason: "runId must be a UUID.") }
        return queue.sync {
            if var current = records[runId] {
                if current.status == .partial, current.latest["status"] as? String == "running" {
                    do {
                        try revalidateCheckpointArtifacts(current)
                        current.status = .running
                        current.latest = workflowEnvelope(runId: runId, stage: current.stage, status: .running, outputs: [:])
                        records[runId] = current
                        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.execute(runId: runId) }
                    } catch let error as WorkflowContractError {
                        current.status = .blocked
                        current.latest = workflowEnvelope(runId: runId, stage: current.stage, status: .blocked, outputs: [:], blockedReason: error.message)
                        records[runId] = current
                    } catch {
                        current.status = .blocked
                        current.latest = workflowEnvelope(runId: runId, stage: current.stage, status: .blocked, outputs: [:], blockedReason: String(describing: error))
                        records[runId] = current
                    }
                }
                return current.latest
            }
            guard var recovered = loadCheckpoint(runId: runId, workspaceRoot: defaultWorkspaceRoot) else {
                return workflowEnvelope(runId: runId, stage: .preflight, status: .blocked, outputs: [:], blockedReason: "Unknown workflow run.")
            }
            if recovered.stage == .handoffOpenDesign && !recovered.completedStages.contains(.handoffOpenDesign) {
                let actionID = UUID().uuidString.lowercased()
                recovered.pendingActionID = actionID
                recovered.latest = workflowEnvelope(runId: runId, stage: recovered.stage, status: .partial, outputs: ["actionId": actionID], gaps: [WorkflowGap(code: "approval_required", message: "A new session approval is required before Open Design can resume.", required: true)])
            } else if recovered.latest["status"] as? String == "running" {
                do {
                    try revalidateCheckpointArtifacts(recovered)
                    recovered.status = .running
                    recovered.latest = workflowEnvelope(runId: runId, stage: recovered.stage, status: .running, outputs: [:])
                    records[runId] = recovered
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.execute(runId: runId) }
                    return recovered.latest
                } catch let error as WorkflowContractError {
                    recovered.status = .blocked
                    recovered.latest = workflowEnvelope(runId: runId, stage: recovered.stage, status: .blocked, outputs: [:], blockedReason: error.message)
                } catch {
                    recovered.status = .blocked
                    recovered.latest = workflowEnvelope(runId: runId, stage: recovered.stage, status: .blocked, outputs: [:], blockedReason: String(describing: error))
                }
            }
            records[runId] = recovered
            return recovered.latest
        }
    }

    func resume(runId: String, workspaceRoot: URL, submission: WorkflowResumeSubmission) -> [String: Any] {
        guard (try? validateRunID(runId)) != nil, let workspaceRoot = try? validatedWorkspace(workspaceRoot) else {
            return workflowEnvelope(runId: runId, stage: .preflight, status: .blocked, outputs: [:], blockedReason: "runId or configured workspaceRoot is invalid.")
        }
        return queue.sync {
            guard var record = records[runId] ?? loadCheckpoint(runId: runId, workspaceRoot: workspaceRoot) else {
                return workflowEnvelope(runId: runId, stage: .preflight, status: .blocked, outputs: [:], blockedReason: "Workflow inputs are unavailable for recovery.")
            }
            guard record.workspaceRoot.resolvingSymlinksInPath().standardizedFileURL == workspaceRoot.resolvingSymlinksInPath().standardizedFileURL else {
                return workflowEnvelope(runId: runId, stage: record.stage, status: .blocked, outputs: [:], blockedReason: "workflow_resume cannot change workspaceRoot.")
            }
            guard !record.activeExecutor, record.status == .partial else { return record.latest }
            do {
                try revalidateCheckpointArtifacts(record)
                try apply(submission, to: &record)
            } catch let error as WorkflowContractError {
                record.status = .blocked
                record.latest = workflowEnvelope(runId: runId, stage: record.stage, status: .blocked, outputs: [:], blockedReason: error.message)
                records[runId] = record
                writeCheckpoint(record)
                return record.latest
            } catch {
                return workflowEnvelope(runId: runId, stage: record.stage, status: .blocked, outputs: [:], blockedReason: String(describing: error))
            }
            guard record.status != .blocked, record.status != .cancelled, record.status != .complete else { return record.latest }
            record.status = .running
            record.latest = workflowEnvelope(runId: runId, stage: record.stage, status: .running, outputs: [:], gaps: [])
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
        var arguments = context.arguments(for: stage)
        arguments["runId"] = context.runId
        return try dispatcher.dispatch(stage: stage, arguments: arguments)
    }

    private func captureMatrix(record: WorkflowRunRecord) throws -> [[String: Any]] {
        guard let prepared = record.previousResults[.prepareReferences],
              let liveURL = stringValue(prepared, keys: ["liveUrl", "url"]) else {
            throw WorkflowContractError(.invalidEvidence, "reference preparation did not provide a liveUrl")
        }
        var results = record.previousResults[.captureSiteMotion]?["cells"] as? [[String: Any]] ?? []
        for cell in Self.matrixCells {
            guard let cellId = cell["cellId"], let viewport = cell["viewport"], let motionMode = cell["motionMode"] else { continue }
            if results.contains(where: { $0["cellId"] as? String == cellId }) { continue }
            let width = viewport == "mobile" ? 390 : 1440
            let height = viewport == "mobile" ? 844 : 900
            let cellArguments: [String: Any] = [
                "runId": record.runId,
                "liveUrl": liveURL,
                "cellId": cellId,
                "viewport": viewport,
                "motionMode": motionMode,
                "width": width,
                "height": height,
                "mobile": viewport == "mobile",
                "reducedMotion": motionMode == "reduced",
                "output_dir": record.workspaceRoot.appendingPathComponent("artifacts/design-inspiration/site-motion-capture", isDirectory: true).path,
                "name": "\(record.runId)-\(cellId)",
                "consent_mode": "reject",
                "gpu": true,
                "no_scroll": false,
                "timeout_ms": 180_000,
            ]
            let gpu = try dispatcher.dispatch(stage: .checkCaptureGPU, arguments: cellArguments)
            let gpuStatus = try validatedStageStatus(gpu, stage: .checkCaptureGPU)
            guard gpuStatus == "complete", let gpuCheckID = stringValue(gpu, keys: ["gpuCheckId", "checkId"]) else {
                throw WorkflowContractError(.invalidEvidence, "capture cell \(cellId) did not receive a fresh verified GPU check")
            }
            var captureArguments = cellArguments
            captureArguments["gpuCheckId"] = gpuCheckID
            let capture = try dispatcher.dispatch(stage: .captureSiteMotion, arguments: captureArguments)
            guard try validatedStageStatus(capture, stage: .captureSiteMotion) == "complete" else {
                throw WorkflowContractError(.invalidEvidence, "capture cell \(cellId) is not complete")
            }
            var result = capture
            result["cellId"] = cellId
            result["viewport"] = viewport
            result["motionMode"] = motionMode
            result["gpuCheckId"] = gpuCheckID
            results.append(result)
            queue.sync {
                guard var current = records[record.runId], current.status == .running else { return }
                current.previousResults[.captureSiteMotion] = ["cells": results]
                var gpuChecks: [[String: Any]] = []
                for capture in results {
                    guard let cellId = capture["cellId"], let gpuID = capture["gpuCheckId"] else { continue }
                    gpuChecks.append(["cellId": cellId, "gpuCheckId": gpuID])
                }
                current.previousResults[.checkCaptureGPU] = ["cells": gpuChecks]
                current.stage = .captureSiteMotion
                records[record.runId] = current
                writeCheckpoint(current)
            }
        }
        return results
    }

    private func stringValue(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String { return value }
            if let nested = object[key] as? [String: Any], let value = stringValue(nested, keys: keys) { return value }
            if let nested = object[key] as? [Any] {
                for item in nested {
                    if let dictionary = item as? [String: Any], let value = stringValue(dictionary, keys: keys) { return value }
                }
            }
        }
        return nil
    }

    private func validateRunID(_ runId: String) throws {
        guard let uuid = UUID(uuidString: runId), uuid.uuidString.lowercased() == runId.lowercased() else {
            throw WorkflowContractError(.invalidConfiguration, "runId must be a UUID")
        }
    }

    private func runInputIdentity(_ inputs: [String: Any]) -> String {
        let keys = ["taskProfile", "query", "profileReason", "reference", "designBrief", "projectName"]
        let identity = inputs.filter { keys.contains($0.key) }
        guard JSONSerialization.isValidJSONObject(identity),
              let data = try? JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    private func validatedWorkspace(_ requested: URL) throws -> URL {
        let configured = defaultWorkspaceRoot.resolvingSymlinksInPath().standardizedFileURL
        let supplied = requested.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: configured.path), configured == supplied else {
            throw WorkflowContractError(.artifactOutsideWorkspace, "workspaceRoot must equal the configured workspace root")
        }
        return configured
    }

    private func validateRunInputs(profile: WorkflowTaskProfile, inputs: [String: Any]) throws {
        if profile == .nonvisual {
            guard let reason = inputs["profileReason"] as? String, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  inputs["query"] == nil, inputs["reference"] == nil else {
                throw WorkflowContractError(.invalidConfiguration, "nonvisual requires profileReason and accepts no query or reference")
            }
            return
        }
        if profile == .visualImplementation {
            guard let brief = inputs["designBrief"] as? String, !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowContractError(.invalidConfiguration, "visual-implementation requires an approved designBrief")
            }
        }
        let query = inputs["query"] as? String
        let reference = inputs["reference"] as? [String: Any]
        guard (query != nil) != (reference != nil) else {
            throw WorkflowContractError(.invalidConfiguration, "visual, evidence-only, and token-only runs require exactly one of query or reference")
        }
        if let query {
            let length = query.trimmingCharacters(in: .whitespacesAndNewlines).count
            guard (2...200).contains(length) else { throw WorkflowContractError(.invalidConfiguration, "query must contain 2 to 200 characters") }
        }
        if let reference { try validatePrimaryReference(reference) }
    }

    private func validatePrimaryReference(_ reference: [String: Any]) throws {
        guard Set(reference.keys).isSuperset(of: ["url", "liveUrl", "role", "captureName", "assetRequirements"]),
              let referenceURL = reference["url"] as? String,
              let liveURL = reference["liveUrl"] as? String,
              let role = reference["role"] as? String, !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let captureName = reference["captureName"] as? String,
              captureName.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$", options: .regularExpression) != nil,
              reference["assetRequirements"] is [Any] else {
            throw WorkflowContractError(.invalidEvidence, "reference does not match design_prepare_references input")
        }
        try safePublicHTTPURL(referenceURL, label: "reference.url")
        try safePublicHTTPURL(liveURL, label: "reference.liveUrl")
    }

    private func apply(_ submission: WorkflowResumeSubmission, to record: inout WorkflowRunRecord) throws {
        switch submission {
        case .referenceSelection(let reference):
            guard record.latest["gaps"] as? [[String: Any]] != nil,
                  (record.latest["gaps"] as? [[String: Any]])?.contains(where: { $0["code"] as? String == "reference_selection_required" }) == true else {
                throw WorkflowContractError(.invalidEvidence, "run is not awaiting reference selection")
            }
            try validatePrimaryReference(reference)
            let candidates = record.previousResults[.searchReferences]?["results"] as? [[String: Any]] ?? []
            guard candidates.contains(where: { ($0["link"] as? String) == (reference["url"] as? String) }) else {
                throw WorkflowContractError(.invalidEvidence, "selected reference must match one provisional search result URL")
            }
            record.inputs["reference"] = reference
        case .motionAnalysis(let path, let cellId):
            guard (record.latest["gaps"] as? [[String: Any]])?.contains(where: { $0["code"] as? String == "motion_analysis_required" }) == true else {
                throw WorkflowContractError(.invalidEvidence, "run is not awaiting motion analysis")
            }
            guard isWorkspaceRelative(path), Self.matrixCells.contains(where: { $0["cellId"] == cellId }) else {
                throw WorkflowContractError(.artifactOutsideWorkspace, "motion analysis path and cellId are invalid")
            }
            let file = try workspaceFile(path, root: record.workspaceRoot)
            let data = try Data(contentsOf: file)
            guard let analysis = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw WorkflowContractError(.invalidEvidence, "motion-analysis submission must be a JSON object")
            }
            let checked = try WorkflowEvidenceValidator.validateMotionAnalysis(analysis)
            let source = try requiredObject(analysis, "source")
            guard source["cellId"] as? String == cellId else { throw WorkflowContractError(.invalidEvidence, "motion-analysis cellId does not match submission") }
            guard let cells = record.previousResults[.captureSiteMotion]?["cells"] as? [[String: Any]],
                  let capture = cells.first(where: { $0["cellId"] as? String == cellId }) else {
                throw WorkflowContractError(.invalidEvidence, "motion analysis references an uncaptured cell")
            }
            guard source["captureRunId"] as? String == capture["runId"] as? String else { throw WorkflowContractError(.invalidEvidence, "motion-analysis captureRunId does not match capture") }
            guard let sourcePath = source["artifactPath"] as? String, let sourceHash = source["sha256"] as? String else {
                throw WorkflowContractError(.invalidEvidence, "motion-analysis source requires artifactPath and sha256")
            }
            let artifacts = capture["artifacts"] as? [[String: Any]] ?? []
            guard artifacts.contains(where: { $0["path"] as? String == sourcePath && $0["sha256"] as? String == sourceHash }) else {
                throw WorkflowContractError(.invalidEvidence, "motion-analysis source path and hash do not match capture evidence")
            }
            _ = checked
            var entries = record.inputs["analysisSubmissions"] as? [[String: Any]] ?? []
            guard !entries.contains(where: { $0["cellId"] as? String == cellId }) else { throw WorkflowContractError(.invalidEvidence, "cell already has a motion analysis") }
            entries.append(["cellId": cellId, "path": path])
            record.inputs["analysisSubmissions"] = entries
        case .approval(let actionId, let approved):
            guard let pending = record.pendingActionID, pending == actionId else {
                throw WorkflowContractError(.invalidEvidence, "approval actionId is not pending for this run")
            }
            record.pendingActionID = nil
            if approved { record.approvedActions.insert(actionId) }
            else {
                record.status = .blocked
                record.latest = workflowEnvelope(runId: record.runId, stage: record.stage, status: .blocked, outputs: [:], blockedReason: "Open Design approval was denied.")
            }
        case .assetResults(let path):
            guard isWorkspaceRelative(path) else { throw WorkflowContractError(.artifactOutsideWorkspace, "asset-results path must be workspace-relative") }
            let file = try workspaceFile(path, root: record.workspaceRoot)
            let data = try Data(contentsOf: file)
            guard let results = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw WorkflowContractError(.invalidEvidence, "asset-results file must contain an array")
            }
            let planned = assetIDs(from: record.previousResults[.prepareReferences] ?? [:])
            let actual = Set(results.compactMap { $0["assetId"] as? String })
            guard actual == planned, actual.count == results.count else { throw WorkflowContractError(.invalidEvidence, "asset results must match every prepared asset ID exactly") }
            guard results.allSatisfy({ ["ready", "blocked"].contains($0["status"] as? String ?? "") }) else {
                throw WorkflowContractError(.invalidEvidence, "asset results require explicit ready or blocked status")
            }
            record.inputs["assetResultsPath"] = path
        }
    }

    private func assetIDs(from value: Any) -> Set<String> {
        if let object = value as? [String: Any] {
            if let plan = object["assetPlan"] as? [[String: Any]] { return Set(plan.compactMap { $0["assetId"] as? String }) }
            return object.values.reduce(into: Set<String>()) { $0.formUnion(assetIDs(from: $1)) }
        }
        if let values = value as? [Any] { return values.reduce(into: Set<String>()) { $0.formUnion(assetIDs(from: $1)) } }
        return []
    }

    private func preparedAssetIDs(from value: [String: Any]?) -> Set<String>? {
        guard let plan = value?["assetPlan"] as? [[String: Any]] else { return nil }
        return Set(plan.compactMap { $0["assetId"] as? String })
    }

    private func isWorkspaceRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }

    private func workspaceFile(_ path: String, root: URL) throws -> URL {
        guard isWorkspaceRelative(path) else { throw WorkflowContractError(.artifactOutsideWorkspace, "artifact path must be workspace-relative") }
        let file = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(prefix) else { throw WorkflowContractError(.artifactOutsideWorkspace, "artifact symlink escapes workspace") }
        return file
    }

    private func revalidateCheckpointArtifacts(_ record: WorkflowRunRecord) throws {
        try validateArtifactReferences(record.previousResults, root: record.workspaceRoot)
        for item in record.inputs["analysisSubmissions"] as? [[String: Any]] ?? [] {
            guard let path = item["path"] as? String else { continue }
            let file = try workspaceFile(path, root: record.workspaceRoot)
            let data = try Data(contentsOf: file)
            guard let analysis = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WorkflowContractError(.invalidEvidence, "checkpoint analysis artifact is invalid") }
            _ = try WorkflowEvidenceValidator.validateMotionAnalysis(analysis)
        }
        if let path = record.inputs["assetResultsPath"] as? String {
            let file = try workspaceFile(path, root: record.workspaceRoot)
            let data = try Data(contentsOf: file)
            guard let routes = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw WorkflowContractError(.invalidEvidence, "checkpoint asset-results file is invalid")
            }
            try validateAssetResultRecords(routes, record: record)
        }
    }

    private func validateAssetResultRecords(_ routes: [[String: Any]], record: WorkflowRunRecord) throws {
        let plan = record.previousResults[.prepareReferences]?["assetPlan"] as? [[String: Any]] ?? []
        let expected = Set(plan.compactMap { $0["assetId"] as? String })
        let actual = Set(routes.compactMap { $0["assetId"] as? String })
        guard actual == expected, actual.count == routes.count else {
            throw WorkflowContractError(.invalidEvidence, "asset results do not match the prepared plan")
        }
        for route in routes where route["status"] as? String == "ready" {
            try validateArtifactReferences(route["outputs"] ?? [], root: record.workspaceRoot)
            try validateArtifactReferences(route["validatedOutputs"] ?? [], root: record.workspaceRoot)
        }
    }

    private func validateArtifactReferences(_ value: Any, root: URL) throws {
        if let object = value as? [String: Any] {
            if let path = object["path"] as? String, let hash = object["sha256"] as? String, let size = object["size"] as? Int {
                let file = try workspaceFile(path, root: root)
                let data = try Data(contentsOf: file)
                guard data.count == size, WorkflowSHA256.hexDigest(data) == hash else { throw WorkflowContractError(.artifactHashMismatch, "checkpoint artifact reference failed revalidation") }
            }
            for nested in object.values { try validateArtifactReferences(nested, root: root) }
        } else if let values = value as? [Any] {
            for nested in values { try validateArtifactReferences(nested, root: root) }
        }
    }

    private func composeManifest(record: WorkflowRunRecord) throws -> [String: Any] {
        let prepared = record.previousResults[.prepareReferences] ?? [:]
        let selected = record.inputs["reference"] as? [String: Any] ?? prepared["reference"] as? [String: Any] ?? [:]
        guard let referenceURL = selected["url"] as? String,
              let liveURL = prepared["liveUrl"] as? String ?? prepared["url"] as? String ?? selected["liveUrl"] as? String else {
            throw WorkflowContractError(.invalidEvidence, "workflow manifest requires the selected reference and prepared live URL")
        }
        var reference: [String: Any] = ["url": referenceURL, "liveUrl": liveURL]
        if record.taskProfile == WorkflowTaskProfile.tokenOnly.rawValue {
            let tokenResult = record.previousResults[.extractTokens] ?? [:]
            guard let provenance = tokenResult["tokenProvenance"] as? [String: Any] ?? tokenResult["provenance"] as? [String: Any] else {
                throw WorkflowContractError(.invalidEvidence, "token-only workflow is missing token provenance")
            }
            reference["tokenProvenance"] = provenance
        }

        let captureResult = record.previousResults[.captureSiteMotion] ?? [:]
        let captures = captureResult["cells"] as? [[String: Any]] ?? []
        let analysisSubmissions = record.inputs["analysisSubmissions"] as? [[String: Any]] ?? []
        var matrix: [[String: Any]] = []
        var analyses: [[String: Any]] = []
        var frames: [[String: Any]] = []
        var artifacts: [[String: Any]] = []
        if record.taskProfile == WorkflowTaskProfile.visualImplementation.rawValue || record.taskProfile == WorkflowTaskProfile.evidenceOnly.rawValue {
            for capture in captures {
                guard let cellID = capture["cellId"] as? String,
                      let viewport = capture["viewport"] as? String,
                      let motionMode = capture["motionMode"] as? String,
                      let runID = capture["runId"] as? String,
                      let finalURL = capture["finalUrl"] as? String else {
                    throw WorkflowContractError(.invalidEvidence, "capture output is missing cell metadata")
                }
                let normalizedCaptures = try normalizeArtifacts(capture["artifacts"] as? [[String: Any]] ?? [], root: record.workspaceRoot)
                matrix.append(["cellId": cellID, "viewport": viewport, "motionMode": motionMode, "status": "complete", "width": capture["width"] ?? (viewport == "mobile" ? 390 : 1440), "height": capture["height"] ?? (viewport == "mobile" ? 844 : 900), "runId": runID, "finalUrl": finalURL, "artifacts": normalizedCaptures])

                guard let submission = analysisSubmissions.first(where: { $0["cellId"] as? String == cellID }),
                      let analysisPath = submission["path"] as? String else {
                    throw WorkflowContractError(.invalidEvidence, "workflow is missing motion analysis for \(cellID)")
                }
                let data = try Data(contentsOf: workspaceFile(analysisPath, root: record.workspaceRoot))
                guard let analysis = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw WorkflowContractError(.invalidEvidence, "motion analysis for \(cellID) is invalid")
                }
                _ = try WorkflowEvidenceValidator.validateMotionAnalysis(analysis)
                analyses.append(analysis)
                for moment in analysis["moments"] as? [[String: Any]] ?? [] {
                    guard let path = moment["framePath"] as? String, let hash = moment["frameSha256"] as? String else { continue }
                    let frameArtifact = try artifactReference(path: path, expectedHash: hash, root: record.workspaceRoot)
                    if !artifacts.contains(where: { $0["path"] as? String == frameArtifact["path"] as? String }) { artifacts.append(frameArtifact) }
                    var frame = frameArtifact
                    frame["timestampSeconds"] = moment["timestampSeconds"] ?? 0
                    frames.append(frame)
                }
            }
        }

        var openDesign: [String: Any]
        if record.taskProfile == WorkflowTaskProfile.visualImplementation.rawValue {
            guard let handoff = record.previousResults[.handoffOpenDesign],
                  let design = handoff["designArtifact"] as? [String: Any],
                  let capability = handoff["capability"] as? [String: Any] else {
                throw WorkflowContractError(.invalidEvidence, "Open Design must return a validated artifact and capability evidence")
            }
            let normalized = try normalizeArtifact(design, root: record.workspaceRoot)
            artifacts.append(normalized)
            openDesign = ["status": "used", "designArtifact": normalized, "redactedInputs": handoff["redactedInputs"] as? [String] ?? [liveURL, "design brief", "selected frames"], "capability": capability]
        } else {
            openDesign = ["status": "skipped", "reason": record.inputs["profileReason"] as? String ?? "Not required by task profile.", "exemption": true]
        }

        var assetRoutes: [[String: Any]] = []
        if record.taskProfile == WorkflowTaskProfile.visualImplementation.rawValue {
            guard let planIDs = preparedAssetIDs(from: record.previousResults[.prepareReferences]) else {
                throw WorkflowContractError(.invalidEvidence, "visual workflow is missing a prepared asset plan")
            }
            if planIDs.isEmpty {
                assetRoutes = []
            } else {
            guard let path = record.inputs["assetResultsPath"] as? String else {
                throw WorkflowContractError(.invalidEvidence, "visual workflow is missing parent-authored asset results")
            }
            let data = try Data(contentsOf: workspaceFile(path, root: record.workspaceRoot))
            guard let results = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw WorkflowContractError(.invalidEvidence, "asset results must be a JSON array")
            }
            for var route in results {
                guard route["assetId"] is String, route["requestedRoute"] is String, route["actualRoute"] is String,
                      route["capability"] is [String: Any], route["acceptance"] is [String: Any],
                      let status = route["status"] as? String else {
                    throw WorkflowContractError(.invalidEvidence, "asset route results require capability and acceptance evidence")
                }
                if status == "ready" {
                    route["outputs"] = try normalizeArtifacts(route["outputs"] as? [[String: Any]] ?? [], root: record.workspaceRoot)
                    route["validatedOutputs"] = try normalizeArtifacts(route["validatedOutputs"] as? [[String: Any]] ?? [], root: record.workspaceRoot)
                }
                assetRoutes.append(route)
            }
            }
        }

        let isCaptureProfile = record.taskProfile == WorkflowTaskProfile.visualImplementation.rawValue || record.taskProfile == WorkflowTaskProfile.evidenceOnly.rawValue
        var manifest: [String: Any] = [
            "schemaVersion": WorkflowContractVersion.manifest,
            "taskProfile": record.taskProfile,
            "workspace": ["root": record.workspaceRoot.path],
            "reference": reference,
            "capture": ["matrix": matrix],
            "artifacts": artifacts,
            "analysis": ["entries": analyses],
            "frames": frames,
            "openDesign": openDesign,
            "assetRoutes": assetRoutes,
            "status": isCaptureProfile && captures.count != 4 ? "partial" : "complete",
        ]
        if let reason = record.inputs["profileReason"] as? String { manifest["profileReason"] = reason }
        return manifest
    }

    private func normalizeArtifacts(_ values: [[String: Any]], root: URL) throws -> [[String: Any]] {
        try values.map { try normalizeArtifact($0, root: root) }
    }

    private func normalizeArtifact(_ value: [String: Any], root: URL) throws -> [String: Any] {
        guard let path = value["path"] as? String else { throw WorkflowContractError(.invalidEvidence, "artifact is missing path") }
        return try artifactReference(path: path, expectedHash: value["sha256"] as? String, expectedSize: value["size"] as? Int, root: root, kind: value["kind"] as? String)
    }

    private func artifactReference(path: String, expectedHash: String?, expectedSize: Int? = nil, root: URL, kind: String? = nil) throws -> [String: Any] {
        let source = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        let file = source.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard file.path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else {
            throw WorkflowContractError(.artifactOutsideWorkspace, "artifact path escapes the configured workspace")
        }
        let data = try Data(contentsOf: file)
        let hash = WorkflowSHA256.hexDigest(data)
        guard !data.isEmpty, expectedHash == nil || hash == expectedHash, expectedSize == nil || data.count == expectedSize else {
            throw WorkflowContractError(.artifactHashMismatch, "artifact size or hash does not match bytes")
        }
        var result: [String: Any] = ["path": String(file.path.dropFirst(rootPath.count + 1)), "size": data.count, "sha256": hash, "nonEmpty": true]
        if let kind { result["kind"] = kind }
        return result
    }

    private func requiredObject(_ object: [String: Any], _ key: String) throws -> [String: Any] {
        guard let value = object[key] as? [String: Any] else { throw WorkflowContractError(.invalidEvidence, "\(key) must be an object") }
        return value
    }

    private func safePublicHTTPURL(_ value: String, label: String) throws {
        guard let components = URLComponents(string: value), ["https", "http"].contains(components.scheme?.lowercased() ?? ""), components.host != nil, components.user == nil, components.password == nil else {
            throw WorkflowContractError(.invalidEvidence, "\(label) must be a public HTTP(S) URL without credentials")
        }
        let host = (components.host ?? "").lowercased()
        guard host != "localhost", host != "localhost.localdomain", !host.hasSuffix(".local") else {
            throw WorkflowContractError(.invalidEvidence, "\(label) must not target a private host")
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 {
            let a = octets[0], b = octets[1]
            let privateAddress = a == 0 || a == 10 || a == 127 || (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) || (a == 192 && (b == 0 || b == 168)) || a >= 224
            guard !privateAddress else { throw WorkflowContractError(.invalidEvidence, "\(label) must not target a private host") }
        }
        if host.contains(":") {
            guard host != "::1", !host.hasPrefix("fc"), !host.hasPrefix("fd"), !host.hasPrefix("fe80"), !host.hasPrefix("::ffff:") else {
                throw WorkflowContractError(.invalidEvidence, "\(label) must not target a private host")
            }
        }
    }

    private func execute(runId: String) {
        let acquired = queue.sync { () -> Bool in
            guard var record = records[runId], record.status == .running, !record.activeExecutor else { return false }
            record.activeExecutor = true
            records[runId] = record
            return true
        }
        guard acquired else { return }
        defer { queue.sync { if var record = records[runId] { record.activeExecutor = false; records[runId] = record } } }
        while true {
            guard let record = queue.sync(execute: { records[runId] }), record.status == .running else { return }
            guard let profile = WorkflowTaskProfile(rawValue: record.taskProfile) else {
                finish(runId: runId, status: .blocked, stage: record.stage, output: workflowEnvelope(runId: runId, stage: record.stage, status: .blocked, outputs: [:], blockedReason: "Unsupported task profile."))
                return
            }
            let preparedAssetIDs = preparedAssetIDs(from: record.previousResults[.prepareReferences])
            let stages = profile.stages(preparedAssetIDs: preparedAssetIDs).filter {
                !($0 == .searchReferences && record.inputs["reference"] != nil)
                    && !($0 == .extractTokens && profile == .visualImplementation && (record.inputs["reference"] as? [String: Any])?["extractTokens"] as? Bool != true)
            }
            guard let stage = stages.first(where: { !record.completedStages.contains($0) }) else {
                let completed = record.taskProfile == WorkflowTaskProfile.nonvisual.rawValue || record.completedStages.contains(.validate)
                finish(runId: runId, status: completed ? .complete : .blocked, stage: record.stage, output: workflowEnvelope(runId: runId, stage: record.stage, status: completed ? .complete : .blocked, outputs: record.previousResults[.validate] ?? [:], blockedReason: completed ? nil : "workflow_validate did not complete"))
                return
            }
            let context = WorkflowStageContext(runId: record.runId, workspaceRoot: record.workspaceRoot.path, taskProfile: record.taskProfile, inputs: record.inputs, previousResults: record.previousResults)
            do {
                if stage == .checkCaptureGPU {
                    let output = try captureMatrix(record: record)
                    queue.sync {
                        guard var current = records[runId], current.status == .running else { return }
                        current.completedStages.append(.checkCaptureGPU)
                        current.completedStages.append(.captureSiteMotion)
                        current.previousResults[.checkCaptureGPU] = ["cells": output]
                        current.previousResults[.captureSiteMotion] = ["cells": output]
                        current.stage = .captureSiteMotion
                        records[runId] = current
                        writeCheckpoint(current)
                    }
                    continue
                }
                if stage == .submitMotionAnalysis {
                    let submissions = record.inputs["analysisSubmissions"] as? [[String: Any]] ?? []
                    if submissions.count < 4 {
                        let waitingCell = Self.matrixCells.first { cell in
                            guard let cellID = cell["cellId"] else { return false }
                            return !submissions.contains { $0["cellId"] as? String == cellID }
                        }
                        let gap = WorkflowGap(code: "motion_analysis_required", message: "Submit one validated motion analysis for each capture cell.", required: true)
                        finish(runId: runId, status: .partial, stage: stage, output: workflowEnvelope(runId: runId, stage: stage, status: .partial, outputs: ["nextCellId": waitingCell?["cellId"] ?? NSNull()], gaps: [gap]))
                        return
                    }
                    queue.sync {
                        guard var current = records[runId], current.status == .running else { return }
                        current.completedStages.append(stage)
                        current.previousResults[stage] = ["analyses": submissions.map { ["cellId": $0["cellId"]!, "path": $0["path"]!] }]
                        current.stage = stage
                        records[runId] = current
                        writeCheckpoint(current)
                    }
                    continue
                }
                if stage == .extractFrames {
                    let submissions = record.inputs["analysisSubmissions"] as? [[String: Any]] ?? []
                    var frames: [[String: Any]] = []
                    for item in submissions {
                        guard let path = item["path"] as? String, let cellId = item["cellId"] as? String else { continue }
                        let analysisURL = try workspaceFile(path, root: record.workspaceRoot)
                        let data = try Data(contentsOf: analysisURL)
                        guard let analysis = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let source = analysis["source"] as? [String: Any],
                              let sourcePath = source["artifactPath"] as? String,
                              let moments = analysis["moments"] as? [[String: Any]] else {
                            throw WorkflowContractError(.invalidEvidence, "motion analysis does not contain frame extraction inputs for \(cellId)")
                        }
                        _ = try workspaceFile(sourcePath, root: record.workspaceRoot)
                        let extractionArguments: [String: Any] = [
                            "analysisPath": path,
                            "path": sourcePath,
                            "sourcePath": sourcePath,
                            "cellId": cellId,
                            "timestamps": moments.compactMap { $0["timestampSeconds"] },
                            "output_dir": record.workspaceRoot.appendingPathComponent("artifacts/design-inspiration/site-motion-capture/frames", isDirectory: true).path,
                        ]
                        let output = try dispatcher.dispatch(stage: .extractFrames, arguments: extractionArguments)
                        guard try validatedStageStatus(output, stage: .extractFrames) == "complete" else {
                            throw WorkflowContractError(.invalidEvidence, "frame extraction did not complete for \(cellId)")
                        }
                        if let extracted = output["frames"] as? [[String: Any]] { frames.append(contentsOf: extracted) }
                    }
                    queue.sync {
                        guard var current = records[runId], current.status == .running else { return }
                        current.completedStages.append(stage)
                        current.previousResults[stage] = ["frames": frames]
                        current.stage = stage
                        records[runId] = current
                        writeCheckpoint(current)
                    }
                    continue
                }
                if stage == .handoffOpenDesign && record.approvedActions.isEmpty {
                    let actionID = record.pendingActionID ?? UUID().uuidString.lowercased()
                    queue.sync {
                        guard var current = records[runId], current.status == .running else { return }
                        current.pendingActionID = actionID
                        current.stage = stage
                        let gap = WorkflowGap(code: "approval_required", message: "Approve the Open Design provider action before it starts.", required: true)
                        current.latest = workflowEnvelope(runId: runId, stage: stage, status: .partial, outputs: ["actionId": actionID], gaps: [gap])
                        current.status = .partial
                        records[runId] = current
                        writeCheckpoint(current)
                    }
                    return
                }
                if stage == .validate, record.taskProfile == WorkflowTaskProfile.visualImplementation.rawValue,
                   preparedAssetIDs?.isEmpty == false, record.inputs["assetResultsPath"] == nil {
                    let gap = WorkflowGap(code: "asset_results_required", message: "Submit validated parent-authored results for every prepared asset route.", required: true)
                    finish(runId: runId, status: .partial, stage: stage, output: workflowEnvelope(runId: runId, stage: stage, status: .partial, outputs: [:], gaps: [gap]))
                    return
                }
                if stage == .validate {
                    let manifest = try composeManifest(record: record)
                    let manifestDirectory = record.workspaceRoot.appendingPathComponent(".workflow/manifests", isDirectory: true)
                    try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
                    let manifestURL = manifestDirectory.appendingPathComponent("\(record.runId).json")
                    let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
                    try manifestData.write(to: manifestURL, options: .atomic)
                    let preparedResult = record.previousResults[.prepareReferences] ?? [:]
                    let preparedPlan = preparedResult["assetPlan"] as? [[String: Any]] ?? []
                    let expectedIDs = Set(preparedPlan.compactMap { $0["assetId"] as? String })
                    let report = try WorkflowEvidenceValidator.validateManifest(data: manifestData, workspaceRoot: record.workspaceRoot, expectedAssetIDs: record.taskProfile == WorkflowTaskProfile.visualImplementation.rawValue ? expectedIDs : nil)
                    let output: [String: Any] = ["stage": stage.rawValue, "status": report.manifestStatus.rawValue, "manifestPath": manifestURL.path, "captureCellCount": report.captureCellCount, "analysisCount": report.analysisCount, "readyAssetRouteCount": report.readyAssetRouteCount]
                    queue.sync {
                        guard var current = records[runId], current.status == .running else { return }
                        current.completedStages.append(stage)
                        current.previousResults[stage] = output
                        current.stage = stage
                        records[runId] = current
                        writeCheckpoint(current)
                    }
                    continue
                }
                var stageArguments = context.arguments(for: stage)
                stageArguments["runId"] = record.runId
                let output = try dispatcher.dispatch(stage: stage, arguments: stageArguments)
                let status = try validatedStageStatus(output, stage: stage)
                if stage == .searchReferences {
                    let candidates = output["results"] as? [[String: Any]] ?? []
                    if candidates.isEmpty {
                        let reason = output["reasonCode"] as? String ?? "search.no_results"
                        let error = WorkflowErrorRecord(code: .invalidEvidence, message: "Reference search returned no selectable results (\(reason)).")
                        finish(runId: runId, status: .blocked, stage: stage, output: workflowEnvelope(runId: runId, stage: stage, status: .blocked, outputs: output, blockedReason: error.message, error: error))
                        return
                    }
                    if status == "complete" || status == "partial" {
                        queue.sync {
                            guard var current = records[runId], current.status == .running else { return }
                            current.completedStages.append(stage)
                            current.previousResults[stage] = output
                            current.stage = stage
                            records[runId] = current
                            writeCheckpoint(current)
                        }
                        let gap = WorkflowGap(code: "reference_selection_required", message: "Choose exactly one primary reference from the provisional search results.", required: true)
                        finish(runId: runId, status: .partial, stage: stage, output: workflowEnvelope(runId: runId, stage: stage, status: .partial, outputs: output, gaps: [gap]))
                        return
                    }
                }
                if status != "complete" {
                    let runStatus = WorkflowRunStatus(rawValue: status) ?? .blocked
                    finish(runId: runId, status: runStatus, stage: stage, output: output)
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
        if status == "verified" {
            guard stage == .checkCaptureGPU, stringValue(output, keys: ["gpuCheckId", "checkId"]) != nil else { throw WorkflowContractError(.invalidEvidence, "GPU verification must return a fresh check ID") }
            return "complete"
        }
        if status == "ready" {
            guard stage == .prepareReferences, stringValue(output, keys: ["liveUrl"]) != nil else { throw WorkflowContractError(.invalidEvidence, "reference preparation did not return a verified liveUrl") }
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
            "inputs": checkpointInputs(record.inputs),
            "stage": record.stage.rawValue,
            "status": record.status.rawValue,
            "completedStages": record.completedStages.map(\.rawValue),
            "previousResults": checkpointMetadata(record.previousResults.reduce(into: [String: Any]()) { $0[$1.key.rawValue] = $1.value }),
            "latest": checkpointMetadata(record.latest),
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
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
              let completedNames = object["completedStages"] as? [String],
              (object["workspaceRoot"] as? String).map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL == workspaceRoot.resolvingSymlinksInPath().standardizedFileURL }) == true
        else { return nil }
        let completed = completedNames.compactMap(WorkflowStage.init(rawValue:))
        let inputs = object["inputs"] as? [String: Any] ?? [:]
        let previous = (object["previousResults"] as? [String: Any] ?? [:]).reduce(into: [WorkflowStage: [String: Any]]()) { result, entry in
            if let stage = WorkflowStage(rawValue: entry.key), let value = entry.value as? [String: Any] { result[stage] = value }
        }
        return WorkflowRunRecord(runId: runId, workspaceRoot: workspaceRoot, taskProfile: taskProfile, inputs: inputs, status: status == .running ? .partial : status, stage: stage, completedStages: completed, previousResults: previous, latest: object["latest"] as? [String: Any] ?? workflowEnvelope(runId: runId, stage: stage, status: .partial, outputs: [:]), activeExecutor: false, pendingActionID: nil, approvedActions: [])
    }

    private func checkpointInputs(_ inputs: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in ["query", "profileReason", "reference", "analysisSubmissions", "assetResultsPath", "manifestPath", "designBrief", "projectName", "taskProfile"] {
            if let value = inputs[key] { result[key] = checkpointMetadata(value) }
        }
        return result
    }

    private func checkpointMetadata(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                let allowed: Set<String> = ["schemaVersion", "runId", "stage", "status", "reasonCode", "cellId", "viewport", "motionMode", "width", "height", "url", "liveUrl", "path", "sha256", "size", "kind", "manifestPath", "gpuCheckId", "checkId", "assetId", "assetPlan", "captureName", "role", "assetRequirements", "analysisSubmissions", "required", "code", "message", "nextCellId", "outputs", "gaps", "blockedReason", "backend", "tool", "cells", "analyses", "reference", "references", "results", "title", "link", "finalUrl", "files", "artifacts", "validation", "media", "jank", "format", "durationSeconds", "videoStreamCount", "cleanup", "evidence", "gpu", "egress", "egressAttestation", "schemaVersion", "controls", "direct", "proxied", "runnerInstanceId", "browserExecutable", "browserVersion", "captureRuntime", "captureRuntimeVersion", "browserUseVersion", "checkedAt", "expiresAt", "passed", "blocked", "consent", "scroll", "interactionFailures", "blindSpots", "verified", "approvedHost", "networkNamespaceInode", "directEgressBlocked", "approvedProxyProbe", "boundaryId", "proxyPolicy", "requested", "completed", "truncated", "preferredFormats", "preferredTool", "delivery", "prompt", "requires3d", "extractTokens", "id", "name", "type", "source", "provenance", "timestampSeconds", "framePath", "frameSha256", "reason", "severity", "observerError", "capability", "redactedInputs", "projectId", "requestId", "designArtifact", "acceptance", "outputs", "validatedOutputs", "actualRoute", "requestedRoute", "reducedMotion", "staticFallback"]
                if allowed.contains(entry.key) && entry.key != "actionId" { result[entry.key] = checkpointMetadata(entry.value) }
            }
        }
        if let array = value as? [Any] { return array.map(checkpointMetadata) }
        if let string = value as? String, string.lowercased().contains("token=") || string.lowercased().contains("api_key=") { return "[REDACTED]" }
        if value is String || value is NSNumber || value is NSNull { return value }
        return NSNull()
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
            guard let workspace = arguments["workspaceRoot"] as? String, let profile = arguments["taskProfile"] as? String else { return error(id, -32602, "workflow_run requires workspaceRoot and taskProfile") }
            return try toolResult(id, manager.start(runId: runId, workspaceRoot: URL(fileURLWithPath: workspace), taskProfile: profile, inputs: arguments))
        case "workflow_status": return try toolResult(id, manager.status(runId: runId))
        case "workflow_resume":
            let root = URL(fileURLWithPath: arguments["workspaceRoot"] as? String ?? manager.defaultWorkspaceRoot.path)
            guard let rawSubmission = arguments["submission"] else { return error(id, -32602, "workflow_resume requires submission") }
            return try toolResult(id, manager.resume(runId: runId, workspaceRoot: root, submission: WorkflowResumeSubmission.decode(rawSubmission)))
        case "workflow_cancel": return try toolResult(id, manager.cancel(runId: runId, reason: arguments["reason"] as? String))
        default:
            let stage = WorkflowStage(rawValue: String(name.dropFirst(9))) ?? .validate
            let context = WorkflowStageContext(runId: runId, workspaceRoot: arguments["workspaceRoot"] as? String ?? ".", taskProfile: arguments["taskProfile"] as? String ?? "evidence-only", inputs: arguments)
            return try toolResult(id, manager.dispatchOne(stage: stage, context: context))
        }
    }

    private static func toolSchemas() -> [[String: Any]] {
        toolNames.map { name in
            var required: [String] = []
            if name == "workflow_run" { required = ["runId", "workspaceRoot", "taskProfile"] }
            if ["workflow_status", "workflow_resume", "workflow_cancel"].contains(name) { required = ["runId"] }
            if name == "workflow_resume" { required.append("submission") }
            let properties: [String: Any] = [
                "runId": ["type": "string", "format": "uuid"],
                "workspaceRoot": ["type": "string"],
                "taskProfile": ["type": "string", "enum": WorkflowTaskProfile.allCases.map(\.rawValue)],
                "query": ["type": "string", "minLength": 2, "maxLength": 200],
                "reference": ["type": "object"],
                "profileReason": ["type": "string", "minLength": 1],
                "designBrief": ["type": "string"],
                "projectName": ["type": "string"],
                "manifestPath": ["type": "string"],
                "assetResultsPath": ["type": "string"],
                "reason": ["type": "string"],
                "url": ["type": "string"],
                "liveUrl": ["type": "string"],
                "cellId": ["type": "string"],
                "viewport": ["type": "string", "enum": ["desktop", "mobile"]],
                "motionMode": ["type": "string", "enum": ["full", "reduced"]],
                "width": ["type": "integer", "minimum": 1],
                "height": ["type": "integer", "minimum": 1],
                "mobile": ["type": "boolean"],
                "reduced_motion": ["type": "boolean"],
                "gpuCheckId": ["type": "string"],
                "consent_mode": ["type": "string"],
                "output_dir": ["type": "string"],
                "name": ["type": "string"],
                "gpu": ["type": "boolean"],
                "no_scroll": ["type": "boolean"],
                "timeout_ms": ["type": "integer", "minimum": 1],
                "path": ["type": "string"],
                "cell_id": ["type": "string"],
                "expectedAssetIDs": ["type": "array", "items": ["type": "string"]],
                "schemaVersion": ["type": "string", "const": WorkflowContractVersion.control],
                "submission": ["oneOf": [
                    ["type": "object", "required": ["kind", "reference"], "properties": ["kind": ["const": "reference-selection"], "reference": ["type": "object"]], "additionalProperties": false],
                    ["type": "object", "required": ["kind", "path", "cellId"], "properties": ["kind": ["const": "motion-analysis"], "path": ["type": "string"], "cellId": ["type": "string"]], "additionalProperties": false],
                    ["type": "object", "required": ["kind", "actionId", "approved"], "properties": ["kind": ["const": "approval"], "actionId": ["type": "string"], "approved": ["type": "boolean"]], "additionalProperties": false],
                    ["type": "object", "required": ["kind", "path"], "properties": ["kind": ["const": "asset-results"], "path": ["type": "string"]], "additionalProperties": false],
                ]],
            ]
            return ["name": name, "description": "Design-inspiration workflow operation", "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
        }
    }

    private func result(_ id: Any, _ value: [String: Any]) throws -> String { try encode(["jsonrpc": "2.0", "id": id, "result": value]) }
    private func toolResult(_ id: Any, _ value: [String: Any]) throws -> String {
        let text = try encode(value)
        return try encode(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": text]], "isError": false]])
    }
    private func error(_ id: Any?, _ code: Int, _ message: String) -> String { (try? encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])) ?? "" }
    private func encode(_ value: [String: Any]) throws -> String { String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)! }
}

private func workflowEnvelope(runId: String, stage: WorkflowStage, status: WorkflowRunStatus, outputs: [String: Any], blockedReason: String? = nil, error: WorkflowErrorRecord? = nil, gaps: [WorkflowGap] = []) -> [String: Any] {
    var value: [String: Any] = ["schemaVersion": WorkflowContractVersion.control, "runId": runId, "stage": stage.rawValue, "status": status.rawValue, "outputs": outputs, "manifestPath": NSNull(), "gaps": gaps.map { ["code": $0.code, "message": $0.message, "required": $0.required] }, "blockedReason": blockedReason ?? NSNull()]
    if let error { value["error"] = ["code": error.code.rawValue, "message": error.message, "backend": error.backend as Any] }
    return value
}
