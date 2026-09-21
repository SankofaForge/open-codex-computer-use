import Foundation

public enum AppApprovalScope: Equatable, Sendable {
    case standard
    case workflow
}

public enum AppApprovalPromptKind: Equatable, Hashable, Sendable {
    case access
    case sensitiveAction
}

public struct AppApprovalRequest: Sendable {
    public let bundleIdentifier: String
    public let toolName: String
    public let kind: AppApprovalPromptKind

    public init(bundleIdentifier: String, toolName: String, kind: AppApprovalPromptKind) {
        self.bundleIdentifier = bundleIdentifier
        self.toolName = toolName
        self.kind = kind
    }
}

public enum AppApprovalResponse: Sendable {
    case approve
    case deny
    case unavailable
}

public typealias AppApprovalPrompt = @Sendable (AppApprovalRequest) -> AppApprovalResponse

/// Session-only approval for an explicitly configured set of application bundle IDs.
///
/// A policy is opt-in: callers that do not provide one keep the historical Computer
/// Use behavior. Workflow hosts should use `.workflow`, which also prevents a
/// configured global-pointer fallback from reaching the desktop service.
public final class AppApprovalPolicy: @unchecked Sendable {
    private let allowedBundleIdentifiers: Set<String>
    private let scope: AppApprovalScope
    private let prompt: AppApprovalPrompt
    private let environment: [String: String]
    private let lock = NSLock()
    private var approvedBundleIdentifiers = Set<String>()

    public init(
        allowedBundleIdentifiers: Set<String>,
        scope: AppApprovalScope = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        prompt: @escaping AppApprovalPrompt = { _ in .unavailable }
    ) {
        self.allowedBundleIdentifiers = Set(
            allowedBundleIdentifiers.map(Self.normalizedBundleIdentifier)
        )
        self.scope = scope
        self.environment = environment
        self.prompt = prompt
    }

    public func authorize(toolName: String, arguments: [String: Any]) throws {
        guard toolName != "list_apps" else {
            return
        }

        guard Self.toolRequiresApp(toolName) else {
            return
        }

        let bundleIdentifier = try requiredBundleIdentifier(in: arguments)

        if AppSafetyPolicy.isBlocked(bundleIdentifier: bundleIdentifier) {
            throw ComputerUseError.accessDenied(
                "Computer Use is not allowed to use the app '\(bundleIdentifier)' for safety reasons."
            )
        }

        guard allowedBundleIdentifiers.contains(bundleIdentifier) else {
            throw ComputerUseError.accessDenied(
                "The app '\(bundleIdentifier)' is not in this session's allowlist."
            )
        }

        try rejectWorkflowGlobalPointerPathIfNeeded(
            toolName: toolName,
            arguments: arguments
        )
        try approveAppAccessIfNeeded(bundleIdentifier: bundleIdentifier, toolName: toolName)

        if Self.requiresSensitiveActionConfirmation(toolName) {
            try confirmSensitiveAction(bundleIdentifier: bundleIdentifier, toolName: toolName)
        }
    }

    public func resetSessionApprovals() {
        lock.lock()
        approvedBundleIdentifiers.removeAll()
        lock.unlock()
    }

    public func isApprovedForCurrentSession(bundleIdentifier: String) -> Bool {
        let normalized = Self.normalizedBundleIdentifier(bundleIdentifier)
        lock.lock()
        defer { lock.unlock() }
        return approvedBundleIdentifiers.contains(normalized)
    }

    private func requiredBundleIdentifier(in arguments: [String: Any]) throws -> String {
        guard let rawValue = arguments["app"] as? String else {
            throw ComputerUseError.missingArgument("app")
        }

        let bundleIdentifier = Self.normalizedBundleIdentifier(rawValue)
        guard !bundleIdentifier.isEmpty else {
            throw ComputerUseError.missingArgument("app")
        }

        guard bundleIdentifier.contains(".") else {
            throw ComputerUseError.approvalRequired(
                "app must be an allowlisted bundle identifier."
            )
        }

        return bundleIdentifier
    }

    private func rejectWorkflowGlobalPointerPathIfNeeded(
        toolName: String,
        arguments: [String: Any]
    ) throws {
        guard scope == .workflow, globalPointerFallbacksEnabled(environment: environment) else {
            return
        }

        switch toolName {
        case "drag", "scroll":
            throw ComputerUseError.accessDenied(
                "workflow global-pointer input is disabled for \(toolName)."
            )
        case "click":
            let method = (arguments["click_method"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ClickMethod.auto.rawValue
            guard method == ClickMethod.auto.rawValue || method == ClickMethod.global.rawValue else {
                return
            }
            throw ComputerUseError.accessDenied(
                "workflow global-pointer input is disabled for click_method '\(method)'."
            )
        default:
            return
        }
    }

    private func approveAppAccessIfNeeded(bundleIdentifier: String, toolName: String) throws {
        lock.lock()
        let alreadyApproved = approvedBundleIdentifiers.contains(bundleIdentifier)
        lock.unlock()

        guard !alreadyApproved else {
            return
        }

        switch prompt(AppApprovalRequest(
            bundleIdentifier: bundleIdentifier,
            toolName: toolName,
            kind: .access
        )) {
        case .approve:
            lock.lock()
            approvedBundleIdentifiers.insert(bundleIdentifier)
            lock.unlock()
        case .deny:
            throw ComputerUseError.accessDenied(
                "Access to '\(bundleIdentifier)' was denied for this session."
            )
        case .unavailable:
            throw ComputerUseError.approvalRequired(
                "Access to '\(bundleIdentifier)' needs an interactive session approval."
            )
        }
    }

    private func confirmSensitiveAction(bundleIdentifier: String, toolName: String) throws {
        switch prompt(AppApprovalRequest(
            bundleIdentifier: bundleIdentifier,
            toolName: toolName,
            kind: .sensitiveAction
        )) {
        case .approve:
            return
        case .deny:
            throw ComputerUseError.accessDenied(
                "The sensitive '\(toolName)' action for '\(bundleIdentifier)' was denied."
            )
        case .unavailable:
            throw ComputerUseError.approvalRequired(
                "The sensitive '\(toolName)' action for '\(bundleIdentifier)' needs confirmation."
            )
        }
    }

    private static func toolRequiresApp(_ toolName: String) -> Bool {
        [
            "get_app_state",
            "click",
            "perform_secondary_action",
            "scroll",
            "drag",
            "type_text",
            "press_key",
            "set_value",
        ].contains(toolName)
    }

    private static func requiresSensitiveActionConfirmation(_ toolName: String) -> Bool {
        toolName != "get_app_state"
    }

    private static func normalizedBundleIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
