import Foundation
import XCTest
@testable import OpenComputerUseWorkflowKit

final class ChildMCPTransportTests: XCTestCase {
    func testStartsDirectProcessInitializesAndListsTools() throws {
        let diagnostics = DiagnosticCollector()
        let transport = try makeTransport(diagnosticSink: diagnostics.append)
        defer { transport.cancel() }

        try transport.start(environment: ["WORKFLOW_MCP_FAKE_UNPERMITTED_FAILURE": "1"])

        XCTAssertEqual(
            transport.discoveredTools.map(\.name),
            ["backend_error", "echo", "hang", "malformed", "oversized"]
        )

        let result = try transport.callTool("echo", arguments: .object(["value": .string("hello")]))
        XCTAssertEqual(result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"], .string("echo"))
        XCTAssertTrue(diagnostics.waitFor(Data("fake-backend diagnostic".utf8), timeout: 1))
    }

    func testRejectsToolOutsideConfiguredDeclarationBeforeDispatch() throws {
        let transport = try makeTransport(declaredTools: ["echo"])
        defer { transport.cancel() }
        try transport.start(environment: [:])

        XCTAssertThrowsError(try transport.callTool("backend_error")) { error in
            XCTAssertEqual(
                error as? ChildMCPTransportError,
                .declaredToolRejected(backendIdentifier: "fixture", toolName: "backend_error")
            )
        }
    }

    func testPreservesBackendJSONRPCError() throws {
        let transport = try makeTransport()
        defer { transport.cancel() }
        try transport.start(environment: [:])

        XCTAssertThrowsError(try transport.callTool("backend_error")) { error in
            XCTAssertEqual(
                error as? ChildMCPTransportError,
                .backendError(
                    ChildMCPBackendError(
                        code: 424,
                        message: "backend refused",
                        data: .object(["reason": .string("fixture")])
                    )
                )
            )
        }
    }

    func testRejectsMalformedBackendStandardOutput() throws {
        let transport = try makeTransport()
        defer { transport.cancel() }
        try transport.start(environment: [:])

        XCTAssertThrowsError(try transport.callTool("malformed")) { error in
            guard case .malformedStandardOutput = error as? ChildMCPTransportError else {
                return XCTFail("Expected malformedStandardOutput, got \(error)")
            }
        }
    }

    func testEnforcesResponseSizeLimit() throws {
        let transport = try makeTransport(timeouts: ChildMCPTimeouts(maximumResponseBytes: 256))
        defer { transport.cancel() }
        try transport.start(environment: [:])

        XCTAssertThrowsError(try transport.callTool("oversized")) { error in
            XCTAssertEqual(error as? ChildMCPTransportError, .responseTooLarge(limit: 256))
        }
    }

    func testEnforcesStartupTimeout() throws {
        let transport = try makeTransport(
            permittedEnvironmentNames: ["WORKFLOW_MCP_FAKE_SLOW_START"],
            timeouts: ChildMCPTimeouts(startup: 0.05, request: 1, shutdown: 0.1)
        )
        defer { transport.cancel() }

        XCTAssertThrowsError(try transport.start(environment: ["WORKFLOW_MCP_FAKE_SLOW_START": "1"])) { error in
            XCTAssertEqual(error as? ChildMCPTransportError, .startupTimedOut("fixture"))
        }
    }

    func testEnforcesRequestTimeoutAndCleansUpChild() throws {
        let transport = try makeTransport(timeouts: ChildMCPTimeouts(startup: 1, request: 0.05, shutdown: 0.1))
        defer { transport.cancel() }
        try transport.start(environment: [:])

        XCTAssertThrowsError(try transport.callTool("hang")) { error in
            XCTAssertEqual(error as? ChildMCPTransportError, .requestTimedOut("fixture"))
        }
        XCTAssertThrowsError(try transport.callTool("echo")) { error in
            XCTAssertEqual(error as? ChildMCPTransportError, .cancelled)
        }
    }

    func testCancelsInFlightRequest() throws {
        let transport = try makeTransport(timeouts: ChildMCPTimeouts(startup: 1, request: 10, shutdown: 0.1))
        try transport.start(environment: [:])
        defer { transport.cancel() }

        let result = ResultCollector()
        Thread.detachNewThread {
            result.store(Result { try transport.callTool("hang") })
        }

        Thread.sleep(forTimeInterval: 0.1)
        transport.cancel()
        XCTAssertTrue(result.wait(timeout: 2))

        XCTAssertEqual(result.error as? ChildMCPTransportError, .cancelled)
    }

    func testShutdownClosesChildWithoutChangingOCUToolServer() throws {
        let transport = try makeTransport()
        try transport.start(environment: [:])
        XCTAssertNoThrow(try transport.shutdown())
    }

    private func makeTransport(
        declaredTools: Set<String> = ["echo", "backend_error", "malformed", "oversized", "hang"],
        permittedEnvironmentNames: Set<String> = [],
        timeouts: ChildMCPTimeouts = ChildMCPTimeouts(startup: 1, request: 1, shutdown: 0.1),
        diagnosticSink: @escaping ChildMCPDiagnosticSink = { _ in }
    ) throws -> ChildMCPTransport {
        try ChildMCPTransport(
            configuration: ChildMCPBackendConfiguration(
                identifier: "fixture",
                executableURL: try fakeBackendURL(),
                permittedEnvironmentVariableNames: permittedEnvironmentNames,
                declaredToolNames: declaredTools,
                timeouts: timeouts,
                diagnosticSink: diagnosticSink
            )
        )
    }

    private func fakeBackendURL() throws -> URL {
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        while directory.pathComponents.count > 1 {
            let candidate = directory.appendingPathComponent("WorkflowMCPFakeBackend")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        throw NSError(domain: "ChildMCPTransportTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "WorkflowMCPFakeBackend executable was not built beside the test bundle."])
    }
}

private final class DiagnosticCollector: @unchecked Sendable {
    private let condition = NSCondition()
    private(set) var data = Data()

    func append(_ diagnostic: ChildMCPDiagnostic) {
        condition.lock()
        data.append(diagnostic.data)
        condition.broadcast()
        condition.unlock()
    }

    func waitFor(_ expected: Data, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }

        while data.range(of: expected) == nil {
            guard condition.wait(until: deadline) else {
                return false
            }
        }

        return true
    }
}

private final class ResultCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var storedResult: Result<WorkflowJSONValue, Error>?

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        guard let storedResult else {
            return nil
        }
        switch storedResult {
        case .success:
            return nil
        case .failure(let error):
            return error
        }
    }

    func store(_ result: Result<WorkflowJSONValue, Error>) {
        lock.lock()
        storedResult = result
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }
}
