import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import XCTest
@testable import OpenComputerUseKit

@MainActor
final class SkyClickAppAgentLiveTests: XCTestCase {
    private struct WindowRecord {
        let id: CGWindowID
        let pid: pid_t
        let bounds: CGRect
        let name: String
    }

    func testCoveredChromeReceivesExactlyOneSkyClickWithoutForegroundSideEffects() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_SKY_CLICK_APP_AGENT_TEST"] == "1" else {
            throw XCTSkip("Set OPEN_COMPUTER_USE_RUN_SKY_CLICK_APP_AGENT_TEST=1 to run the production app-agent Chrome live test")
        }
        let spi = SkyLightSPI.shared
        guard spi.capability.isAvailable else {
            throw XCTSkip("SkyLight SPI unavailable: \(spi.capability.unavailableReason)")
        }

        let chromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        guard FileManager.default.isExecutableFile(atPath: chromeURL.path) else {
            throw XCTSkip("Google Chrome is not installed at the standard path")
        }
        let originalFrontApp = NSWorkspace.shared.frontmostApplication
        defer {
            if let originalFrontApp {
                _ = originalFrontApp.activate(options: [.activateAllWindows])
            }
        }

        let coverExecutable = Self.packageRoot
            .appendingPathComponent(".build/debug/OpenComputerUseFixture")
        guard FileManager.default.isExecutableFile(atPath: coverExecutable.path) else {
            throw XCTSkip("Build OpenComputerUseFixture before running the live test")
        }
        let coverProbe = try launch(executable: coverExecutable)
        defer {
            stop(coverProbe)
        }
        _ = try waitForWindow(
            pid: coverProbe.processIdentifier,
            nameContaining: "OpenComputerUseFixture"
        )

        let testRoot = Self.packageRoot.appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("ocu-sky-click-live-\(UUID().uuidString)", isDirectory: true)
        let profileURL = testRoot.appendingPathComponent("chrome-profile", isDirectory: true)
        let pageURL = testRoot.appendingPathComponent("index.html")
        try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)
        // XCTest's temporary directory can reject Foundation's atomic
        // replace/remove dance after a GUI child process gets access to the
        // parent. This page is disposable, so a direct write is sufficient.
        try Self.liveTestHTML.write(to: pageURL, atomically: false, encoding: .utf8)
        defer {
            do {
                try FileManager.default.removeItem(at: testRoot)
            } catch {
                print("sky_click live test cleanup warning: \(error)")
            }
        }

        let targetWidth = 400
        let targetHeight = 300
        let targetX = 110
        let targetY = 190

        let chrome = Process()
        chrome.executableURL = chromeURL
        chrome.arguments = [
            "--user-data-dir=\(profileURL.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-background-networking",
            "--disable-component-update",
            "--window-position=\(targetX),\(targetY)",
            "--window-size=\(targetWidth),\(targetHeight)",
            "--app=\(pageURL.absoluteString)",
        ]
        chrome.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        let chromeStderr = CappedProcessOutput(limit: 16 * 1024)
        chromeStderr.attach(to: stderrPipe)
        chrome.standardError = stderrPipe
        do {
            try chrome.run()
        } catch {
            chromeStderr.finish()
            let diagnostic = windowReadinessDiagnostic(
                pid: chrome.processIdentifier,
                process: chrome,
                stderr: chromeStderr,
                marker: "launch"
            )
            throw ComputerUseError.message("Chrome launch failed: \(error); \(diagnostic)")
        }
        defer {
            stop(chrome)
            chromeStderr.finish()
        }

        print("sky_click live test: Chrome launcher pid=\(chrome.processIdentifier)")
        let readyWindow = try waitForWindow(
            pid: chrome.processIdentifier,
            nameContaining: "ocu-sky-click-ready",
            process: chrome,
            stderr: chromeStderr
        )
        print("sky_click live test: target window=\(readyWindow.id) owner pid=\(readyWindow.pid)")
        stop(coverProbe)
        let cover = try launch(executable: coverExecutable, quartzFrame: readyWindow.bounds.insetBy(dx: -10, dy: -10))
        defer {
            stop(cover)
        }
        let coverWindow = try waitForWindow(
            pid: cover.processIdentifier,
            nameContaining: "OpenComputerUseFixture"
        )
        try waitUntil(timeout: 5, failure: "Isolated Chrome remained the frontmost app") {
            guard let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
                return false
            }
            return frontPID != readyWindow.pid
        }
        try waitUntil(timeout: 5, failure: "The cover window did not move above isolated Chrome") {
            let ordered = windows()
            guard
                let currentCoverIndex = ordered.firstIndex(where: { $0.id == coverWindow.id }),
                let currentTargetIndex = ordered.firstIndex(where: { $0.id == readyWindow.id })
            else {
                return false
            }
            return currentCoverIndex < currentTargetIndex
        }

        let orderedBefore = windows()
        guard
            let coveredWindow = orderedBefore.first(where: { $0.id == readyWindow.id }),
            let freshCoverWindow = orderedBefore.first(where: { $0.id == coverWindow.id }),
            let coverIndex = orderedBefore.firstIndex(where: { $0.id == coverWindow.id }),
            let targetIndex = orderedBefore.firstIndex(where: { $0.id == readyWindow.id })
        else {
            return XCTFail("Could not re-read the controlled Chrome and cover windows")
        }
        XCTAssertTrue(
            freshCoverWindow.bounds.contains(coveredWindow.bounds),
            "The controlled Chrome window must be fully covered before sky_click"
        )
        XCTAssertLessThan(coverIndex, targetIndex, "The cover window must be above Chrome in z-order")
        try FixtureBridge.post(
            FixtureCommand(kind: "click", identifier: "fixture-input")
        )
        let foregroundStateBefore = try waitForFixtureState(
            pid: cover.processIdentifier,
            failure: "The foreground fixture did not keep its text field focused"
        ) { state in
            state.isActive == true
                && state.isKeyWindow == true
                && state.focusedIdentifier == "fixture-input"
        }
        print(
            "sky_click live test: cover=\(freshCoverWindow.bounds) target=\(coveredWindow.bounds) "
                + "z-order=\(coverIndex)<\(targetIndex) front-pid="
                + "\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)"
        )

        let frontPIDBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let cursorBefore = CGEvent(source: nil)?.location
        let screenPoint = CGPoint(x: coveredWindow.bounds.midX, y: coveredWindow.bounds.midY)
        let windowPoint = CGPoint(
            x: screenPoint.x - coveredWindow.bounds.minX,
            y: screenPoint.y - coveredWindow.bounds.minY
        )

        let target = SkyClickTarget(
            screenPoint: screenPoint,
            windowPoint: windowPoint,
            windowBounds: coveredWindow.bounds,
            windowID: coveredWindow.id,
            pid: coveredWindow.pid
        )
        try runAppAgentClick(target: target)

        let clickedWindow = try waitForWindow(pid: readyWindow.pid, nameContaining: "ocu-sky-click-clicked-")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let finalWindow = windows().first(where: { $0.id == clickedWindow.id })
        XCTAssertEqual(finalWindow?.name, "ocu-sky-click-clicked-1", "sky_click must trigger exactly one DOM click")
        XCTAssertEqual(
            NSWorkspace.shared.frontmostApplication?.processIdentifier,
            frontPIDBefore,
            "sky_click must not change the frontmost app"
        )
        let foregroundStateAfter = try waitForFixtureState(
            pid: cover.processIdentifier,
            failure: "The foreground fixture state was unavailable after sky_click"
        ) { _ in true }
        XCTAssertEqual(foregroundStateAfter.isActive, true, "sky_click must keep the foreground app active")
        XCTAssertEqual(foregroundStateAfter.isKeyWindow, true, "sky_click must keep the foreground window key")
        XCTAssertEqual(
            foregroundStateAfter.focusedIdentifier,
            foregroundStateBefore.focusedIdentifier,
            "sky_click must preserve the foreground first responder"
        )
        XCTAssertEqual(
            foregroundStateAfter.activationLossCount,
            foregroundStateBefore.activationLossCount,
            "sky_click must not transiently resign the foreground app"
        )
        XCTAssertEqual(
            foregroundStateAfter.keyWindowLossCount,
            foregroundStateBefore.keyWindowLossCount,
            "sky_click must not transiently resign the foreground key window"
        )

        if let cursorBefore, let cursorAfter = CGEvent(source: nil)?.location {
            XCTAssertLessThan(hypot(cursorAfter.x - cursorBefore.x, cursorAfter.y - cursorBefore.y), 0.5)
        }

        let orderedAfter = windows()
        guard
            let coverIndexAfter = orderedAfter.firstIndex(where: { $0.id == coverWindow.id }),
            let targetIndexAfter = orderedAfter.firstIndex(where: { $0.id == clickedWindow.id })
        else {
            return XCTFail("Could not verify final window z-order")
        }
        XCTAssertLessThan(coverIndexAfter, targetIndexAfter, "sky_click must not raise the Chrome window")
    }

    private func waitForWindow(
        pid: pid_t? = nil,
        nameContaining marker: String,
        process: Process? = nil,
        stderr: CappedProcessOutput? = nil,
        timeout: TimeInterval = 10
    ) throws -> WindowRecord {
        var match: WindowRecord?
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            match = windows().first(where: { window in
                (pid == nil || window.pid == pid) && window.name.contains(marker)
            })
            if match != nil {
                return try XCTUnwrap(match)
            }
            if let process, !process.isRunning {
                throw ComputerUseError.message(windowReadinessDiagnostic(
                    pid: pid,
                    process: process,
                    stderr: stderr,
                    marker: marker
                ))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw ComputerUseError.message(windowReadinessDiagnostic(
            pid: pid,
            process: process,
            stderr: stderr,
            marker: marker
        ))
    }

    private func waitUntil(
        timeout: TimeInterval,
        failure: String,
        condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw ComputerUseError.message(failure)
    }

    private func waitForFixtureState(
        pid: pid_t,
        failure: String,
        condition: (FixtureAppState) -> Bool
    ) throws -> FixtureAppState {
        var match: FixtureAppState?
        try waitUntil(timeout: 5, failure: failure) {
            guard
                let state = try? FixtureBridge.readState(),
                state.processIdentifier == pid,
                condition(state)
            else {
                return false
            }
            match = state
            return true
        }
        return try XCTUnwrap(match)
    }

    private func runAppAgentClick(target: SkyClickTarget) throws {
        let cli = Self.packageRoot
            .appendingPathComponent(".build/debug/OpenComputerUse")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            throw XCTSkip("Build OpenComputerUse before running the app-agent live test")
        }

        let appBundle = Self.packageRoot
            .appendingPathComponent("dist/Open Computer Use (Dev).app")
        guard FileManager.default.fileExists(atPath: appBundle.path) else {
            throw XCTSkip("Build dist/Open Computer Use (Dev).app before running the app-agent live test")
        }

        let arguments: [String: Any] = [
            "app": "pid:\(target.pid)",
            // The click tool accepts screenshot-local coordinates. The test
            // target also records the global screen point for post-action
            // invariants, but passing it here would make coordinates outside
            // the snapshot window when the window is offset on screen.
            "x": target.windowPoint.x,
            "y": target.windowPoint.y,
            "click_count": 1,
            "mouse_button": "left",
            "click_method": "sky_click",
        ]
        let argumentsData = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        let argumentsJSON = try XCTUnwrap(String(data: argumentsData, encoding: .utf8))
        let process = Process()
        process.executableURL = cli
        process.arguments = ["call", "click", "--args", argumentsJSON]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY")
        environment["OPEN_COMPUTER_USE_AGENT_SOCKET_NAMESPACE"] = "sky-click-app-agent-\(UUID().uuidString)"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let deadline = Date().addingTimeInterval(30)
        while process.isRunning, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ComputerUseError.message(
                "app-agent CLI timed out after 30 seconds; stdout=\(String(reflecting: stdoutText)); stderr=\(String(reflecting: stderrText))"
            )
        }
        process.waitUntilExit()

        let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw ComputerUseError.message(
                "app-agent CLI failed with status \(process.terminationStatus); stdout=\(String(reflecting: stdoutText)); stderr=\(String(reflecting: stderrText))"
            )
        }
        let responseObject = try JSONSerialization.jsonObject(with: Data(stdoutText.utf8))
        let response = try XCTUnwrap(responseObject as? [String: Any])
        guard let isError = response["isError"] as? Bool, !isError else {
            throw ComputerUseError.message(
                "app-agent CLI returned no successful tool result; stdout=\(String(reflecting: stdoutText)); stderr=\(String(reflecting: stderrText))"
            )
        }
        print("sky_click app-agent test: CLI request completed through Open Computer Use.app")
    }

    private func stop(_ process: Process) {
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    private func launch(executable: URL, quartzFrame: CGRect? = nil) throws -> Process {
        let process = Process()
        process.executableURL = executable
        if let quartzFrame {
            process.environment = [
                "OPEN_COMPUTER_USE_FIXTURE_QUARTZ_FRAME":
                    "\(quartzFrame.minX),\(quartzFrame.minY),\(quartzFrame.width),\(quartzFrame.height)",
            ]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func windows() -> [WindowRecord] {
        let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        return rawWindows.compactMap { info in
            guard
                let number = info[kCGWindowNumber as String] as? NSNumber,
                let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                let layer = info[kCGWindowLayer as String] as? NSNumber,
                layer.intValue == 0,
                let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                bounds.width > 0,
                bounds.height > 0
            else {
                return nil
            }

            return WindowRecord(
                id: number.uint32Value,
                pid: ownerPID.int32Value,
                bounds: bounds,
                name: info[kCGWindowName as String] as? String ?? ""
            )
        }
    }

    private static let liveTestHTML = #"""
    <!doctype html>
    <meta charset="utf-8">
    <title>ocu-sky-click-ready</title>
    <style>
      html, body, button { width: 100%; height: 100%; margin: 0; }
      button { border: 0; font: 24px system-ui; background: #5b8def; color: white; }
    </style>
    <button id="target">sky_click probe</button>
    <script>
      let count = 0;
      document.querySelector('#target').addEventListener('click', () => {
        count += 1;
        document.title = `ocu-sky-click-clicked-${count}`;
      });
    </script>
    """#

    private static let packageRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }()
}

private final class CappedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private weak var pipe: Pipe?

    init(limit: Int) {
        self.limit = limit
    }

    func attach(to pipe: Pipe) {
        self.pipe = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData)
        }
    }

    func finish() {
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let pipe, let remaining = try? pipe.fileHandleForReading.readToEnd() {
            append(remaining)
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? "<non-UTF8 stderr>"
    }

    private func append(_ bytes: Data?) {
        guard let bytes, !bytes.isEmpty else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        guard data.count < limit else {
            return
        }
        data.append(bytes.prefix(limit - data.count))
    }
}

private func windowReadinessDiagnostic(
    pid: pid_t?,
    process: Process?,
    stderr: CappedProcessOutput?,
    marker: String
) -> String {
    let rawWindows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] ?? []
    let matchingWindows = rawWindows.compactMap { info -> (id: UInt32, pid: pid_t, name: String, bounds: CGRect)? in
        guard
            let number = info[kCGWindowNumber as String] as? NSNumber,
            let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
            let layer = info[kCGWindowLayer as String] as? NSNumber,
            layer.intValue == 0,
            let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
            bounds.width > 0,
            bounds.height > 0,
            pid == nil || ownerPID.int32Value == pid
        else {
            return nil
        }
        return (number.uint32Value, ownerPID.int32Value, info[kCGWindowName as String] as? String ?? "", bounds)
    }
    let guiSession = CGSessionCopyCurrentDictionary() as? [String: Any]
    let onConsole = guiSession?[kCGSessionOnConsoleKey as String] as? Bool ?? false
    let loginDone = guiSession?[kCGSessionLoginDoneKey as String] as? Bool ?? false
    let userID = guiSession?[kCGSessionUserIDKey as String] as? Int ?? -1
    let hasGUISession = onConsole && loginDone && userID >= 0 && CGMainDisplayID() != 0
    let reason: String
    if !hasGUISession {
        reason = "missing-gui-session"
    } else if let process, !process.isRunning {
        reason = "early-exit"
    } else if !AXIsProcessTrusted() || !CGPreflightScreenCaptureAccess() {
        reason = "permission-suspected"
    } else if matchingWindows.isEmpty {
        reason = "missing-window"
    } else {
        reason = "missing-title"
    }
    let observed = matchingWindows.map {
        "id=\($0.id),pid=\($0.pid),name=\(String(reflecting: $0.name)),bounds=\($0.bounds)"
    }.joined(separator: "; ")
    let processState: String
    if let process {
        if process.isRunning {
            processState = "running=true,status=unavailable,termination-reason=unavailable"
        } else {
            processState = "running=false,status=\(process.terminationStatus),termination-reason=\(process.terminationReason.rawValue)"
        }
    } else {
        processState = "not-observed"
    }
    return [
        "Chrome window readiness failure (reason=\(reason), marker=\(marker))",
        "pid=\(pid.map(String.init) ?? "unknown")",
        "process=\(processState)",
        "gui-session=on-console:\(onConsole),login-done:\(loginDone),user-id:\(userID),display:\(CGMainDisplayID())",
        "accessibility-trusted=\(AXIsProcessTrusted())",
        "screen-recording=\(CGPreflightScreenCaptureAccess())",
        "windows=[\(observed)]",
        "stderr=\(String(reflecting: stderr?.text ?? ""))",
    ].joined(separator: "; ")
}
