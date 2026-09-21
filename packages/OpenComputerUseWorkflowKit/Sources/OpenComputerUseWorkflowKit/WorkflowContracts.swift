import Foundation

public enum WorkflowContractVersion {
    public static let control = "workflow-control.v1"
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
}

public enum WorkflowErrorCode: String, CaseIterable, Codable, Sendable {
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
        if kind == .openDesign, launchPolicy != .direct {
            throw WorkflowContractError(.invalidConfiguration, "open-design must use its generated direct command, not a secret wrapper")
        }
    }
}

public struct WorkflowConfiguration: Codable, Equatable, Sendable {
    public let workspaceRoot: String
    public let backends: [WorkflowBackendConfiguration]

    public init(workspaceRoot: String, backends: [WorkflowBackendConfiguration]) {
        self.workspaceRoot = workspaceRoot
        self.backends = backends
    }

    public func validate() throws {
        guard !workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkflowContractError(.invalidConfiguration, "workspaceRoot is required")
        }
        let kinds = backends.map(\.kind)
        guard kinds.count == Set(kinds).count else {
            throw WorkflowContractError(.invalidConfiguration, "workflow backend kinds must be unique")
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
    let pattern = "(?i)(api[_-]?key|token|secret|password)\\s*="
    return value.range(of: pattern, options: .regularExpression) != nil
}
