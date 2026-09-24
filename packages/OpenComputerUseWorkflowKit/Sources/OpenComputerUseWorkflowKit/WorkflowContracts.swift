import Foundation

private let browserUseCaptureRequiredEnvironmentVariables: Set<String> = [
    "VAST_INSTANCE_ID",
    "VAST_API_KEY",
    "BROWSER_USE_CHROMIUM_PATH",
    "CAPTURE_EGRESS_ATTESTATION_FILE",
]

public enum WorkflowContractVersion {
    public static let control = "workflow-control.v2"
    public static let manifest = "workflow-manifest.v2"
    public static let motionAnalysis = "motion-analysis.v2"
    public static let capability = 1
}

public enum WorkflowStage: String, CaseIterable, Codable, Sendable {
    case preflight
    case searchReferences = "search_references"
    case prepareReferences = "prepare_references"
    case extractTokens = "extract_tokens"
    case checkCaptureGPU = "check_capture_gpu"
    case captureSiteMotion = "capture_site_motion"
    case submitMotionAnalysis = "submit_motion_analysis"
    case extractFrames = "extract_frames"
    case handoffOpenDesign = "handoff_open_design"
    case resolveAssetRoutes = "resolve_asset_routes"
    case validate
}

public enum WorkflowRunStatus: String, CaseIterable, Codable, Sendable {
    case running
    case partial
    case blocked
    case complete
    case cancelled
}

public enum WorkflowTaskProfile: String, CaseIterable, Codable, Sendable {
    case visualImplementation = "visual-implementation"
    case evidenceOnly = "evidence-only"
    case tokenOnly = "token-only"
    case nonvisual

    public var stages: [WorkflowStage] { stages(preparedAssetIDs: nil) }

    public func stages(preparedAssetIDs: Set<String>?) -> [WorkflowStage] {
        let stages: [WorkflowStage]
        switch self {
        case .visualImplementation:
            stages = [.preflight, .searchReferences, .prepareReferences, .extractTokens, .checkCaptureGPU, .captureSiteMotion, .submitMotionAnalysis, .extractFrames, .handoffOpenDesign, .resolveAssetRoutes, .validate]
        case .evidenceOnly:
            stages = [.preflight, .searchReferences, .prepareReferences, .checkCaptureGPU, .captureSiteMotion, .submitMotionAnalysis, .extractFrames, .validate]
        case .tokenOnly:
            stages = [.preflight, .searchReferences, .prepareReferences, .extractTokens, .validate]
        case .nonvisual:
            stages = [.preflight]
        }
        if self == .visualImplementation, preparedAssetIDs?.isEmpty == true {
            return stages.filter { $0 != .resolveAssetRoutes }
        }
        return stages
    }
}

public enum WorkflowResumeSubmission: @unchecked Sendable {
    case referenceSelection([String: Any])
    case motionAnalysis(path: String, cellId: String)
    case approval(actionId: String, approved: Bool)
    case assetResults(path: String)

    public static func decode(_ value: Any) throws -> Self {
        guard let object = value as? [String: Any], let kind = object["kind"] as? String else {
            throw WorkflowContractError(.invalidEvidence, "workflow_resume requires a typed submission")
        }
        switch kind {
        case "reference-selection":
            guard Set(object.keys) == ["kind", "reference"], let reference = object["reference"] as? [String: Any] else {
                throw WorkflowContractError(.invalidEvidence, "reference-selection requires only a reference object")
            }
            return .referenceSelection(reference)
        case "motion-analysis":
            guard Set(object.keys) == ["kind", "path", "cellId"], let path = object["path"] as? String, let cellId = object["cellId"] as? String else {
                throw WorkflowContractError(.invalidEvidence, "motion-analysis requires path and cellId")
            }
            return .motionAnalysis(path: path, cellId: cellId)
        case "approval":
            guard Set(object.keys) == ["kind", "actionId", "approved"], let actionId = object["actionId"] as? String, let approved = object["approved"] as? Bool else {
                throw WorkflowContractError(.invalidEvidence, "approval requires actionId and approved")
            }
            return .approval(actionId: actionId, approved: approved)
        case "asset-results":
            guard Set(object.keys) == ["kind", "path"], let path = object["path"] as? String else {
                throw WorkflowContractError(.invalidEvidence, "asset-results requires a workspace-relative path")
            }
            return .assetResults(path: path)
        default:
            throw WorkflowContractError(.invalidEvidence, "unsupported workflow submission kind")
        }
    }
}

public struct WorkflowStageContext: @unchecked Sendable {
    public let runId: String
    public let workspaceRoot: String
    public let taskProfile: String
    public let inputs: [String: Any]
    public let previousResults: [WorkflowStage: [String: Any]]

    public init(runId: String, workspaceRoot: String, taskProfile: String, inputs: [String: Any], previousResults: [WorkflowStage: [String: Any]] = [:]) {
        self.runId = runId
        self.workspaceRoot = workspaceRoot
        self.taskProfile = taskProfile
        self.inputs = inputs
        self.previousResults = previousResults
    }

    public func arguments(for stage: WorkflowStage) -> [String: Any] {
        let keys: Set<String>
        switch stage {
        case .searchReferences: keys = ["query"]
        case .prepareReferences: keys = ["reference"]
        case .extractTokens: keys = ["reference"]
        case .checkCaptureGPU: keys = ["liveUrl", "cellId", "viewport", "motionMode"]
        case .captureSiteMotion: keys = ["liveUrl", "cellId", "viewport", "motionMode", "gpuCheckId"]
        case .submitMotionAnalysis: keys = ["path", "cellId"]
        case .extractFrames: keys = ["analysisPath", "cellId"]
        case .handoffOpenDesign: keys = ["liveUrl", "designBrief", "motionNotes", "selectedFrames", "projectId", "requestId"]
        case .resolveAssetRoutes: keys = ["assetPlan", "assetResultsPath"]
        case .validate: keys = ["manifestPath", "expectedAssetIDs", "assetResultsPath"]
        case .preflight: keys = []
        }
        var arguments = inputs.filter { keys.contains($0.key) }
        if stage == .preflight {
            arguments["requiresCapture"] = taskProfile == WorkflowTaskProfile.visualImplementation.rawValue || taskProfile == WorkflowTaskProfile.evidenceOnly.rawValue
        }
        if stage == .prepareReferences, arguments["reference"] == nil,
           let result = previousResults[.searchReferences],
           let candidates = result["references"] as? [[String: Any]], candidates.count == 1 {
            arguments["reference"] = candidates[0]
        }
        if let prepared = previousResults[.prepareReferences] {
            if arguments["liveUrl"] == nil { arguments["liveUrl"] = prepared["liveUrl"] ?? prepared["url"] }
            if arguments["liveUrl"] == nil, let refs = prepared["references"] as? [[String: Any]], refs.count == 1 {
                arguments["liveUrl"] = refs[0]["liveUrl"]
            }
            if arguments["reference"] == nil { arguments["reference"] = prepared["reference"] }
        }
        if stage == .extractTokens, arguments["reference"] == nil {
            arguments["reference"] = (inputs["reference"] as? [String: Any]) ?? (previousResults[.prepareReferences]?["reference"] as? [String: Any])
        }
        if stage == .handoffOpenDesign {
            arguments["workflowRunId"] = runId
            if arguments["requestId"] == nil { arguments["requestId"] = runId }
            if arguments["liveUrl"] == nil { arguments["liveUrl"] = (inputs["reference"] as? [String: Any])?["liveUrl"] }
            if arguments["designBrief"] == nil { arguments["designBrief"] = inputs["designBrief"] }
            if arguments["motionNotes"] == nil, let analyses = inputs["analysisSubmissions"] as? [[String: Any]] {
                arguments["motionNotes"] = analyses.map { "\($0["cellId"] ?? "cell"): analysis at \($0["path"] ?? "")" }.joined(separator: "\n")
            }
            if arguments["selectedFrames"] == nil, let frames = previousResults[.extractFrames]?["frames"] { arguments["selectedFrames"] = frames }
        }
        if let gpu = previousResults[.checkCaptureGPU], arguments["gpuCheckId"] == nil {
            arguments["gpuCheckId"] = gpu["gpuCheckId"]
        }
        if let analysis = previousResults[.submitMotionAnalysis], arguments["analysisPath"] == nil {
            arguments["analysisPath"] = analysis["path"]
        }
        if let assets = previousResults[.prepareReferences], arguments["assetPlan"] == nil {
            arguments["assetPlan"] = assets["assetPlan"]
        }
        if stage == .validate, let plan = previousResults[.prepareReferences]?["assetPlan"] as? [[String: Any]] {
            arguments["expectedAssetIDs"] = plan.compactMap { $0["assetId"] as? String }
        }
        return arguments
    }
}

public enum WorkflowErrorCode: String, CaseIterable, Codable, Hashable, Sendable {
    case invalidConfiguration = "invalid_configuration"
    case invalidEvidence = "invalid_evidence"
    case unsupportedSchema = "unsupported_schema"
    case artifactOutsideWorkspace = "artifact_outside_workspace"
    case artifactMissing = "artifact_missing"
    case artifactEmpty = "artifact_empty"
    case artifactSizeMismatch = "artifact_size_mismatch"
    case artifactHashMismatch = "artifact_hash_mismatch"
    case incompleteMatrix = "incomplete_matrix"
    case openDesignRequired = "open_design_required"
    case assetRouteBlocked = "asset_route_blocked"
    case backendUnavailable = "backend_unavailable"
    case backendFailure = "backend_failure"
    case cancelled
}

public struct WorkflowOutput: Codable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let path: String?
    public let sha256: String?

    public init(id: String, kind: String, path: String? = nil, sha256: String? = nil) {
        self.id = id
        self.kind = kind
        self.path = path
        self.sha256 = sha256
    }
}

public struct WorkflowGap: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let required: Bool

    public init(code: String, message: String, required: Bool) {
        self.code = code
        self.message = message
        self.required = required
    }
}

public struct WorkflowErrorRecord: Codable, Equatable, Sendable {
    public let code: WorkflowErrorCode
    public let message: String
    public let backend: String?

    public init(code: WorkflowErrorCode, message: String, backend: String? = nil) {
        self.code = code
        self.message = message
        self.backend = backend
    }
}

public struct WorkflowControlEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let runId: String
    public let stage: WorkflowStage
    public let status: WorkflowRunStatus
    public let outputs: [WorkflowOutput]
    public let manifestPath: String?
    public let gaps: [WorkflowGap]
    public let blockedReason: String?
    public let error: WorkflowErrorRecord?

    public init(
        runId: String,
        stage: WorkflowStage,
        status: WorkflowRunStatus,
        outputs: [WorkflowOutput] = [],
        manifestPath: String? = nil,
        gaps: [WorkflowGap] = [],
        blockedReason: String? = nil,
        error: WorkflowErrorRecord? = nil
    ) {
        self.schemaVersion = WorkflowContractVersion.control
        self.runId = runId
        self.stage = stage
        self.status = status
        self.outputs = outputs
        self.manifestPath = manifestPath
        self.gaps = gaps
        self.blockedReason = blockedReason
        self.error = error
    }
}

public enum WorkflowBackendKind: String, Codable, Sendable {
    case designInspiration = "design-inspiration"
    case siteMotionCapture = "site-motion-capture"
    case browserUseCapture = "browser-use-capture"
    case openDesign = "open-design"
    case frameExtraction = "frame-extraction"
    case assetRouting = "asset-routing"
    case motionAnalysis = "motion-analysis"
}

public enum WorkflowLaunchPolicy: String, Codable, Sendable {
    case direct
    case secretWrapper = "secret-wrapper"
}

public struct WorkflowBackendConfiguration: Codable, Equatable, Sendable {
    public let kind: WorkflowBackendKind
    public let command: String
    public let arguments: [String]
    public let workingDirectory: String?
    public let permittedEnvironmentVariables: [String]
    public let declaredTools: [String]
    public let launchPolicy: WorkflowLaunchPolicy

    public init(
        kind: WorkflowBackendKind,
        command: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        permittedEnvironmentVariables: [String] = [],
        declaredTools: [String],
        launchPolicy: WorkflowLaunchPolicy = .direct
    ) {
        self.kind = kind
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.permittedEnvironmentVariables = permittedEnvironmentVariables
        self.declaredTools = declaredTools
        self.launchPolicy = launchPolicy
    }

    public func validate() throws {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkflowContractError(.invalidConfiguration, "backend command is required")
        }
        guard !declaredTools.isEmpty, Set(declaredTools).count == declaredTools.count,
              declaredTools.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw WorkflowContractError(.invalidConfiguration, "backend declaredTools must be a non-empty unique list")
        }
        guard Set(permittedEnvironmentVariables).count == permittedEnvironmentVariables.count,
              permittedEnvironmentVariables.allSatisfy(isEnvironmentVariableName) else {
            throw WorkflowContractError(.invalidConfiguration, "permittedEnvironmentVariables must contain unique environment variable names")
        }
        guard arguments.allSatisfy({ !containsSecretAssignment($0) }) else {
            throw WorkflowContractError(.invalidConfiguration, "backend arguments must not contain credential assignments")
        }
        if kind == .browserUseCapture {
            let requiredTools: Set<String> = ["check_capture_gpu", "capture_site_motion"]
            guard Set(declaredTools) == requiredTools else {
                throw WorkflowContractError(.invalidConfiguration, "browser-use-capture must declare exactly check_capture_gpu and capture_site_motion")
            }
            guard !permittedEnvironmentVariables.contains("BROWSER_USE_CAPTURE_COMPATIBLE") else {
                throw WorkflowContractError(.invalidConfiguration, "browser-use-capture does not accept a manual compatibility override")
            }
            guard Set(permittedEnvironmentVariables) == browserUseCaptureRequiredEnvironmentVariables else {
                throw WorkflowContractError(.invalidConfiguration, "browser-use-capture must permit exactly VAST_INSTANCE_ID, VAST_API_KEY, BROWSER_USE_CHROMIUM_PATH, and CAPTURE_EGRESS_ATTESTATION_FILE")
            }
        }
        if kind == .openDesign, launchPolicy != .direct {
            throw WorkflowContractError(.invalidConfiguration, "open-design must use its generated direct command, not a secret wrapper")
        }
    }
}

public struct WorkflowConfiguration: Codable, Equatable, Sendable {
    public let workspaceRoot: String
    public let backends: [WorkflowBackendConfiguration]
    public let captureBackend: WorkflowBackendKind?

    public init(workspaceRoot: String, backends: [WorkflowBackendConfiguration], captureBackend: WorkflowBackendKind? = nil) {
        self.workspaceRoot = workspaceRoot
        self.backends = backends
        self.captureBackend = captureBackend
    }

    public static func load(path: String) throws -> Self {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        if let configuration = try? decoder.decode(Self.self, from: data) {
            try configuration.validate()
            return configuration
        }

        struct Legacy: Decodable {
            struct Backend: Decodable {
                let id: String
                let command: String
                let arguments: [String]?
                let workingDirectory: String?
                let environmentAllowlist: [String]?
                let declaredTools: [String]?
            }
            let workspaceRoot: String?
            let backends: [Backend]
            let captureBackend: WorkflowBackendKind?
        }
        let legacy = try decoder.decode(Legacy.self, from: data)
        let backends = try legacy.backends.map { backend in
            guard let kind = WorkflowBackendKind(rawValue: backend.id) else {
                throw WorkflowContractError(.invalidConfiguration, "unsupported backend kind: \(backend.id)")
            }
            return WorkflowBackendConfiguration(
                kind: kind,
                command: backend.command,
                arguments: backend.arguments ?? [],
                workingDirectory: backend.workingDirectory,
                permittedEnvironmentVariables: backend.environmentAllowlist ?? [],
                declaredTools: backend.declaredTools ?? []
            )
        }
        let configuration = Self(workspaceRoot: legacy.workspaceRoot ?? ".", backends: backends, captureBackend: legacy.captureBackend)
        try configuration.validate()
        return configuration
    }

    public func validate() throws {
        guard !workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkflowContractError(.invalidConfiguration, "workspaceRoot is required")
        }
        let kinds = backends.map(\.kind)
        guard kinds.count == Set(kinds).count else {
            throw WorkflowContractError(.invalidConfiguration, "workflow backend kinds must be unique")
        }
        if let captureBackend {
            guard captureBackend == .browserUseCapture || captureBackend == .siteMotionCapture else {
                throw WorkflowContractError(.invalidConfiguration, "captureBackend must be browser-use-capture or site-motion-capture")
            }
            guard kinds.contains(captureBackend) else {
                throw WorkflowContractError(.invalidConfiguration, "captureBackend must reference a configured backend")
            }
        }
        try backends.forEach { try $0.validate() }
    }
}

public struct WorkflowContractError: Error, LocalizedError, Equatable, Sendable {
    public let code: WorkflowErrorCode
    public let message: String

    public init(_ code: WorkflowErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

private func isEnvironmentVariableName(_ value: String) -> Bool {
    guard let first = value.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first) else {
        return false
    }
    return value.unicodeScalars.allSatisfy { $0 == "_" || CharacterSet.alphanumerics.contains($0) }
}

private func containsSecretAssignment(_ value: String) -> Bool {
    let pattern = "(?i)(?:api[_-]?key|token|secret|password|[A-Z][A-Z0-9_]*)\\s*="
    return value.range(of: pattern, options: .regularExpression) != nil
}
