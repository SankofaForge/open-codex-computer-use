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
        .checkCaptureGPU: Route(kind: .siteMotionCapture, tool: "check_capture_gpu"),
        .captureSiteMotion: Route(kind: .siteMotionCapture, tool: "capture_site_motion"),
        .submitMotionAnalysis: Route(kind: .motionAnalysis, tool: "submit_motion_analysis"),
        .extractFrames: Route(kind: .frameExtraction, tool: "extract_frames"),
        .handoffOpenDesign: Route(kind: .openDesign, tool: "handoff_open_design"),
        .resolveAssetRoutes: Route(kind: .assetRouting, tool: "resolve_asset_routes"),
    ]
    private var transports: [WorkflowBackendKind: ChildMCPTransport] = [:]
    private let lock = NSLock()

    public init(configuration: WorkflowConfiguration, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        try configuration.validate()
        self.configuration = configuration
        self.environment = environment
    }

    public func dispatch(stage: WorkflowStage, arguments: [String: Any]) throws -> [String: Any] {
        if stage == .preflight || stage == .validate {
            return ["stage": stage.rawValue, "status": "complete", "workspaceRoot": configuration.workspaceRoot]
        }
        guard let route = routes[stage] else { throw WorkflowStageDispatchError.missingBackend(.designInspiration, stage) }
        guard let backend = configuration.backends.first(where: { $0.kind == route.kind }) else {
            throw WorkflowStageDispatchError.missingBackend(route.kind, stage)
        }
        guard backend.declaredTools.contains(route.tool) else {
            throw WorkflowStageDispatchError.missingTool(route.kind, route.tool, stage)
        }
        do {
            let result = try transport(for: backend).callTool(route.tool, arguments: try jsonValue(arguments))
            return ["stage": stage.rawValue, "backend": route.kind.rawValue, "tool": route.tool, "result": result.foundationObject]
        } catch let error as ChildMCPTransportError {
            throw WorkflowStageDispatchError.backend(WorkflowErrorRecord(code: .backendFailure, message: error.localizedDescription, backend: backend.kind.rawValue))
        }
    }

    public func shutdown() {
        lock.lock(); let active = Array(transports.values); transports.removeAll(); lock.unlock()
        active.forEach { try? $0.shutdown() }
    }

    deinit { shutdown() }

    private func transport(for backend: WorkflowBackendConfiguration) throws -> ChildMCPTransport {
        lock.lock(); if let existing = transports[backend.kind] { lock.unlock(); return existing }; lock.unlock()
        let child = try ChildMCPTransport(configuration: ChildMCPBackendConfiguration(
            identifier: backend.kind.rawValue,
            executableURL: URL(fileURLWithPath: backend.command),
            arguments: backend.arguments,
            workingDirectoryURL: backend.workingDirectory.map(URL.init(fileURLWithPath:)),
            permittedEnvironmentVariableNames: Set(backend.permittedEnvironmentVariables),
            declaredToolNames: Set(backend.declaredTools)
        ))
        try child.start(environment: environment)
        lock.lock(); transports[backend.kind] = child; lock.unlock()
        return child
    }

    private func jsonValue(_ arguments: [String: Any]) throws -> WorkflowJSONValue {
        guard JSONSerialization.isValidJSONObject(arguments) else { throw WorkflowContractError(.invalidConfiguration, "workflow arguments must be JSON objects") }
        return try WorkflowJSONValue(foundationValue: arguments)
    }
}

private extension WorkflowJSONValue { var foundationObject: Any { foundationValue } }
