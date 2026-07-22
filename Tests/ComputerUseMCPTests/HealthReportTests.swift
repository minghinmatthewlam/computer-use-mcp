import MCP
import Testing

@testable import computer_use_mcp

private func healthToolSpec(_ name: String) throws -> ToolSpec {
    guard let spec = toolCatalog.first(where: { $0.name == name }) else {
        throw ToolError.failed("Missing tool spec \(name).")
    }
    return spec
}

private func structuredReport(in result: CallTool.Result) throws -> [String: Value] {
    guard case let .object(report)? = result.structuredContent else {
        throw ToolError.failed("Expected structured health report.")
    }
    return report
}

private func resultText(in result: CallTool.Result) throws -> String {
    guard case let .text(text, _, _)? = result.content.first else {
        throw ToolError.failed("Expected text health report summary.")
    }
    return text
}

private func outcomeFields(in result: CallTool.Result) throws -> [String: Value] {
    guard case let .object(outcome)? = result._meta?[actionOutcomeMetaKey] else {
        throw ToolError.failed("Expected outcome metadata.")
    }
    return outcome
}

@Suite struct HealthReportTests {
    @Test func healthReportToolIsRegisteredReadOnly() throws {
        let spec = try healthToolSpec("health_report")
        #expect(spec.annotations.readOnlyHint == true)
        #expect(spec.annotations.destructiveHint == false)
        #expect(spec.annotations.idempotentHint == true)
        #expect(spec.annotations.openWorldHint == false)
    }

    @Test func healthReportToolReturnsStructuredContentAndSuccessOutcomeWhenDegraded() async throws {
        let result = try await healthReportImpl([:]) { probe in
            #expect(probe == false)
            return Self.mockReport(
                accessibility: false,
                screenRecording: true,
                captureServiceStatus: .skipped
            )
        }

        #expect(result.isError == false)
        let summary = try resultText(in: result)
        #expect(summary.contains("completed with degraded health"))
        #expect(summary.contains("Grant Accessibility"))

        let report = try structuredReport(in: result)
        #expect(report["version"]?.stringValue == "test")
        guard case let .object(permissions)? = report["permissions"],
            case let .object(accessibility)? = permissions["accessibility"]
        else {
            Issue.record("expected permissions.accessibility object")
            return
        }
        #expect(accessibility["granted"]?.boolValue == false)

        let outcome = try outcomeFields(in: result)
        #expect(outcome["classification"]?.stringValue == "success")
        #expect(outcome["failure_domain"] == nil)
    }

    @Test func healthReportToolReturnsSuccessOutcomeWhenCaptureProbeIsSkipped() async throws {
        let result = try await healthReportImpl([:]) { probe in
            #expect(probe == false)
            return Self.mockReport(
                accessibility: true,
                screenRecording: true,
                captureServiceStatus: .skipped
            )
        }

        #expect(result.isError == false)
        let summary = try resultText(in: result)
        #expect(summary.contains("without verified capture health"))
        #expect(summary.contains("--probe-capture"))

        let outcome = try outcomeFields(in: result)
        #expect(outcome["classification"]?.stringValue == "success")
        #expect(outcome["failure_domain"] == nil)
    }

    @Test func healthReportToolPassesCaptureProbeArgumentToFactory() async throws {
        let result = try await healthReportImpl(["probe_capture_service": .bool(true)]) { probe in
            #expect(probe == true)
            return Self.mockReport(
                accessibility: true,
                screenRecording: true,
                captureServiceStatus: .responsive
            )
        }

        #expect(result.isError == false)
        let summary = try resultText(in: result)
        #expect(summary == "Health report is ready: permissions and capture health are verified.")

        let report = try structuredReport(in: result)
        guard case let .object(captureService)? = report["captureService"] else {
            Issue.record("expected captureService object")
            return
        }
        #expect(captureService["status"]?.stringValue == "responsive")

        let outcome = try outcomeFields(in: result)
        #expect(outcome["classification"]?.stringValue == "success")
        #expect(outcome["failure_domain"] == nil)
    }

    @Test func recommendationStartsWithAccessibility() {
        let action = recommendedNextAction(
            accessibility: false,
            screenRecording: false,
            captureServiceStatus: .skipped
        )

        #expect(action.contains("Grant Accessibility"))
    }

    @Test func recommendationThenChecksScreenRecording() {
        let action = recommendedNextAction(
            accessibility: true,
            screenRecording: false,
            captureServiceStatus: .skipped
        )

        #expect(action.contains("Grant Screen Recording"))
    }

    @Test func recommendationCallsOutWedgedCaptureService() {
        let action = recommendedNextAction(
            accessibility: true,
            screenRecording: true,
            captureServiceStatus: .notResponding
        )

        #expect(action.contains("replayd"))
    }

    @Test func recommendationCallsOutStableBundleIdentityWhenHealthy() {
        let action = recommendedNextAction(
            accessibility: true,
            screenRecording: true,
            captureServiceStatus: .responsive
        )

        #expect(action.contains("signed, notarized app bundle"))
    }

    @Test func recommendationExplainsSkippedCaptureProbe() {
        let action = recommendedNextAction(
            accessibility: true,
            screenRecording: true,
            captureServiceStatus: .skipped
        )

        #expect(action.contains("--probe-capture"))
    }

    private static func mockReport(
        accessibility: Bool,
        screenRecording: Bool,
        captureServiceStatus: CaptureServiceStatus
    ) -> HealthReport {
        let captureService = CaptureServiceDiagnostic(status: captureServiceStatus, detail: "mock")
        return HealthReport(
            reportVersion: 1,
            version: "test",
            executablePath: "/tmp/computer-use-mcp",
            bundleIdentifier: nil,
            process: ProcessDiagnostics(
                current: ProcessIdentity(
                    pid: 123,
                    name: "computer-use-mcp",
                    bundleIdentifier: nil,
                    bundlePath: nil,
                    executablePath: "/tmp/computer-use-mcp"
                ),
                parent: nil
            ),
            permissions: PermissionDiagnostics(
                accessibility: PermissionStatus(
                    granted: accessibility,
                    status: accessibility ? "granted" : "not_granted",
                    requiredFor: "mock accessibility"
                ),
                screenRecording: PermissionStatus(
                    granted: screenRecording,
                    status: screenRecording ? "granted" : "not_granted",
                    requiredFor: "mock screen recording"
                )
            ),
            captureService: captureService,
            daemon: DaemonDiagnostics(
                runtimeDirectory: "/tmp/computer-use-mcp",
                runtimeDirectoryExists: false,
                socketPath: "/tmp/computer-use-mcp/socket",
                socketExists: false,
                lockPath: "/tmp/computer-use-mcp/lock",
                lockExists: false,
                logPath: "/tmp/computer-use-mcp/log",
                logExists: false,
                secretPath: "/tmp/computer-use-mcp/secret",
                secretExists: false,
                secretContentsReported: false
            ),
            inputDelivery: nil,
            telemetry: nil,
            tccAttribution: "mock attribution",
            recommendedNextAction: recommendedNextAction(
                accessibility: accessibility,
                screenRecording: screenRecording,
                captureServiceStatus: captureService.status
            )
        )
    }
}
