import Foundation

public enum WorkflowStageDispatchError: Error, LocalizedError, Equatable, Sendable {
    case missingBackend(WorkflowBackendKind, WorkflowStage)
    case missingTool(WorkflowBackendKind, String, WorkflowStage)
    case backend(WorkflowErrorRecord)

    public var errorDescription: String? {
        switch self {
        case .missingBackend(let kind, let stage): "No \(kind.rawValue) backend is configured for \(stage.rawValue)."
        case .missingTool(let kind, let tool, let stage): "The \(kind.rawValue) backend does not declare \(tool) for \(stage.rawValue)."
        case .backend(let record): record.message
        }
    }
}

public final class ConfiguredChildMCPStageDispatcher: WorkflowStageDispatcher {
    private struct Route { let kind: WorkflowBackendKind; let tool: String }
    private let configuration: WorkflowConfiguration
    private let environment: [String: String]
    private let routes: [WorkflowStage: Route] = [
        .searchReferences: Route(kind: .designInspiration, tool: "design_search_references"),
        .prepareReferences: Route(kind: .designInspiration, tool: "design_prepare_references"),
        .extractTokens: Route(kind: .designInspiration, tool: "design_extract_tokens"),
        .submitMotionAnalysis: Route(kind: .motionAnalysis, tool: "submit_motion_analysis"),
        .extractFrames: Route(kind: .frameExtraction, tool: "extract_frames"),
        .handoffOpenDesign: Route(kind: .openDesign, tool: "start_run"),
        .resolveAssetRoutes: Route(kind: .assetRouting, tool: "resolve_asset_routes"),
    ]
    private var transports: [String: ChildMCPTransport] = [:]
    private var openDesignRuns: [String: (runID: String, backend: WorkflowBackendConfiguration)] = [:]
    private let lock = NSLock()

    public init(configuration: WorkflowConfiguration, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        try configuration.validate()
        self.configuration = configuration
        self.environment = environment
    }

    public func dispatch(stage: WorkflowStage, arguments: [String: Any]) throws -> [String: Any] {
        if stage == .preflight {
            if arguments["requiresCapture"] as? Bool == true,
               configuration.captureBackend ?? .browserUseCapture == .browserUseCapture {
                guard let backend = configuration.backends.first(where: { $0.kind == .browserUseCapture }) else {
                    throw WorkflowStageDispatchError.missingBackend(.browserUseCapture, .preflight)
                }
                let requiredTools: Set<String> = ["check_capture_gpu", "capture_site_motion"]
                guard Set(backend.declaredTools) == requiredTools else {
                    throw WorkflowStageDispatchError.missingTool(.browserUseCapture, "check_capture_gpu and capture_site_motion", .preflight)
                }
            }
            return ["stage": stage.rawValue, "status": "complete", "workspaceRoot": configuration.workspaceRoot]
        }
        if stage == .validate {
            guard let manifestPath = arguments["manifestPath"] as? String else {
                throw WorkflowStageDispatchError.backend(WorkflowErrorRecord(code: .invalidEvidence, message: "workflow_validate requires manifestPath"))
            }
            let manifestURL = URL(fileURLWithPath: manifestPath)
            guard let data = try? Data(contentsOf: manifestURL) else {
                throw WorkflowStageDispatchError.backend(WorkflowErrorRecord(code: .artifactMissing, message: "workflow manifest does not exist: \(manifestPath)"))
            }
            let expectedIDs = Set(arguments["expectedAssetIDs"] as? [String] ?? [])
            let report = try WorkflowEvidenceValidator.validateManifest(data: data, workspaceRoot: URL(fileURLWithPath: configuration.workspaceRoot), expectedAssetIDs: expectedIDs)
            return [
                "stage": stage.rawValue,
                "status": report.manifestStatus.rawValue,
                "captureCellCount": report.captureCellCount,
                "analysisCount": report.analysisCount,
                "readyAssetRouteCount": report.readyAssetRouteCount,
                "manifestPath": manifestPath,
            ]
        }
        guard let route = route(for: stage) else { throw WorkflowStageDispatchError.missingBackend(.designInspiration, stage) }
        guard let backend = configuration.backends.first(where: { $0.kind == route.kind }) else {
            throw WorkflowStageDispatchError.missingBackend(route.kind, stage)
        }
        guard backend.declaredTools.contains(route.tool) else {
            throw WorkflowStageDispatchError.missingTool(route.kind, route.tool, stage)
        }
        do {
            let child = try transport(for: backend, runId: arguments["runId"] as? String ?? "default")
            if stage == .handoffOpenDesign {
                return try runOpenDesign(arguments: arguments, backend: backend, transport: child)
            }
            var stageArguments = arguments
            if stage == .prepareReferences, let reference = stageArguments.removeValue(forKey: "reference") {
                stageArguments["references"] = [reference]
            }
            if stage == .extractTokens {
                let reference = arguments["reference"] as? [String: Any] ?? [:]
                stageArguments["url"] = reference["url"]
                stageArguments.removeValue(forKey: "liveUrl")
            }
            for internalKey in ["runId", "workspaceRoot", "taskProfile", "stage", "previousResults", "workflowRunId"] {
                stageArguments.removeValue(forKey: internalKey)
            }
            stageArguments = normalizeBackendAliases(stageArguments)
            if stage == .resolveAssetRoutes { stageArguments["routeContractVersion"] = "asset-route.v1" }
            stageArguments = projectArguments(stageArguments, tool: route.tool, transport: child)
            let result = try child.callTool(route.tool, arguments: try jsonValue(stageArguments))
            if case .object(let object) = result,
               object["isError"]?.boolValue == true {
                throw WorkflowStageDispatchError.backend(WorkflowErrorRecord(code: .backendFailure, message: "\(route.tool) returned isError", backend: backend.kind.rawValue))
            }
            var output: [String: Any] = ["stage": stage.rawValue, "backend": route.kind.rawValue, "tool": route.tool, "result": result.foundationObject]
            if case .object(let object) = result, let structured = object["structuredContent"]?.foundationObject as? [String: Any] {
                let promoted: Set<String> = ["status", "reasonCode", "manifestPath", "liveUrl", "url", "checkId", "gpuCheckId", "references", "results", "count", "assetPlan", "failures", "path", "sha256", "size", "artifacts", "captureRunId", "cellId", "viewport", "motionMode", "finalUrl", "runId", "projectId"]
                for key in promoted { if let value = structured[key] { output[key] = value } }
            }
            return output
        } catch let error as ChildMCPTransportError {
            throw WorkflowStageDispatchError.backend(WorkflowErrorRecord(code: .backendFailure, message: error.localizedDescription, backend: backend.kind.rawValue))
        }
    }

    public func shutdown() {
        lock.lock(); let active = Array(transports.values); transports.removeAll(); lock.unlock()
        active.forEach { try? $0.shutdown() }
    }

    public func cancel(runId: String) {
        lock.lock()
        let active = transports.filter { $0.key.hasPrefix("\(runId)::") }.map(\.value)
        let openDesign = openDesignRuns[runId]
        openDesignRuns.removeValue(forKey: runId)
        lock.unlock()
        if let openDesign, let cancellation = try? transport(for: openDesign.backend, runId: "\(runId)::cancel") {
            let arguments = projectArguments(["runId": openDesign.runID], tool: "cancel_run", transport: cancellation)
            _ = try? cancellation.callTool("cancel_run", arguments: (try? jsonValue(arguments)) ?? .object([:]))
            try? cancellation.shutdown()
        }
        active.forEach { $0.cancel() }
    }

    deinit { shutdown() }

    private func route(for stage: WorkflowStage) -> Route? {
        switch stage {
        case .checkCaptureGPU:
            return Route(kind: configuration.captureBackend ?? .browserUseCapture, tool: "check_capture_gpu")
        case .captureSiteMotion:
            return Route(kind: configuration.captureBackend ?? .browserUseCapture, tool: "capture_site_motion")
        default:
            return routes[stage]
        }
    }

    private func transport(for backend: WorkflowBackendConfiguration, runId: String) throws -> ChildMCPTransport {
        let key = "\(runId)::\(backend.kind.rawValue)"
        lock.lock(); if let existing = transports[key] { lock.unlock(); return existing }; lock.unlock()
        let child = try ChildMCPTransport(configuration: ChildMCPBackendConfiguration(
            identifier: backend.kind.rawValue,
            executableURL: URL(fileURLWithPath: backend.command),
            arguments: backend.arguments,
            workingDirectoryURL: backend.workingDirectory.map(URL.init(fileURLWithPath:)),
            permittedEnvironmentVariableNames: Set(backend.permittedEnvironmentVariables),
            declaredToolNames: Set(backend.declaredTools),
            timeouts: ChildMCPTimeouts(request: backend.kind == .browserUseCapture || backend.kind == .siteMotionCapture ? 300 : backend.kind == .openDesign ? 900 : 60)
        ))
        try child.start(environment: environment)
        lock.lock(); transports[key] = child; lock.unlock()
        return child
    }

    private func normalizeBackendAliases(_ values: [String: Any]) -> [String: Any] {
        var result = values
        if let mode = result.removeValue(forKey: "motionMode") as? String, result["reduced_motion"] == nil {
            result["reduced_motion"] = mode == "reduced"
        }
        if let reduced = result.removeValue(forKey: "reducedMotion"), result["reduced_motion"] == nil {
            result["reduced_motion"] = reduced
        }
        let aliases = ["liveUrl": "url", "gpuCheckId": "gpu_check_id", "analysisPath": "path"]
        for (source, destination) in aliases where result[destination] == nil {
            result[destination] = result[source]
            result.removeValue(forKey: source)
        }
        return result
    }

    private func projectArguments(_ values: [String: Any], tool: String, transport: ChildMCPTransport) -> [String: Any] {
        guard let definition = transport.discoveredTools.first(where: { $0.name == tool })?.definition.foundationObject as? [String: Any],
              let schema = definition["inputSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: Any] else { return values }
        return values.filter { properties[$0.key] != nil }
    }

    private func requiredArguments(tool: String, values: [String: Any], transport: ChildMCPTransport) throws -> [String: Any] {
        guard let definition = transport.discoveredTools.first(where: { $0.name == tool })?.definition.foundationObject as? [String: Any],
              let schema = definition["inputSchema"] as? [String: Any] else {
            throw WorkflowStageDispatchError.backend(WorkflowErrorRecord(code: .backendUnavailable, message: "Open Design did not publish an input schema for \(tool).", backend: WorkflowBackendKind.openDesign.rawValue))
        }
        let projected = projectArguments(values, tool: tool, transport: transport)
        let missing = (schema["required"] as? [String] ?? []).filter { projected[$0] == nil }
        guard missing.isEmpty else {
            throw WorkflowStageDispatchError.backend(WorkflowErrorRecord(code: .invalidConfiguration, message: "Open Design \(tool) requires unsupported inputs: \(missing.joined(separator: ", ")).", backend: WorkflowBackendKind.openDesign.rawValue))
        }
        return projected
    }

    private func runOpenDesign(arguments: [String: Any], backend: WorkflowBackendConfiguration, transport: ChildMCPTransport) throws -> [String: Any] {
        let required = ["list_plugins", "create_project", "start_run", "get_run", "cancel_run"]
        guard Set(backend.declaredTools).isSuperset(of: Set(required)),
              Set(transport.discoveredTools.map(\.name)).isSuperset(of: Set(required)) else {
            throw WorkflowStageDispatchError.backend(WorkflowErrorRecord(code: .backendUnavailable, message: "Open Design must advertise list_plugins, create_project, start_run, get_run, and cancel_run.", backend: backend.kind.rawValue))
        }
        let workflowRunID = arguments["workflowRunId"] as? String ?? "workflow"
        let plugins = try transport.callTool("list_plugins", arguments: .object([:]))
        let pluginName = arguments["plugin"] as? String ?? "od-web-effect-extractor"
        guard pluginAvailable(pluginName, in: plugins.foundationObject) else {
            throw WorkflowStageDispatchError.backend(WorkflowErrorRecord(code: .backendUnavailable, message: "Open Design plugin \(pluginName) is not available.", backend: backend.kind.rawValue))
        }
        let projectName = arguments["projectName"] as? String ?? "Design inspiration \(workflowRunID)"
        let createProjectArguments = try requiredArguments(tool: "create_project", values: ["name": projectName, "projectName": projectName, "title": projectName], transport: transport)
        let project = try transport.callTool("create_project", arguments: try jsonValue(createProjectArguments))
        guard let projectID = string(in: project.foundationObject, keys: ["projectId", "id"]) else {
            throw WorkflowStageDispatchError.backend(WorkflowErrorRecord(code: .backendFailure, message: "Open Design create_project did not return a project ID.", backend: backend.kind.rawValue))
        }
        let requestID = arguments["requestId"] as? String ?? workflowRunID
        let prompt = [arguments["designBrief"] as? String, arguments["motionNotes"] as? String].compactMap { $0 }.joined(separator: "\n\n")
        let startValues: [String: Any] = [
            "project": projectID,
            "projectId": projectID,
            "plugin": pluginName,
            "prompt": prompt,
            "inputs": ["url": arguments["liveUrl"] ?? "", "selectedFrames": arguments["selectedFrames"] ?? []],
            "requestId": requestID,
        ]
        let startArguments = try requiredArguments(tool: "start_run", values: startValues, transport: transport)
        let started = try transport.callTool("start_run", arguments: try jsonValue(startArguments))
        guard let runID = string(in: started.foundationObject, keys: ["runId", "id"]) else {
            throw WorkflowStageDispatchError.backend(WorkflowErrorRecord(code: .backendFailure, message: "Open Design start_run did not return a run ID.", backend: backend.kind.rawValue))
        }
        lock.lock(); openDesignRuns[workflowRunID] = (runID, backend); lock.unlock()
        var latest = started.foundationObject
        let deadline = Date().addingTimeInterval(900)
        var terminal = false
        while Date() < deadline {
            let polled = try transport.callTool("get_run", arguments: try jsonValue(projectArguments(["runId": runID], tool: "get_run", transport: transport)))
            latest = polled.foundationObject
            let status = string(in: latest, keys: ["status"]) ?? ""
            if ["succeeded", "failed", "canceled", "cancelled"].contains(status) { terminal = true; break }
            Thread.sleep(forTimeInterval: 1)
        }
        lock.lock(); openDesignRuns.removeValue(forKey: workflowRunID); lock.unlock()
        guard terminal else {
            let cancellation = projectArguments(["runId": runID], tool: "cancel_run", transport: transport)
            _ = try? transport.callTool("cancel_run", arguments: try jsonValue(cancellation))
            throw WorkflowStageDispatchError.backend(WorkflowErrorRecord(code: .backendFailure, message: "Open Design run timed out and was cancelled.", backend: backend.kind.rawValue))
        }
        let finalStatus = string(in: latest, keys: ["status"]) ?? ""
        guard finalStatus == "succeeded" else {
            throw WorkflowStageDispatchError.backend(WorkflowErrorRecord(code: .backendFailure, message: "Open Design run ended with status \(finalStatus).", backend: backend.kind.rawValue))
        }
        guard let artifact = outputArtifact(in: latest) else {
            throw WorkflowStageDispatchError.backend(WorkflowErrorRecord(code: .invalidEvidence, message: "Open Design succeeded without a hashed design artifact reference.", backend: backend.kind.rawValue))
        }
        let artifactPath = artifact["path"] as? String ?? ""
        let root = URL(fileURLWithPath: configuration.workspaceRoot).resolvingSymlinksInPath().standardizedFileURL
        let artifactURL = artifactPath.hasPrefix("/") ? URL(fileURLWithPath: artifactPath) : root.appendingPathComponent(artifactPath)
        let resolvedArtifact = artifactURL.resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolvedArtifact.path.hasPrefix(prefix),
              let artifactData = try? Data(contentsOf: resolvedArtifact),
              artifactData.count == artifact["size"] as? Int,
              WorkflowSHA256.hexDigest(artifactData) == artifact["sha256"] as? String else {
            throw WorkflowStageDispatchError.backend(WorkflowErrorRecord(code: .invalidEvidence, message: "Open Design artifact failed workspace, size, or hash validation.", backend: backend.kind.rawValue))
        }
        var validatedArtifact = artifact
        validatedArtifact["path"] = String(resolvedArtifact.path.dropFirst(root.path.count + 1))
        let frameNames = (arguments["selectedFrames"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }.map { URL(fileURLWithPath: $0).lastPathComponent }
        var redactedInputs = [arguments["liveUrl"] as? String ?? "", "approved design brief", "approved motion notes"]
        redactedInputs.append(contentsOf: frameNames)
        let capability: [String: Any] = ["id": pluginName, "available": true, "runId": runID, "projectId": projectID]
        return ["stage": WorkflowStage.handoffOpenDesign.rawValue, "status": "complete", "backend": WorkflowBackendKind.openDesign.rawValue, "tool": "start_run", "requestId": requestID, "runId": runID, "projectId": projectID, "designArtifact": validatedArtifact, "capability": capability, "redactedInputs": redactedInputs.filter { !$0.isEmpty }, "result": latest]
    }

    func pluginAvailable(_ pluginID: String, in value: Any) -> Bool {
        if let object = value as? [String: Any] {
            if let plugins = object["plugins"] as? [[String: Any]] {
                return plugins.contains { ($0["id"] as? String) == pluginID || ($0["name"] as? String) == pluginID }
            }
            if let structured = object["structuredContent"] { return pluginAvailable(pluginID, in: structured) }
            if let content = object["content"] as? [[String: Any]] {
                for item in content where item["type"] as? String == "text" {
                    guard let text = item["text"] as? String, let data = text.data(using: .utf8),
                          let parsed = try? JSONSerialization.jsonObject(with: data) else { continue }
                    if pluginAvailable(pluginID, in: parsed) { return true }
                }
            }
        }
        if let values = value as? [Any] {
            return values.contains { pluginAvailable(pluginID, in: $0) }
        }
        return false
    }

    private func string(in value: Any, keys: [String]) -> String? {
        if let object = value as? [String: Any] {
            for key in keys { if let value = object[key] as? String { return value } }
            for nested in object.values { if let value = string(in: nested, keys: keys) { return value } }
        } else if let values = value as? [Any] {
            for nested in values { if let value = string(in: nested, keys: keys) { return value } }
        }
        return nil
    }

    private func outputArtifact(in value: Any) -> [String: Any]? {
        if let object = value as? [String: Any] {
            if let path = object["path"] as? String, let hash = object["sha256"] as? String,
               let size = object["size"] as? Int, !path.isEmpty, size > 0 {
                return ["path": path, "sha256": hash, "size": size, "nonEmpty": true, "kind": object["kind"] as? String ?? "open-design"]
            }
            for nested in object.values { if let artifact = outputArtifact(in: nested) { return artifact } }
        } else if let values = value as? [Any] {
            for nested in values { if let artifact = outputArtifact(in: nested) { return artifact } }
        }
        return nil
    }

    private func jsonValue(_ arguments: [String: Any]) throws -> WorkflowJSONValue {
        guard JSONSerialization.isValidJSONObject(arguments) else { throw WorkflowContractError(.invalidConfiguration, "workflow arguments must be JSON objects") }
        return try WorkflowJSONValue(foundationValue: arguments)
    }
}

private extension WorkflowJSONValue { var foundationObject: Any { foundationValue } }
