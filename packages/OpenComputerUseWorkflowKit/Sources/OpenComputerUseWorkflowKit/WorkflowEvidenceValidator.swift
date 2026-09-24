import Foundation
import CoreFoundation

public struct WorkflowEvidenceValidationReport: Equatable, Sendable {
    public let manifestStatus: WorkflowRunStatus
    public let captureCellCount: Int
    public let analysisCount: Int
    public let readyAssetRouteCount: Int

    public init(manifestStatus: WorkflowRunStatus, captureCellCount: Int, analysisCount: Int, readyAssetRouteCount: Int) {
        self.manifestStatus = manifestStatus
        self.captureCellCount = captureCellCount
        self.analysisCount = analysisCount
        self.readyAssetRouteCount = readyAssetRouteCount
    }
}

public enum WorkflowEvidenceValidator {
    public static func validateManifest(data: Data, workspaceRoot: URL, expectedAssetIDs: Set<String>? = nil) throws -> WorkflowEvidenceValidationReport {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let manifest = raw as? [String: Any] else {
            throw WorkflowContractError(.invalidEvidence, "workflow manifest must be a JSON object")
        }
        return try validateManifest(manifest, workspaceRoot: workspaceRoot, expectedAssetIDs: expectedAssetIDs)
    }

    public static func validateManifest(_ manifest: [String: Any], workspaceRoot: URL, expectedAssetIDs: Set<String>? = nil) throws -> WorkflowEvidenceValidationReport {
        try exactKeys(manifest, allowed: [
            "schemaVersion", "taskProfile", "profileReason", "workspace", "reference", "capture", "artifacts",
            "analysis", "frames", "openDesign", "assetRoutes", "status", "blockedReason",
        ], label: "workflow manifest")
        try require(manifest.string("schemaVersion") == WorkflowContractVersion.manifest, .unsupportedSchema, "unsupported schemaVersion")
        let profile = try manifest.requiredEnum("taskProfile", values: ["visual-implementation", "evidence-only", "token-only", "nonvisual"])
        let root = try verifiedWorkspaceRoot(manifest.requiredObject("workspace"), expected: workspaceRoot)
        let reference = try manifest.requiredObject("reference")
        try exactKeys(reference, allowed: ["url", "liveUrl", "tokenProvenance"], label: "reference")
        try safeHTTPURL(reference.requiredString("url"), label: "reference.url")
        try safeHTTPURL(reference.requiredString("liveUrl"), label: "reference.liveUrl")
        if profile == "token-only" {
            try require(reference["tokenProvenance"] is [String: Any], .invalidEvidence, "token-only requires token provenance")
        }

        let capture = try manifest.requiredObject("capture")
        try exactKeys(capture, allowed: ["matrix"], label: "capture")
        let cells = try capture.requiredArray("matrix")
        var cellsByID: [String: [String: Any]] = [:]
        var matrix = Set<String>()
        var captureArtifacts = Set<String>()
        var incompleteCapture = false

        for rawCell in cells {
            let cell = try object(rawCell, label: "capture cell")
            try exactKeys(cell, allowed: ["cellId", "viewport", "motionMode", "status", "width", "height", "runId", "finalUrl", "artifacts", "blockedReason"], label: "capture cell")
            let cellID = try cell.requiredString("cellId")
            try require(cellsByID[cellID] == nil, .invalidEvidence, "capture cell IDs must be unique")
            let viewport = try cell.requiredEnum("viewport", values: ["desktop", "mobile"])
            let mode = try cell.requiredEnum("motionMode", values: ["full", "reduced"])
            try require(matrix.insert("\(viewport):\(mode)").inserted, .invalidEvidence, "capture matrix contains duplicate cells")
            let status = try cell.requiredEnum("status", values: ["complete", "partial", "blocked"])
            incompleteCapture = incompleteCapture || status != "complete"
            _ = try positiveInteger(cell["width"], label: "capture width")
            _ = try positiveInteger(cell["height"], label: "capture height")
            _ = try cell.requiredString("runId")
            try safeHTTPURL(cell.requiredString("finalUrl"), label: "capture finalUrl")
            let artifacts = try cell.requiredArray("artifacts")
            if status == "complete" {
                try require(artifacts.count >= 3, .invalidEvidence, "complete capture cells require WebM, jank, and capture-cell artifacts")
            }
            if status == "blocked" {
                _ = try cell.requiredString("blockedReason")
            }
            var validatedCellArtifacts: [[String: Any]] = []
            for rawArtifact in artifacts {
                let artifact = try object(rawArtifact, label: "capture artifact")
                let hash = try validateArtifact(artifact, workspaceRoot: root)
                let artifactPath = try artifact.requiredString("path")
                validatedCellArtifacts.append(artifact)
                let key = "\(artifactPath):\(hash)"
                try require(captureArtifacts.insert(key).inserted, .invalidEvidence, "capture artifacts must not be reused across cells")
            }
            if status == "complete" {
                try validateCaptureCellEvidence(
                    artifacts: validatedCellArtifacts,
                    cell: cell,
                    workspaceRoot: root,
                    cellID: cellID,
                    runID: try cell.requiredString("runId"),
                    finalURL: try cell.requiredString("finalUrl"),
                    viewport: viewport,
                    motionMode: mode,
                    width: try positiveInteger(cell["width"], label: "capture width"),
                    height: try positiveInteger(cell["height"], label: "capture height")
                )
            }
            cellsByID[cellID] = cell
        }

        if profile == "visual-implementation" {
            try require(matrix == Set(["desktop:full", "desktop:reduced", "mobile:full", "mobile:reduced"]), .incompleteMatrix, "visual implementation requires four distinct cells")
        }
        for rawArtifact in try manifest.requiredArray("artifacts") {
            _ = try validateArtifact(try object(rawArtifact, label: "artifact"), workspaceRoot: root)
        }

        var frameHashes = Set<String>()
        var framePairs = Set<String>()
        for rawFrame in try manifest.requiredArray("frames") {
            let frame = try object(rawFrame, label: "frame")
            try exactKeys(frame, allowed: ["path", "size", "sha256", "nonEmpty", "kind", "timestampSeconds"], label: "frame")
            _ = try finiteNumber(frame["timestampSeconds"], label: "frame timestampSeconds", minimum: 0)
            let hash = try validateArtifact(frame, workspaceRoot: root, allowTimestampSeconds: true)
            frameHashes.insert(hash)
            framePairs.insert("\(try frame.requiredString("path")):\(hash)")
        }

        let analysisContainer = try manifest.requiredObject("analysis")
        try exactKeys(analysisContainer, allowed: ["entries"], label: "analysis")
        let analyses = try analysisContainer.requiredArray("entries")
        var analyzedCellIDs = Set<String>()
        var hasRequiredGap = false
        for rawAnalysis in analyses {
            let analysis = try object(rawAnalysis, label: "motion analysis")
            let result = try validateMotionAnalysis(analysis)
            let source = try analysis.requiredObject("source")
            let provenance = try analysis.requiredObject("provenance")
            let cellID = try source.requiredString("cellId")
            guard let cell = cellsByID[cellID] else {
                throw WorkflowContractError(.invalidEvidence, "analysis must reference an existing capture cell")
            }
            try require(analyzedCellIDs.insert(cellID).inserted, .invalidEvidence, "each capture cell may have one analysis")
            try require(provenance["sourceUrl"] as? String == cell["finalUrl"] as? String, .invalidEvidence, "analysis source URL does not match cell")
            try require(provenance["viewport"] as? String == cell["viewport"] as? String, .invalidEvidence, "analysis viewport does not match cell")
            try require(provenance["motionMode"] as? String == cell["motionMode"] as? String, .invalidEvidence, "analysis motion mode does not match cell")
            let sourceHash = try source.requiredString("sha256")
            let cellHashes = try (cell.requiredArray("artifacts")).map { try object($0, label: "capture artifact").requiredString("sha256") }
            try require(cellHashes.contains(sourceHash), .invalidEvidence, "analysis source hash is not declared by its cell")
            let sourcePath = try source.requiredString("artifactPath")
            let cellPaths = try (cell.requiredArray("artifacts")).map { try object($0, label: "capture artifact").requiredString("path") }
            try require(cellPaths.contains(sourcePath), .invalidEvidence, "analysis source path is not declared by its cell")
            try require(source["captureRunId"] as? String == cell["runId"] as? String, .invalidEvidence, "analysis captureRunId does not match cell runId")
            for hash in result.momentFrameHashes {
                try require(frameHashes.contains(hash), .invalidEvidence, "moment frame hash is not declared")
            }
            for rawMoment in try analysis.requiredArray("moments") {
                let moment = try object(rawMoment, label: "motion moment")
                let framePath = try moment.requiredString("framePath")
                let frameHash = try moment.requiredString("frameSha256")
                try require(framePairs.contains("\(framePath):\(frameHash)"), .invalidEvidence, "moment frame path and hash are not declared together")
            }
            hasRequiredGap = hasRequiredGap || result.hasRequiredGap
        }
        if profile == "visual-implementation" || profile == "evidence-only" {
            try require(analyses.count == cells.count, .invalidEvidence, "every capture cell requires exactly one analysis")
        }
        if profile == "visual-implementation" {
            try require(analyses.count == 4, .incompleteMatrix, "visual implementation requires four analyses")
        }
        if profile == "nonvisual" { _ = try manifest.requiredString("profileReason") }

        let openDesign = try manifest.requiredObject("openDesign")
        try exactKeys(openDesign, allowed: ["status", "designArtifact", "redactedInputs", "capability", "reason", "exemption", "blockedReason"], label: "openDesign")
        let openDesignStatus = try openDesign.requiredEnum("status", values: ["used", "skipped", "blocked"])
        if profile == "visual-implementation" {
            try require(openDesignStatus == "used", .openDesignRequired, "visual implementation requires Open Design")
        }
        switch openDesignStatus {
        case "used":
            _ = try validateArtifact(try openDesign.requiredObject("designArtifact"), workspaceRoot: root)
            let inputs = try openDesign.requiredArray("redactedInputs")
            try require(!inputs.isEmpty, .invalidEvidence, "Open Design redactedInputs is required")
            for input in inputs {
                try validateRedactedOpenDesignInput(try nonEmptyString(input, label: "Open Design redacted input"))
            }
            try require(openDesign["capability"] is [String: Any], .invalidEvidence, "Open Design capability evidence is required")
        case "skipped":
            _ = try openDesign.requiredString("reason")
            try require(openDesign["exemption"] as? Bool == true, .invalidEvidence, "skipped Open Design requires an exemption")
        default:
            _ = try openDesign.requiredString("blockedReason")
        }

        var readyRoutes = 0
        var blockedRoute = false
        for rawRoute in try manifest.requiredArray("assetRoutes") {
            let route = try object(rawRoute, label: "asset route")
            try exactKeys(route, allowed: ["assetId", "requestedRoute", "actualRoute", "status", "capability", "acceptance", "outputs", "validatedOutputs", "reducedMotion", "blockedReason"], label: "asset route")
            _ = try route.requiredString("assetId")
            let requestedRoute = try route.requiredString("requestedRoute")
            let actualRoute = try route.requiredString("actualRoute")
            try safeHTTPURL(requestedRoute, label: "asset requestedRoute")
            try safeHTTPURL(actualRoute, label: "asset actualRoute")
            try validateAssetRouteContract(route, requested: requestedRoute, actual: actualRoute)
            let status = try route.requiredEnum("status", values: ["ready", "blocked"])
            try require(route["capability"] is [String: Any], .invalidEvidence, "asset capability evidence is required")
            try require(route["acceptance"] is [String: Any], .invalidEvidence, "asset route acceptance is required")
            if status == "ready" {
                readyRoutes += 1
                let outputs = try route.requiredArray("outputs")
                let validated = try route.requiredArray("validatedOutputs")
                try require(!outputs.isEmpty && !validated.isEmpty, .invalidEvidence, "ready asset routes require outputs and validatedOutputs")
                for rawArtifact in outputs + validated {
                    _ = try validateArtifact(try object(rawArtifact, label: "asset output"), workspaceRoot: root)
                }
                try require(route["reducedMotion"] is [String: Any], .invalidEvidence, "ready routes require reduced-motion evidence")
            } else {
                blockedRoute = true
                _ = try route.requiredString("blockedReason")
            }
        }

        if profile == "visual-implementation", let expectedAssetIDs {
            let actualAssetIDs = Set(try manifest.requiredArray("assetRoutes").map {
                try object($0, label: "asset route").requiredString("assetId")
            })
            try require(actualAssetIDs == expectedAssetIDs, .invalidEvidence, "asset route IDs do not match the prepared asset plan")
        }

        let finalStatus = try WorkflowRunStatus(rawValue: manifest.requiredEnum("status", values: ["complete", "partial", "blocked"])) ?? .partial
        if finalStatus == .complete {
            try require(!hasRequiredGap, .invalidEvidence, "required analysis gaps prevent complete status")
            try require(!incompleteCapture, .invalidEvidence, "complete manifests cannot contain incomplete cells")
            try require(!blockedRoute, .assetRouteBlocked, "complete manifests cannot contain blocked asset routes")
        }
        if finalStatus == .blocked { _ = try manifest.requiredString("blockedReason") }
        return WorkflowEvidenceValidationReport(manifestStatus: finalStatus, captureCellCount: cells.count, analysisCount: analyses.count, readyAssetRouteCount: readyRoutes)
    }

    public static func validateMotionAnalysis(_ analysis: [String: Any]) throws -> MotionAnalysisValidationResult {
        try exactKeys(analysis, allowed: ["schemaVersion", "description", "source", "provenance", "moments", "uncertainties", "gaps"], label: "motion analysis")
        try require(analysis.string("schemaVersion") == WorkflowContractVersion.motionAnalysis, .unsupportedSchema, "unsupported motion-analysis schemaVersion")
        _ = try analysis.requiredString("description")
        let source = try analysis.requiredObject("source")
        try exactKeys(source, allowed: ["mode", "artifactPath", "sha256", "durationSeconds", "captureRunId", "cellId"], label: "motion source")
        _ = try source.requiredEnum("mode", values: ["native-video", "timestamped-frames"])
        _ = try source.requiredString("artifactPath")
        try sha256(source.requiredString("sha256"), label: "motion source sha256")
        let duration = try finiteNumber(source["durationSeconds"], label: "source.durationSeconds", minimumExclusive: 0, maximum: 3600)
        _ = try source.requiredString("captureRunId")
        _ = try source.requiredString("cellId")
        let provenance = try analysis.requiredObject("provenance")
        try exactKeys(provenance, allowed: ["sourceUrl", "viewport", "motionMode"], label: "motion provenance")
        try safeHTTPURL(provenance.requiredString("sourceUrl"), label: "motion sourceUrl")
        _ = try provenance.requiredString("viewport")
        _ = try provenance.requiredEnum("motionMode", values: ["full", "reduced"])

        let moments = try analysis.requiredArray("moments")
        try require(moments.count <= 8, .invalidEvidence, "moments must contain at most eight entries")
        var timestamps: [Double] = []
        var frameHashes = Set<String>()
        for rawMoment in moments {
            let moment = try object(rawMoment, label: "motion moment")
            try exactKeys(moment, allowed: ["timestampSeconds", "why", "framePath", "frameSha256"], label: "motion moment")
            let timestamp = try finiteNumber(moment["timestampSeconds"], label: "moment.timestampSeconds", minimum: 0, maximum: duration)
            _ = try moment.requiredString("why")
            _ = try moment.requiredString("framePath")
            let frameHash = try moment.requiredString("frameSha256")
            try sha256(frameHash, label: "moment frameSha256")
            timestamps.append(timestamp)
            frameHashes.insert(frameHash)
        }
        try require(timestamps == timestamps.sorted(), .invalidEvidence, "moment timestamps must be sorted")
        try require(Set(timestamps).count == timestamps.count, .invalidEvidence, "moment timestamps must be unique")
        for value in try analysis.requiredArray("uncertainties") { _ = try nonEmptyString(value, label: "uncertainty") }
        var previousEnd = 0.0
        var hasRequiredGap = false
        for rawGap in try analysis.requiredArray("gaps") {
            let gap = try object(rawGap, label: "motion gap")
            try exactKeys(gap, allowed: ["startSeconds", "endSeconds", "reason", "severity"], label: "motion gap")
            let start = try finiteNumber(gap["startSeconds"], label: "gap.startSeconds", minimum: 0)
            let end = try finiteNumber(gap["endSeconds"], label: "gap.endSeconds", minimumExclusive: 0, maximum: duration)
            try require(previousEnd <= start && start < end, .invalidEvidence, "gaps must be ordered, non-overlapping, and within duration")
            _ = try gap.requiredString("reason")
            let severity = try gap.requiredEnum("severity", values: ["informational", "required"])
            hasRequiredGap = hasRequiredGap || severity == "required"
            previousEnd = end
        }
        return MotionAnalysisValidationResult(momentFrameHashes: frameHashes, hasRequiredGap: hasRequiredGap)
    }
}

private func validateCaptureCellEvidence(
    artifacts: [[String: Any]],
    cell: [String: Any],
    workspaceRoot: URL,
    cellID: String,
    runID: String,
    finalURL: String,
    viewport: String,
    motionMode: String,
    width: Int,
    height: Int
) throws {
    func artifact(suffix: String) throws -> [String: Any] {
        guard let match = artifacts.first(where: { (($0["path"] as? String) ?? "").hasSuffix(suffix) }) else {
            throw WorkflowContractError(.invalidEvidence, "complete capture cell requires a \(suffix) artifact")
        }
        return match
    }
    let video = try artifact(suffix: ".webm")
    let jank = try artifact(suffix: ".jank.json")
    let captureManifest = try artifact(suffix: ".capture-cell.v2.json")
    let manifestPath = try captureManifest.requiredString("path")
    let manifestURL = workspaceRoot.appendingPathComponent(manifestPath).resolvingSymlinksInPath().standardizedFileURL
    let captureData = try Data(contentsOf: manifestURL)
    guard let capture = try JSONSerialization.jsonObject(with: captureData) as? [String: Any] else {
        throw WorkflowContractError(.invalidEvidence, "capture-cell.v2 artifact must be a JSON object")
    }
    try require(capture["contractVersion"] as? String == "capture-cell.v2", .unsupportedSchema, "unsupported capture-cell contractVersion")
    try require(capture["runId"] as? String == runID, .invalidEvidence, "capture-cell runId does not match workflow cell")
    try require(capture["cellId"] as? String == cellID, .invalidEvidence, "capture-cell cellId does not match workflow cell")
    try require(capture["finalUrl"] as? String == finalURL, .invalidEvidence, "capture-cell finalUrl does not match workflow cell")
    try require(capture["status"] as? String == "complete", .invalidEvidence, "capture-cell manifest is not complete")
    let viewportEvidence = try capture.requiredObject("viewport")
    let evidenceWidth = try positiveInteger(viewportEvidence["width"], label: "capture-cell viewport width")
    let evidenceHeight = try positiveInteger(viewportEvidence["height"], label: "capture-cell viewport height")
    try require(evidenceWidth == width, .invalidEvidence, "capture-cell viewport width does not match workflow cell")
    try require(evidenceHeight == height, .invalidEvidence, "capture-cell viewport height does not match workflow cell")
    try require(viewportEvidence["mobile"] as? Bool == (viewport == "mobile"), .invalidEvidence, "capture-cell mobile setting does not match workflow cell")
    try require(viewportEvidence["reducedMotion"] as? Bool == (motionMode == "reduced"), .invalidEvidence, "capture-cell reduced-motion setting does not match workflow cell")

    let validation = try capture.requiredObject("validation")
    let media = try validation.requiredObject("media")
    try require(media["status"] as? String == "valid", .invalidEvidence, "capture-cell media validation is not valid")
    try require((media["format"] as? String ?? "").lowercased().contains("webm"), .invalidEvidence, "capture-cell media format is not WebM")
    _ = try finiteNumber(media["durationSeconds"], label: "capture-cell media durationSeconds", minimumExclusive: 0)
    let videoStreamCount = try positiveInteger(media["videoStreamCount"], label: "capture-cell videoStreamCount")
    try require(videoStreamCount >= 1, .invalidEvidence, "capture-cell has no video stream")
    let jankValidation = try validation.requiredObject("jank")
    try require(jankValidation["status"] as? String == "valid", .invalidEvidence, "capture-cell jank validation is not valid")
    try require(capture["cleanup"] as? String == "confirmed", .invalidEvidence, "capture-cell cleanup is not confirmed")

    let evidence = try capture.requiredObject("evidence")
    let gpu = try evidence.requiredObject("gpu")
    try require(gpu["status"] as? String == "verified", .invalidEvidence, "capture-cell GPU evidence is not verified")
    let egress = try evidence.requiredObject("egress")
    try require(egress["status"] as? String == "verified", .invalidEvidence, "capture-cell egress evidence is not verified")
    _ = try egress.requiredString("boundaryId")
    let approvedHost = try egress.requiredString("approvedHost").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    let finalHost = URLComponents(string: finalURL)?.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    try require(approvedHost == finalHost, .invalidEvidence, "capture-cell approvedHost does not match finalUrl")
    let namespaceInode = try positiveInteger(egress["networkNamespaceInode"], label: "capture-cell networkNamespaceInode")
    try require(namespaceInode > 0, .invalidEvidence, "capture-cell network namespace is not attested")
    try require(egress["directEgressBlocked"] as? Bool == true, .invalidEvidence, "capture-cell direct egress was not blocked")
    try require(egress["approvedProxyProbe"] as? Bool == true, .invalidEvidence, "capture-cell approved proxy probe did not pass")
    try require(egress["proxyPolicy"] as? String == "capture-exact-host.v1", .invalidEvidence, "capture-cell proxy policy is unsupported")
    let attestation = try evidence.requiredObject("egressAttestation")
    try exactKeys(attestation, allowed: ["schemaVersion", "boundaryId", "approvedHost", "networkNamespaceInode", "directEgressBlocked", "proxyPolicy", "controls", "runnerInstanceId", "browserExecutable", "browserVersion", "captureRuntime", "captureRuntimeVersion", "browserUseVersion", "checkedAt", "expiresAt", "runId", "proxyEvidence", "cleanupVerified"], label: "runner egress attestation")
    try require(attestation["schemaVersion"] as? String == "runner-egress-boundary.v1", .unsupportedSchema, "unsupported runner egress attestation schemaVersion")
    try require(attestation["boundaryId"] as? String == egress["boundaryId"] as? String, .invalidEvidence, "egress attestation boundaryId does not match summary")
    try require((attestation["approvedHost"] as? String)?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == approvedHost, .invalidEvidence, "egress attestation approvedHost does not match summary")
    try require((attestation["networkNamespaceInode"] as? NSNumber)?.intValue == namespaceInode, .invalidEvidence, "egress attestation namespace inode does not match summary")
    try require(attestation["directEgressBlocked"] as? Bool == true && attestation["proxyPolicy"] as? String == "capture-exact-host.v1", .invalidEvidence, "egress attestation does not prove the required policy")
    if attestation["captureRuntime"] as? String == "browser-use" {
        try require(attestation["runId"] as? String == runID, .invalidEvidence, "egress attestation run ID does not match capture")
        try require(attestation["cleanupVerified"] as? Bool == true, .invalidEvidence, "egress boundary cleanup is not verified")
        let proxyEvidence = try attestation.requiredObject("proxyEvidence")
        try require((proxyEvidence["violations"] as? [Any])?.isEmpty == true, .invalidEvidence, "egress proxy reports policy violations")
        let connections = proxyEvidence["connectionOutcomes"] as? [[String: Any]] ?? []
        let finalComponents = URLComponents(string: finalURL)
        let expectedPort = finalComponents?.port ?? (finalComponents?.scheme?.lowercased() == "https" ? 443 : 80)
        try require(connections.contains { connection in
            let port = connection["port"] as? NSNumber
            let count = connection["count"] as? NSNumber
            return (connection["hostname"] as? String)?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == approvedHost
                && port.map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.intValue == expectedPort } == true
                && connection["outcome"] as? String == "connected"
                && count.map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.intValue > 0 } == true
        }, .invalidEvidence, "egress proxy has no successful connection to the approved host and port")
    }
    let controls = try attestation.requiredObject("controls")
    try exactKeys(controls, allowed: ["direct", "proxied"], label: "egress control probes")
    try require((controls["direct"] as? [String: Any])?["status"] as? String == "blocked", .invalidEvidence, "direct egress control probe did not block")
    try require((controls["proxied"] as? [String: Any])?["status"] as? String == "passed", .invalidEvidence, "approved proxy control probe did not pass")
    for key in ["runnerInstanceId", "browserExecutable", "browserVersion", "captureRuntimeVersion", "browserUseVersion"] {
        _ = try attestation.requiredString(key)
    }
    try require(["browser-use", "site-motion-capture"].contains(attestation["captureRuntime"] as? String ?? ""), .invalidEvidence, "egress attestation captureRuntime is unsupported")
    let checkedAt = try attestationDate(attestation, key: "checkedAt")
    let expiresAt = try attestationDate(attestation, key: "expiresAt")
    let lifetime = expiresAt.timeIntervalSince(checkedAt)
    try require(lifetime > 0 && lifetime <= 120, .invalidEvidence, "egress attestation lifetime must be at most 120 seconds")
    let consent = try evidence.requiredObject("consent")
    try require(consent["verified"] as? Bool == true, .invalidEvidence, "capture-cell consent is not verified")
    try require((consent["blindSpots"] as? [Any] ?? []).isEmpty, .invalidEvidence, "capture-cell consent has blind spots")
    let scroll = try evidence.requiredObject("scroll")
    try require(scroll["completed"] as? Bool == true, .invalidEvidence, "capture-cell scroll did not complete")
    try require(scroll["truncated"] as? Bool == false, .invalidEvidence, "capture-cell scroll is truncated")
    try require((evidence["interactionFailures"] as? [Any] ?? []).isEmpty, .invalidEvidence, "capture-cell contains interaction failures")

    let files = try capture.requiredArray("files")
    for expected in [video, jank] {
        let expectedPath = try expected.requiredString("path")
        let basename = URL(fileURLWithPath: expectedPath).lastPathComponent
        let expectedSize = try positiveInteger(expected["size"], label: "capture artifact size")
        let expectedHash = try expected.requiredString("sha256")
        let matching = try files.compactMap { try object($0, label: "capture-cell file") }.first {
            $0["path"] as? String == basename
        }
        try require((matching?["size"] as? Int) == expectedSize, .invalidEvidence, "capture-cell file size does not match workflow artifact")
        try require(matching?["sha256"] as? String == expectedHash, .invalidEvidence, "capture-cell file hash does not match workflow artifact")
    }
}

private func attestationDate(_ object: [String: Any], key: String) throws -> Date {
    let value = try object.requiredString(key)
    let optionSets: [ISO8601DateFormatter.Options] = [.withInternetDateTime.union(.withFractionalSeconds), .withInternetDateTime]
    for options in optionSets {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        if let date = formatter.date(from: value) { return date }
    }
    throw WorkflowContractError(.invalidEvidence, "egress attestation \(key) must be ISO-8601 with a timezone")
}

public struct MotionAnalysisValidationResult: Equatable, Sendable {
    public let momentFrameHashes: Set<String>
    public let hasRequiredGap: Bool
}

private func verifiedWorkspaceRoot(_ workspace: [String: Any], expected: URL) throws -> URL {
    try exactKeys(workspace, allowed: ["root"], label: "workspace")
    let declared = URL(fileURLWithPath: try workspace.requiredString("root")).resolvingSymlinksInPath().standardizedFileURL
    let expected = expected.resolvingSymlinksInPath().standardizedFileURL
    try require(!declared.path.isEmpty && FileManager.default.fileExists(atPath: expected.path), .artifactOutsideWorkspace, "manifest workspace root is not available")
    try require(declared.path == expected.path, .artifactOutsideWorkspace, "manifest workspace root does not match expected root")
    return expected
}

private func validateArtifact(_ artifact: [String: Any], workspaceRoot: URL, allowTimestampSeconds: Bool = false) throws -> String {
    var allowed: Set<String> = ["path", "size", "sha256", "nonEmpty", "kind"]
    if allowTimestampSeconds {
        allowed.insert("timestampSeconds")
    }
    try exactKeys(artifact, allowed: allowed, label: "artifact")
    let path = try artifact.requiredString("path")
    let size = try positiveInteger(artifact["size"], label: "artifact size")
    let expectedHash = try artifact.requiredString("sha256")
    try sha256(expectedHash, label: "artifact sha256")
    try require(artifact["nonEmpty"] as? Bool == true, .invalidEvidence, "artifact.nonEmpty must be true")
    let file = workspaceRoot.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
    let rootPath = workspaceRoot.path.hasSuffix("/") ? workspaceRoot.path : workspaceRoot.path + "/"
    try require(file.path.hasPrefix(rootPath), .artifactOutsideWorkspace, "artifact path must remain inside workspace")
    guard FileManager.default.fileExists(atPath: file.path) else {
        throw WorkflowContractError(.artifactMissing, "artifact path does not exist: \(path)")
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let actualSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
    try require(actualSize > 0, .artifactEmpty, "artifact path is empty: \(path)")
    try require(actualSize == size, .artifactSizeMismatch, "artifact size does not match: \(path)")
    let actualHash = WorkflowSHA256.hexDigest(try Data(contentsOf: file))
    try require(actualHash == expectedHash, .artifactHashMismatch, "artifact sha256 does not match: \(path)")
    return expectedHash
}

private func validateRedactedOpenDesignInput(_ value: String) throws {
    let lowercased = value.lowercased()
    try require(!lowercased.contains(".webm"), .invalidEvidence, "Open Design redactedInputs must not include WebM files")
    try require(!lowercased.contains(".env") && !lowercased.contains("api_key") && !lowercased.contains("token="), .invalidEvidence, "Open Design redactedInputs contain sensitive material")
}

private func validateAssetRouteContract(_ route: [String: Any], requested: String, actual: String) throws {
    let syntheticPrefix = "https://asset-route.invalid/"
    let usesSynthetic = requested.hasPrefix(syntheticPrefix) || actual.hasPrefix(syntheticPrefix)
    guard usesSynthetic else { return }
    let pattern = #"^https://asset-route\.invalid/(requested|actual|blocked)/(blender|brief-to-lottie|lottie-creator|svgator|glaxnimate)$"#
    let validRequested = requested.range(of: pattern, options: .regularExpression) != nil
    let validActual = actual.range(of: pattern, options: .regularExpression) != nil
    try require(validRequested && validActual, .invalidEvidence, "synthetic asset routes must use asset-route.v1 identifiers")
    let capability = try route.requiredObject("capability")
    try require(capability["routeContractVersion"] as? String == "asset-route.v1", .invalidEvidence, "synthetic asset routes require asset-route.v1 capability metadata")
}

private func exactKeys(_ object: [String: Any], allowed: Set<String>, label: String) throws {
    let unknown = Set(object.keys).subtracting(allowed)
    try require(unknown.isEmpty, .invalidEvidence, "\(label) has unknown fields: \(unknown.sorted().joined(separator: ", "))")
}

private func object(_ value: Any, label: String) throws -> [String: Any] {
    guard let object = value as? [String: Any] else {
        throw WorkflowContractError(.invalidEvidence, "\(label) must be an object")
    }
    return object
}

private func nonEmptyString(_ value: Any, label: String) throws -> String {
    guard let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw WorkflowContractError(.invalidEvidence, "\(label) is required")
    }
    return string
}

private func safeHTTPURL(_ value: String, label: String) throws {
    guard let components = URLComponents(string: value),
          ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
          components.host != nil,
          components.user == nil,
          components.password == nil else {
        throw WorkflowContractError(.invalidEvidence, "\(label) must be a safe http(s) URL")
    }
    let hostname = (components.host ?? "").lowercased()
    try require(hostname != "localhost" && hostname != "localhost.localdomain" && !hostname.hasSuffix(".local"), .invalidEvidence, "\(label) must not target a private host")
    if hostname.contains(":") {
        let privateIPv6 = hostname == "::1" || hostname.hasPrefix("fc") || hostname.hasPrefix("fd") || hostname.hasPrefix("fe80") || hostname.hasPrefix("::ffff:")
        try require(!privateIPv6, .invalidEvidence, "\(label) must not target a private host")
    } else {
        let parts = hostname.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            let first = parts[0]
            let second = parts[1]
            let privateIPv4 = first == 0 || first == 10 || first == 127 || (first == 100 && (64...127).contains(second)) || (first == 169 && second == 254) || (first == 172 && (16...31).contains(second)) || (first == 192 && (second == 0 || second == 168)) || (first == 198 && (18...19).contains(second)) || first >= 224
            try require(!privateIPv4, .invalidEvidence, "\(label) must not target a private host")
        }
    }
}

private func sha256(_ value: String, label: String) throws {
    let matches = value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    try require(matches, .invalidEvidence, "\(label) must be lowercase sha256")
}

private func positiveInteger(_ value: Any?, label: String) throws -> Int {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.rounded() == number.doubleValue, number.intValue > 0 else {
        throw WorkflowContractError(.invalidEvidence, "\(label) must be a positive integer")
    }
    return number.intValue
}

private func finiteNumber(_ value: Any?, label: String, minimum: Double? = nil, minimumExclusive: Double? = nil, maximum: Double? = nil) throws -> Double {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
        throw WorkflowContractError(.invalidEvidence, "\(label) must be a number")
    }
    let result = number.doubleValue
    try require(result.isFinite, .invalidEvidence, "\(label) must be finite")
    if let minimum { try require(result >= minimum, .invalidEvidence, "\(label) is below the minimum") }
    if let minimumExclusive { try require(result > minimumExclusive, .invalidEvidence, "\(label) must be greater than the minimum") }
    if let maximum { try require(result <= maximum, .invalidEvidence, "\(label) exceeds the maximum") }
    return result
}

private func require(_ condition: @autoclosure () -> Bool, _ code: WorkflowErrorCode, _ message: @autoclosure () -> String) throws {
    guard condition() else { throw WorkflowContractError(code, message()) }
}

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func requiredString(_ key: String) throws -> String { try nonEmptyString(self[key] as Any, label: key) }
    func requiredObject(_ key: String) throws -> [String: Any] { try object(self[key] as Any, label: key) }
    func requiredArray(_ key: String) throws -> [Any] {
        guard let array = self[key] as? [Any] else { throw WorkflowContractError(.invalidEvidence, "\(key) must be an array") }
        return array
    }
    func requiredEnum(_ key: String, values: Set<String>) throws -> String {
        let value = try requiredString(key)
        try require(values.contains(value), .invalidEvidence, "\(key) has an unsupported value")
        return value
    }
}
