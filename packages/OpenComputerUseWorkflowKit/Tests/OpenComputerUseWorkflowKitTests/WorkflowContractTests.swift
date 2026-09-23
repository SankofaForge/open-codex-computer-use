import Foundation
import XCTest
@testable import OpenComputerUseWorkflowKit

final class WorkflowContractTests: XCTestCase {
    func testWorkflowControlEnvelopeUsesVersionedStableShape() throws {
        let envelope = WorkflowControlEnvelope(
            runId: "run-1",
            stage: .captureSiteMotion,
            status: .partial,
            gaps: [WorkflowGap(code: "capture-matrix", message: "mobile reduced capture is pending", required: true)]
        )
        let object = try jsonObject(envelope)

        XCTAssertEqual(object["schemaVersion"] as? String, "workflow-control.v2")
        XCTAssertEqual(object["stage"] as? String, "capture_site_motion")
        XCTAssertEqual(object["status"] as? String, "partial")
        XCTAssertEqual((object["gaps"] as? [[String: Any]])?.count, 1)
    }

    func testConfigurationRejectsCredentialsAndWrappedOpenDesign() {
        XCTAssertThrowsError(try WorkflowBackendConfiguration(
            kind: .designInspiration,
            command: "node",
            arguments: ["API_KEY=secret"],
            declaredTools: ["design_search_references"]
        ).validate())
        XCTAssertThrowsError(try WorkflowBackendConfiguration(
            kind: .openDesign,
            command: "od",
            declaredTools: ["od_web_effect_extractor"],
            launchPolicy: .secretWrapper
        ).validate())
    }

    func testBrowserUseCaptureBackendHasStableRawValue() {
        XCTAssertEqual(WorkflowBackendKind.browserUseCapture.rawValue, "browser-use-capture")
    }

    func testBrowserUseCaptureRejectsManualCompatibilityOverride() {
        XCTAssertThrowsError(try WorkflowBackendConfiguration(
            kind: .browserUseCapture,
            command: "browser-use-capture-mcp",
            permittedEnvironmentVariables: browserUseEnvironmentVariables + ["BROWSER_USE_CAPTURE_COMPATIBLE"],
            declaredTools: ["check_capture_gpu", "capture_site_motion"]
        ).validate())
    }

    func testBrowserUseCaptureRequiresExactlyItsRunnerEnvironmentNames() {
        XCTAssertNoThrow(try WorkflowBackendConfiguration(
            kind: .browserUseCapture,
            command: "browser-use-capture-mcp",
            permittedEnvironmentVariables: browserUseEnvironmentVariables,
            declaredTools: ["check_capture_gpu", "capture_site_motion"]
        ).validate())

        XCTAssertThrowsError(try WorkflowBackendConfiguration(
            kind: .browserUseCapture,
            command: "browser-use-capture-mcp",
            permittedEnvironmentVariables: Array(browserUseEnvironmentVariables.dropLast()),
            declaredTools: ["check_capture_gpu", "capture_site_motion"]
        ).validate()) { error in
            XCTAssertEqual((error as? WorkflowContractError)?.code, .invalidConfiguration)
        }

        XCTAssertThrowsError(try WorkflowBackendConfiguration(
            kind: .browserUseCapture,
            command: "browser-use-capture-mcp",
            permittedEnvironmentVariables: browserUseEnvironmentVariables + ["UNRELATED_CAPTURE_VALUE"],
            declaredTools: ["check_capture_gpu", "capture_site_motion"]
        ).validate()) { error in
            XCTAssertEqual((error as? WorkflowContractError)?.code, .invalidConfiguration)
        }
    }

    func testBrowserUseTreatsChromiumPathAsEnvironmentNameOnly() {
        XCTAssertTrue(browserUseEnvironmentVariables.contains("BROWSER_USE_CHROMIUM_PATH"))
        XCTAssertThrowsError(try WorkflowBackendConfiguration(
            kind: .browserUseCapture,
            command: "browser-use-capture-mcp",
            arguments: ["BROWSER_USE_CHROMIUM_PATH=/usr/bin/chromium"],
            permittedEnvironmentVariables: browserUseEnvironmentVariables,
            declaredTools: ["check_capture_gpu", "capture_site_motion"]
        ).validate()) { error in
            XCTAssertEqual((error as? WorkflowContractError)?.code, .invalidConfiguration)
        }
    }

    func testExplicitCaptureBackendMustBeSupportedAndConfigured() throws {
        XCTAssertThrowsError(try WorkflowConfiguration(
            workspaceRoot: ".",
            backends: [],
            captureBackend: .siteMotionCapture
        ).validate()) { error in
            XCTAssertEqual((error as? WorkflowContractError)?.code, .invalidConfiguration)
        }

        XCTAssertThrowsError(try WorkflowConfiguration(
            workspaceRoot: ".",
            backends: [],
            captureBackend: .assetRouting
        ).validate()) { error in
            XCTAssertEqual((error as? WorkflowContractError)?.code, .invalidConfiguration)
        }
    }

    func testWorkflowConfigurationLoadsManualCaptureBackendSelection() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-mcp-config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: path) }

        let configurationJSON = """
        {
          "workspaceRoot": ".",
          "captureBackend": "site-motion-capture",
          "backends": [
            {
              "kind": "site-motion-capture",
              "command": "site-motion-capture-mcp",
              "arguments": [],
              "workingDirectory": ".",
              "permittedEnvironmentVariables": [],
              "declaredTools": ["check_capture_gpu", "capture_site_motion"],
              "launchPolicy": "direct"
            }
          ]
        }
        """
        try Data(configurationJSON.utf8).write(to: path)

        let configuration = try WorkflowConfiguration.load(path: path.path)
        XCTAssertEqual(configuration.captureBackend, .siteMotionCapture)
    }

    func testValidVisualImplementationFixturePasses() throws {
        let fixture = try WorkflowFixture.make()
        let report = try WorkflowEvidenceValidator.validateManifest(fixture.manifest, workspaceRoot: fixture.root)

        XCTAssertEqual(report.manifestStatus, .complete)
        XCTAssertEqual(report.captureCellCount, 4)
        XCTAssertEqual(report.analysisCount, 4)
        XCTAssertEqual(report.readyAssetRouteCount, 1)
    }

    func testPartialAndBlockedFixturesAreAcceptedWithRequiredReasons() throws {
        let partial = try WorkflowFixture.make(profile: "nonvisual")
        partial.manifest["status"] = "partial"
        partial.manifest["profileReason"] = "The task has no visual implementation."
        partial.manifest["openDesign"] = ["status": "skipped", "reason": "No visual output", "exemption": true]
        XCTAssertEqual(try WorkflowEvidenceValidator.validateManifest(partial.manifest, workspaceRoot: partial.root).manifestStatus, .partial)

        let blocked = try WorkflowFixture.make()
        blocked.manifest["status"] = "blocked"
        blocked.manifest["blockedReason"] = "Capture backend is unavailable."
        XCTAssertEqual(try WorkflowEvidenceValidator.validateManifest(blocked.manifest, workspaceRoot: blocked.root).manifestStatus, .blocked)
    }

    func testStaleHashAndWorkspaceEscapeAreRejected() throws {
        let fixture = try WorkflowFixture.make()
        var stale = fixture.manifest
        var capture = stale["capture"] as! [String: Any]
        var cells = capture["matrix"] as! [[String: Any]]
        var artifacts = cells[0]["artifacts"] as! [[String: Any]]
        artifacts[0]["sha256"] = String(repeating: "0", count: 64)
        cells[0]["artifacts"] = artifacts
        capture["matrix"] = cells
        stale["capture"] = capture
        XCTAssertThrowsError(try WorkflowEvidenceValidator.validateManifest(stale, workspaceRoot: fixture.root)) { error in
            XCTAssertEqual((error as? WorkflowContractError)?.code, .artifactHashMismatch)
        }

        var escaped = fixture.manifest
        var topArtifacts = escaped["artifacts"] as! [[String: Any]]
        topArtifacts[0]["path"] = "../outside.txt"
        escaped["artifacts"] = topArtifacts
        XCTAssertThrowsError(try WorkflowEvidenceValidator.validateManifest(escaped, workspaceRoot: fixture.root)) { error in
            XCTAssertEqual((error as? WorkflowContractError)?.code, .artifactOutsideWorkspace)
        }
    }

    func testV1AndMissingVisualMatrixAreRejected() throws {
        let v1 = try WorkflowFixture.make()
        v1.manifest["schemaVersion"] = "workflow-manifest.v1"
        XCTAssertThrowsError(try WorkflowEvidenceValidator.validateManifest(v1.manifest, workspaceRoot: v1.root)) { error in
            XCTAssertEqual((error as? WorkflowContractError)?.code, .unsupportedSchema)
        }

        let missingMatrix = try WorkflowFixture.make()
        var capture = missingMatrix.manifest["capture"] as! [String: Any]
        capture["matrix"] = Array((capture["matrix"] as! [[String: Any]]).dropLast())
        missingMatrix.manifest["capture"] = capture
        XCTAssertThrowsError(try WorkflowEvidenceValidator.validateManifest(missingMatrix.manifest, workspaceRoot: missingMatrix.root)) { error in
            XCTAssertEqual((error as? WorkflowContractError)?.code, .incompleteMatrix)
        }
    }

    func testVisualImplementationRequiresOpenDesignAndReadyAssetRoutes() throws {
        let missingOpenDesign = try WorkflowFixture.make()
        missingOpenDesign.manifest["openDesign"] = ["status": "skipped", "reason": "not now", "exemption": true]
        XCTAssertThrowsError(try WorkflowEvidenceValidator.validateManifest(missingOpenDesign.manifest, workspaceRoot: missingOpenDesign.root)) { error in
            XCTAssertEqual((error as? WorkflowContractError)?.code, .openDesignRequired)
        }

        let blockedAsset = try WorkflowFixture.make()
        blockedAsset.manifest["assetRoutes"] = [[
            "assetId": "hero-model",
            "requestedRoute": "https://routes.example/blender",
            "actualRoute": "https://routes.example/blender",
            "status": "blocked",
            "capability": ["id": "blender", "available": false],
            "acceptance": ["format": "glb"],
            "blockedReason": "Blender is unavailable.",
        ]]
        XCTAssertThrowsError(try WorkflowEvidenceValidator.validateManifest(blockedAsset.manifest, workspaceRoot: blockedAsset.root)) { error in
            XCTAssertEqual((error as? WorkflowContractError)?.code, .assetRouteBlocked)
        }
    }
}

private let browserUseEnvironmentVariables = [
    "VAST_INSTANCE_ID",
    "VAST_API_KEY",
    "BROWSER_USE_CHROMIUM_PATH",
]

private final class WorkflowFixture {
    let root: URL
    var manifest: [String: Any]

    private init(root: URL, manifest: [String: Any]) {
        self.root = root
        self.manifest = manifest
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    static func make(profile: String = "visual-implementation") throws -> WorkflowFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ocu-workflow-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var cells: [[String: Any]] = []
        var analyses: [[String: Any]] = []
        let frame = try artifact(root: root, path: "artifacts/design-inspiration/site-motion-capture/frame.png", contents: "frame")
        for (index, pair) in [("desktop", "full"), ("desktop", "reduced"), ("mobile", "full"), ("mobile", "reduced")].enumerated() {
            let capture = try artifact(root: root, path: "artifacts/design-inspiration/site-motion-capture/capture-\(index).webm", contents: "capture \(index)")
            let cellID = "cell-\(index)"
            let finalURL = "https://preview.example/\(cellID)"
            cells.append([
                "cellId": cellID,
                "viewport": pair.0,
                "motionMode": pair.1,
                "status": "complete",
                "width": pair.0 == "desktop" ? 1920 : 390,
                "height": pair.0 == "desktop" ? 1080 : 844,
                "runId": "capture-\(index)",
                "finalUrl": finalURL,
                "artifacts": [capture],
            ])
            analyses.append([
                "schemaVersion": "motion-analysis.v2",
                "description": "Observed loading motion.",
                "source": [
                    "mode": "native-video",
                    "artifactPath": capture["path"]!,
                    "sha256": capture["sha256"]!,
                    "durationSeconds": 8.0,
                    "captureRunId": "capture-\(index)",
                    "cellId": cellID,
                ],
                "provenance": ["sourceUrl": finalURL, "viewport": pair.0, "motionMode": pair.1],
                "moments": [["timestampSeconds": 1.0, "why": "Hero enters", "framePath": frame["path"]!, "frameSha256": frame["sha256"]!]],
                "uncertainties": [],
                "gaps": [],
            ])
        }
        let design = try artifact(root: root, path: "artifacts/design-inspiration/open-design/design.html", contents: "<main>design</main>")
        let asset = try artifact(root: root, path: "artifacts/design-inspiration/assets/hero.glb", contents: "asset")
        let manifest: [String: Any] = [
            "schemaVersion": "workflow-manifest.v2",
            "taskProfile": profile,
            "workspace": ["root": root.path],
            "reference": ["url": "https://www.awwwards.com/example", "liveUrl": "https://preview.example"],
            "capture": ["matrix": cells],
            "artifacts": [frame],
            "analysis": ["entries": analyses],
            "frames": [frame.merging(["timestampSeconds": 1.0]) { _, new in new }],
            "openDesign": [
                "status": "used",
                "designArtifact": design,
                "redactedInputs": ["https://preview.example", "DESIGN.md", "frame-001.png"],
                "capability": ["id": "open-design", "available": true],
            ],
            "assetRoutes": [[
                "assetId": "hero-model",
                "requestedRoute": "https://routes.example/blender",
                "actualRoute": "https://routes.example/blender",
                "status": "ready",
                "capability": ["id": "blender", "available": true],
                "acceptance": ["format": "glb"],
                "outputs": [asset],
                "validatedOutputs": [asset],
                "reducedMotion": ["staticFallback": "hero.png"],
            ]],
            "status": "complete",
        ]
        return WorkflowFixture(root: root, manifest: manifest)
    }

    private static func artifact(root: URL, path: String, contents: String) throws -> [String: Any] {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(contents.utf8)
        try data.write(to: file)
        let hash = WorkflowSHA256.hexDigest(data)
        return ["path": path, "size": data.count, "sha256": hash, "nonEmpty": true]
    }
}

private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
