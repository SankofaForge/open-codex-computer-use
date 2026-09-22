import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// JSON values accepted by the workflow boundary. Keeping this type independent
/// from the OCU tool result types lets workflow backends evolve separately.
public enum WorkflowJSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([WorkflowJSONValue])
    case object([String: WorkflowJSONValue])

    public var objectValue: [String: WorkflowJSONValue]? {
        guard case .object(let value) = self else {
            return nil
        }

        return value
    }

    public var arrayValue: [WorkflowJSONValue]? {
        guard case .array(let value) = self else {
            return nil
        }

        return value
    }

    public var stringValue: String? {
        guard case .string(let value) = self else {
            return nil
        }

        return value
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var intValue: Int? {
        guard case let .number(value) = self, value.rounded() == value else {
            return nil
        }

        return Int(value)
    }

    init(foundationValue: Any) throws {
        switch foundationValue {
        case is NSNull:
            self = .null
        case let value as NSNumber:
            if String(cString: value.objCType) == "c" {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as Bool:
            self = .bool(value)
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(try value.map(WorkflowJSONValue.init(foundationValue:)))
        case let value as [String: Any]:
            self = .object(try value.mapValues(WorkflowJSONValue.init(foundationValue:)))
        default:
            throw ChildMCPTransportError.malformedStandardOutput("JSON-RPC contained an unsupported JSON value.")
        }
    }

    var foundationValue: Any {
        switch self {
        case .null:
            NSNull()
        case .bool(let value):
            value
        case .number(let value):
            value
        case .string(let value):
            value
        case .array(let value):
            value.map(\.foundationValue)
        case .object(let value):
            value.mapValues(\.foundationValue)
        }
    }
}

public struct ChildMCPTimeouts: Sendable, Equatable {
    public let startup: TimeInterval
    public let request: TimeInterval
    public let shutdown: TimeInterval
    public let maximumResponseBytes: Int
    public let maximumDiagnosticBytes: Int

    public init(
        startup: TimeInterval = 15,
        request: TimeInterval = 60,
        shutdown: TimeInterval = 5,
        maximumResponseBytes: Int = 1_048_576,
        maximumDiagnosticBytes: Int = 64 * 1024
    ) {
        self.startup = startup
        self.request = request
        self.shutdown = shutdown
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumDiagnosticBytes = maximumDiagnosticBytes
    }

    fileprivate func validate() throws {
        guard startup > 0, request > 0, shutdown > 0 else {
            throw ChildMCPTransportError.invalidConfiguration("Child-MCP timeouts must be greater than zero.")
        }

        guard maximumResponseBytes > 0, maximumDiagnosticBytes > 0 else {
            throw ChildMCPTransportError.invalidConfiguration("maximumResponseBytes must be greater than zero.")
        }
    }
}

public struct ChildMCPDiagnostic: Sendable, Equatable {
    public let backendIdentifier: String
    public let data: Data

    public init(backendIdentifier: String, data: Data) {
        self.backendIdentifier = backendIdentifier
        self.data = data
    }
}

public typealias ChildMCPDiagnosticSink = @Sendable (ChildMCPDiagnostic) -> Void

public enum ChildMCPDiagnosticSinks {
    /// Writes backend diagnostics to the workflow host's stderr. The transport
    /// never writes backend diagnostics to its JSON-RPC stdout channel.
    public static let standardError: ChildMCPDiagnosticSink = { diagnostic in
        FileHandle.standardError.write(diagnostic.data)
    }
}

/// Configuration is intentionally command-only: environment values are supplied
/// by the workflow host at launch and filtered through `permittedEnvironmentVariableNames`.
public struct ChildMCPBackendConfiguration: Sendable {
    public let identifier: String
    public let executableURL: URL
    public let arguments: [String]
    public let workingDirectoryURL: URL?
    public let permittedEnvironmentVariableNames: Set<String>
    public let declaredToolNames: Set<String>
    public let timeouts: ChildMCPTimeouts
    public let diagnosticSink: ChildMCPDiagnosticSink

    public init(
        identifier: String,
        executableURL: URL,
        arguments: [String] = [],
        workingDirectoryURL: URL? = nil,
        permittedEnvironmentVariableNames: Set<String> = [],
        declaredToolNames: Set<String>,
        timeouts: ChildMCPTimeouts = ChildMCPTimeouts(),
        diagnosticSink: @escaping ChildMCPDiagnosticSink = ChildMCPDiagnosticSinks.standardError
    ) {
        self.identifier = identifier
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectoryURL = workingDirectoryURL
        self.permittedEnvironmentVariableNames = permittedEnvironmentVariableNames
        self.declaredToolNames = declaredToolNames
        self.timeouts = timeouts
        self.diagnosticSink = diagnosticSink
    }

    fileprivate func validate() throws {
        guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChildMCPTransportError.invalidConfiguration("Child-MCP backend identifier is required.")
        }

        guard executableURL.isFileURL else {
            throw ChildMCPTransportError.invalidConfiguration("Child-MCP executable must be a file URL.")
        }

        guard !declaredToolNames.isEmpty else {
            throw ChildMCPTransportError.invalidConfiguration("Child-MCP backend \(identifier) must declare at least one permitted tool.")
        }

        try timeouts.validate()
    }
}

public struct ChildMCPBackendError: Error, Sendable, Equatable {
    public let code: Int
    public let message: String
    public let data: WorkflowJSONValue?

    public init(code: Int, message: String, data: WorkflowJSONValue?) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public enum ChildMCPTransportError: Error, LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String)
    case alreadyStarted
    case notStarted
    case startupTimedOut(String)
    case requestTimedOut(String)
    case responseTooLarge(limit: Int)
    case malformedStandardOutput(String)
    case unexpectedEndOfStandardOutput
    case processLaunchFailed(String)
    case processExited(Int32)
    case declaredToolRejected(backendIdentifier: String, toolName: String)
    case backendError(ChildMCPBackendError)
    case cancelled
    case shutdownTimedOut(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .malformedStandardOutput(let message), .processLaunchFailed(let message):
            message
        case .alreadyStarted:
            "Child-MCP backend is already started."
        case .notStarted:
            "Child-MCP backend is not started."
        case .startupTimedOut(let backendIdentifier):
            "Child-MCP backend \(backendIdentifier) did not finish startup before its timeout."
        case .requestTimedOut(let backendIdentifier):
            "Child-MCP backend \(backendIdentifier) did not respond before its request timeout."
        case .responseTooLarge(let limit):
            "Child-MCP response exceeded the \(limit)-byte limit."
        case .unexpectedEndOfStandardOutput:
            "Child-MCP backend closed stdout before it returned a JSON-RPC response."
        case .processExited(let status):
            "Child-MCP backend exited with status \(status)."
        case .declaredToolRejected(let backendIdentifier, let toolName):
            "Child-MCP backend \(backendIdentifier) is not permitted to call tool \(toolName)."
        case .backendError(let error):
            error.message
        case .cancelled:
            "Child-MCP request was cancelled."
        case .shutdownTimedOut(let backendIdentifier):
            "Child-MCP backend \(backendIdentifier) did not exit before its shutdown timeout."
        }
    }
}

public struct ChildMCPTool: Sendable, Equatable {
    public let name: String
    public let definition: WorkflowJSONValue

    public init(name: String, definition: WorkflowJSONValue) {
        self.name = name
        self.definition = definition
    }
}

private final class ChildMCPProcessSession: @unchecked Sendable {
    let process: Process
    let input: FileHandle
    let output: FileHandle
    let error: FileHandle

    init(process: Process, input: FileHandle, output: FileHandle, error: FileHandle) {
        self.process = process
        self.input = input
        self.output = output
        self.error = error
    }
}

/// A direct-process, line-delimited JSON-RPC client for configured workflow MCP
/// backends. It intentionally does not provide shell execution or tool fallback.
public final class ChildMCPTransport: @unchecked Sendable {
    private let configuration: ChildMCPBackendConfiguration
    private let operationLock = NSLock()
    private let stateLock = NSLock()
    private var session: ChildMCPProcessSession?
    private var nextRequestID = 1
    private var cancelled = false
    private var tools: [String: ChildMCPTool] = [:]
    private var diagnosticBytes = 0

    public init(configuration: ChildMCPBackendConfiguration) throws {
        try configuration.validate()
        self.configuration = configuration
    }

    deinit {
        cancel()
    }

    public var discoveredTools: [ChildMCPTool] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return tools.values.sorted { $0.name < $1.name }
    }

    /// Starts the configured executable directly, initializes it, and reads its
    /// tool registry. Only named environment variables may enter the child.
    public func start(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        operationLock.lock()
        defer { operationLock.unlock() }

        stateLock.lock()
        let isStarted = session != nil
        stateLock.unlock()
        guard !isStarted else {
            throw ChildMCPTransportError.alreadyStarted
        }

        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.currentDirectoryURL = configuration.workingDirectoryURL
        process.environment = filteredEnvironment(from: environment)

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw ChildMCPTransportError.processLaunchFailed(String(describing: error))
        }
#if canImport(Darwin)
        _ = Darwin.setpgid(process.processIdentifier, process.processIdentifier)
#endif

        let newSession = ChildMCPProcessSession(
            process: process,
            input: inputPipe.fileHandleForWriting,
            output: outputPipe.fileHandleForReading,
            error: errorPipe.fileHandleForReading
        )
        configureDiagnostics(for: newSession)

        stateLock.lock()
        session = newSession
        cancelled = false
        diagnosticBytes = 0
        stateLock.unlock()

        do {
            let initializeResult = try requestLocked(
                session: newSession,
                method: "initialize",
                parameters: .object([
                    "protocolVersion": .string("2025-03-26"),
                    "clientInfo": .object([
                        "name": .string("open-computer-use-workflow"),
                        "version": .string("1"),
                    ]),
                    "capabilities": .object([:]),
                ]),
                timeout: configuration.timeouts.startup,
                timeoutError: .startupTimedOut(configuration.identifier)
            )
            guard initializeResult.objectValue != nil else {
                throw ChildMCPTransportError.malformedStandardOutput("Child-MCP initialize result must be a JSON object.")
            }

            try notifyLocked(session: newSession, method: "notifications/initialized", parameters: .object([:]))
            let listResult = try requestLocked(
                session: newSession,
                method: "tools/list",
                parameters: .object([:]),
                timeout: configuration.timeouts.startup,
                timeoutError: .startupTimedOut(configuration.identifier)
            )
            let discoveredTools = try parseTools(listResult)

            stateLock.lock()
            tools = Dictionary(uniqueKeysWithValues: discoveredTools.map { ($0.name, $0) })
            stateLock.unlock()
        } catch {
            terminate(session: newSession)
            clear(session: newSession)
            throw error
        }
    }

    /// Calls a tool only after confirming that it appears in the backend's
    /// configured allowlist and advertised tool registry.
    public func callTool(_ name: String, arguments: WorkflowJSONValue = .object([:])) throws -> WorkflowJSONValue {
        operationLock.lock()
        defer { operationLock.unlock() }

        guard configuration.declaredToolNames.contains(name) else {
            throw ChildMCPTransportError.declaredToolRejected(backendIdentifier: configuration.identifier, toolName: name)
        }

        let activeSession = try requireSession()
        stateLock.lock()
        let toolIsAdvertised = tools[name] != nil
        stateLock.unlock()
        guard toolIsAdvertised else {
            throw ChildMCPTransportError.declaredToolRejected(backendIdentifier: configuration.identifier, toolName: name)
        }

        return try requestLocked(
            session: activeSession,
            method: "tools/call",
            parameters: .object([
                "name": .string(name),
                "arguments": arguments,
            ]),
            timeout: configuration.timeouts.request,
            timeoutError: .requestTimedOut(configuration.identifier)
        )
    }

    /// Terminates an in-flight request and closes the child process. A later
    /// start creates a new backend process; cancelled sessions are never reused.
    public func cancel() {
        stateLock.lock()
        cancelled = true
        let activeSession = session
        stateLock.unlock()

        guard let activeSession else {
            return
        }

        terminate(session: activeSession)
        clear(session: activeSession)
    }

    /// Requests a bounded graceful shutdown, then terminates a child that did
    /// not exit. This never invokes a shell command.
    public func shutdown() throws {
        operationLock.lock()
        defer { operationLock.unlock() }

        guard let activeSession = currentSession() else {
            return
        }

        try? activeSession.input.close()
        if waitForExit(activeSession.process, timeout: configuration.timeouts.shutdown) {
            clear(session: activeSession)
            return
        }

        terminate(session: activeSession)
        clear(session: activeSession)
        throw ChildMCPTransportError.shutdownTimedOut(configuration.identifier)
    }

    private func filteredEnvironment(from environment: [String: String]) -> [String: String] {
        let baselineNames = ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"]
        let allowed = Set(baselineNames).union(configuration.permittedEnvironmentVariableNames)
        return environment.filter { allowed.contains($0.key) }
    }

    private func configureDiagnostics(for session: ChildMCPProcessSession) {
        session.error.readabilityHandler = { [weak self, configuration] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }

            guard let self else { return }
            self.stateLock.lock()
            let remaining = max(0, configuration.timeouts.maximumDiagnosticBytes - self.diagnosticBytes)
            let bounded = data.prefix(remaining)
            self.diagnosticBytes += bounded.count
            self.stateLock.unlock()
            guard !bounded.isEmpty else { return }
            let redacted = Self.redactDiagnostic(Data(bounded))
            configuration.diagnosticSink(ChildMCPDiagnostic(backendIdentifier: configuration.identifier, data: redacted))
        }
    }

    private func requireSession() throws -> ChildMCPProcessSession {
        stateLock.lock()
        defer { stateLock.unlock() }
        if cancelled {
            throw ChildMCPTransportError.cancelled
        }

        guard let session else {
            throw ChildMCPTransportError.notStarted
        }

        return session
    }

    private func currentSession() -> ChildMCPProcessSession? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return session
    }

    private func isCancelled() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }

    private func clear(session target: ChildMCPProcessSession) {
        stateLock.lock()
        if session === target {
            session = nil
            tools = [:]
        }
        stateLock.unlock()
    }

    private func terminate(session: ChildMCPProcessSession) {
        session.error.readabilityHandler = nil
        try? session.input.close()
        if session.process.isRunning {
            session.process.terminate()
            _ = waitForExit(session.process, timeout: min(configuration.timeouts.shutdown, 0.25))
            if session.process.isRunning {
                killProcessGroup(session.process)
            }
        }
    }

    private static func redactDiagnostic(_ data: Data) -> Data {
        guard var text = String(data: data, encoding: .utf8) else { return data }
        let patterns = [
            "(?i)(api[_-]?key|token|secret|password)(\\s*[=:]\\s*)[^\\s,;]+",
            "(?i)bearer\\s+[A-Za-z0-9._-]+",
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: "$1$2[REDACTED]", options: .regularExpression)
        }
        return Data(text.utf8)
    }

    private func killProcessGroup(_ process: Process) {
        #if canImport(Darwin)
        Darwin.kill(-process.processIdentifier, SIGKILL)
        #else
        process.terminate()
        #endif
    }

    private func requestLocked(
        session: ChildMCPProcessSession,
        method: String,
        parameters: WorkflowJSONValue,
        timeout: TimeInterval,
        timeoutError: ChildMCPTransportError
    ) throws -> WorkflowJSONValue {
        if isCancelled() {
            throw ChildMCPTransportError.cancelled
        }

        let id = allocateRequestID()
        try write(
            .object([
                "jsonrpc": .string("2.0"),
                "id": .number(Double(id)),
                "method": .string(method),
                "params": parameters,
            ]),
            to: session.input
        )

        let response = try readResponse(
            from: session,
            expectedID: id,
            timeout: timeout,
            timeoutError: timeoutError
        )

        if let backendError = response.error {
            throw ChildMCPTransportError.backendError(backendError)
        }

        guard let result = response.result else {
            throw ChildMCPTransportError.malformedStandardOutput("JSON-RPC response did not contain result or error.")
        }

        return result
    }

    private func notifyLocked(session: ChildMCPProcessSession, method: String, parameters: WorkflowJSONValue) throws {
        try write(
            .object([
                "jsonrpc": .string("2.0"),
                "method": .string(method),
                "params": parameters,
            ]),
            to: session.input
        )
    }

    private func allocateRequestID() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        let id = nextRequestID
        nextRequestID += 1
        return id
    }

    private func write(_ value: WorkflowJSONValue, to input: FileHandle) throws {
        guard case .object(let object) = value else {
            throw ChildMCPTransportError.invalidConfiguration("JSON-RPC request must be a JSON object.")
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: object.mapValues(\.foundationValue), options: [.withoutEscapingSlashes])
            input.write(data)
            input.write(Data([0x0A]))
        } catch {
            if isCancelled() {
                throw ChildMCPTransportError.cancelled
            }
            throw ChildMCPTransportError.processLaunchFailed("Failed to write JSON-RPC request: \(error)")
        }
    }

    private func readResponse(
        from session: ChildMCPProcessSession,
        expectedID: Int,
        timeout: TimeInterval,
        timeoutError: ChildMCPTransportError
    ) throws -> (result: WorkflowJSONValue?, error: ChildMCPBackendError?) {
        while true {
            let line = try readLine(from: session, timeout: timeout, timeoutError: timeoutError)
            let value: WorkflowJSONValue
            do {
                let object = try JSONSerialization.jsonObject(with: line)
                value = try WorkflowJSONValue(foundationValue: object)
            } catch let error as ChildMCPTransportError {
                throw error
            } catch {
                throw ChildMCPTransportError.malformedStandardOutput("Child-MCP stdout contained invalid JSON-RPC: \(error.localizedDescription)")
            }
            guard case .object(let response) = value else {
                throw ChildMCPTransportError.malformedStandardOutput("Child-MCP stdout JSON-RPC message must be an object.")
            }
            guard response["jsonrpc"] == .string("2.0") else {
                throw ChildMCPTransportError.malformedStandardOutput("Child-MCP stdout message did not declare jsonrpc 2.0.")
            }
            guard let responseID = response["id"] else {
                continue
            }
            guard responseID.intValue == expectedID else {
                throw ChildMCPTransportError.malformedStandardOutput("Child-MCP stdout response id did not match request \(expectedID).")
            }
            let result = response["result"]
            let error = try parseBackendError(response["error"])
            if result != nil, error != nil {
                throw ChildMCPTransportError.malformedStandardOutput("Child-MCP stdout response contained both result and error.")
            }
            return (result, error)
        }
    }

    private func readLine(
        from session: ChildMCPProcessSession,
        timeout: TimeInterval,
        timeoutError: ChildMCPTransportError
    ) throws -> Data {
        let resultBox = TimedResultBox<Data>()
        Thread.detachNewThread { [weak self] in
            guard let self else {
                resultBox.store(.failure(ChildMCPTransportError.cancelled))
                return
            }

            do {
                var line = Data()
                while true {
                    if self.isCancelled() {
                        throw ChildMCPTransportError.cancelled
                    }

                    let byte = try session.output.read(upToCount: 1) ?? Data()
                    guard !byte.isEmpty else {
                        if self.isCancelled() {
                            throw ChildMCPTransportError.cancelled
                        }
                        if session.process.isRunning {
                            throw ChildMCPTransportError.unexpectedEndOfStandardOutput
                        }
                        throw ChildMCPTransportError.processExited(session.process.terminationStatus)
                    }

                    if byte == Data([0x0A]) {
                        resultBox.store(.success(line))
                        return
                    }

                    line.append(byte)
                    if line.count > self.configuration.timeouts.maximumResponseBytes {
                        throw ChildMCPTransportError.responseTooLarge(limit: self.configuration.timeouts.maximumResponseBytes)
                    }
                }
            } catch {
                resultBox.store(.failure(error))
            }
        }

        guard resultBox.wait(timeout: timeout) else {
            cancel()
            throw timeoutError
        }

        return try resultBox.value()
    }

    private func parseTools(_ result: WorkflowJSONValue) throws -> [ChildMCPTool] {
        guard case .object(let object) = result,
              case .array(let definitions)? = object["tools"]
        else {
            throw ChildMCPTransportError.malformedStandardOutput("Child-MCP tools/list result must contain a tools array.")
        }

        var names = Set<String>()
        return try definitions.map { definition in
            guard case .object(let object) = definition,
                  let name = object["name"]?.stringValue,
                  !name.isEmpty,
                  names.insert(name).inserted
            else {
                throw ChildMCPTransportError.malformedStandardOutput("Child-MCP tools/list returned an invalid or duplicate tool name.")
            }
            return ChildMCPTool(name: name, definition: definition)
        }
    }

    private func parseBackendError(_ value: WorkflowJSONValue?) throws -> ChildMCPBackendError? {
        guard let value else {
            return nil
        }
        guard case .object(let object) = value,
              let code = object["code"]?.intValue,
              let message = object["message"]?.stringValue
        else {
            throw ChildMCPTransportError.malformedStandardOutput("Child-MCP JSON-RPC error must include integer code and string message.")
        }

        return ChildMCPBackendError(code: code, message: message, data: object["data"])
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !process.isRunning
    }
}

private final class TimedResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }

    func value() throws -> Value {
        lock.lock()
        defer { lock.unlock() }
        guard let result else {
            throw ChildMCPTransportError.unexpectedEndOfStandardOutput
        }
        return try result.get()
    }
}
