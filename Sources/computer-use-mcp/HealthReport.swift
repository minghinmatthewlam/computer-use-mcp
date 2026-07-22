import Foundation
#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import ScreenCaptureKit
#else
import Glibc
#endif

func makeHealthReport(prompt: Bool, probeCaptureService: Bool) async -> HealthReport {
    #if os(macOS)
    let accessibility: Bool
    if prompt {
        // Literal key for kAXTrustedCheckOptionPrompt; the C global is not
        // concurrency-safe to reference under Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibility = AXIsProcessTrustedWithOptions(options)
    } else {
        accessibility = AXIsProcessTrusted()
    }

    var screenRecording = CGPreflightScreenCaptureAccess()
    if prompt && !screenRecording {
        screenRecording = CGRequestScreenCaptureAccess()
    }

    let permissions = PermissionDiagnostics(
        accessibility: PermissionStatus(
            granted: accessibility,
            status: accessibility ? "granted" : "not_granted",
            requiredFor: "reading app UI and delivering Accessibility actions"
        ),
        screenRecording: PermissionStatus(
            granted: screenRecording,
            status: screenRecording ? "granted" : "not_granted",
            requiredFor: "screenshots and ScreenCaptureKit window capture"
        )
    )

    let captureService = await captureServiceDiagnostic(
        screenRecordingGranted: screenRecording,
        probe: probeCaptureService
    )
    let process = ProcessDiagnostics.current()
    let daemon = daemonDiagnostics()
    let action = recommendedNextAction(
        accessibility: accessibility,
        screenRecording: screenRecording,
        captureServiceStatus: captureService.status
    )

    return HealthReport(
        reportVersion: 1,
        version: version,
        executablePath: executablePath(),
        bundleIdentifier: Bundle.main.bundleIdentifier,
        process: process,
        permissions: permissions,
        captureService: captureService,
        daemon: daemon,
        inputDelivery: nil,
        telemetry: telemetryDiagnostics(),
        tccAttribution: tccAttributionNote(parent: process.parent),
        recommendedNextAction: action
    )
    #else
    let process = ProcessDiagnostics.current()
    let accessibility = linuxAccessibilityAvailable()
    let inputDelivery = linuxInputDeliveryDiagnostic()
    let captureService = linuxCaptureDiagnostic()
    return HealthReport(
        reportVersion: 1,
        version: version,
        executablePath: executablePath(),
        bundleIdentifier: Bundle.main.bundleIdentifier,
        process: process,
        permissions: PermissionDiagnostics(
            accessibility: PermissionStatus(
                granted: accessibility,
                status: accessibility ? "granted" : "not_available",
                requiredFor: "AT-SPI2 accessibility bus and application trees"
            ),
            screenRecording: PermissionStatus(granted: false, status: "unsupported", requiredFor: "Screen Recording is unsupported on Linux")
        ),
        captureService: captureService,
        daemon: daemonDiagnostics(),
        inputDelivery: inputDelivery,
        telemetry: telemetryDiagnostics(),
        tccAttribution: "Linux does not use TCC.",
        recommendedNextAction: accessibility
            ? (inputDelivery.status == "available"
                ? (captureService.status == .responsive
                    ? "AT-SPI2 perception, X11/XTest input, and X11 capture are available; Wayland is unsupported."
                    : "AT-SPI2 perception and X11/XTest input are available, but X11 capture is unavailable: \(captureService.detail)")
                : "AT-SPI2 perception is available, but X11/XTest input is unavailable: \(inputDelivery.detail)")
            : "Start an AT-SPI2 accessibility bus and enable application accessibility, then rerun health_report."
    )
    #endif
}

private func captureServiceDiagnostic(screenRecordingGranted: Bool, probe: Bool) async -> CaptureServiceDiagnostic {
    #if os(macOS)
    guard screenRecordingGranted else {
        return CaptureServiceDiagnostic(
            status: .skipped,
            detail: "Screen Recording is not granted, so the capture service probe was not run."
        )
    }
    guard probe else {
        return CaptureServiceDiagnostic(status: .skipped, detail: "Capture service probe was disabled.")
    }

    // The screen-capture daemon (replayd) serves every screenshot and can
    // wedge. Probe it so a wedged daemon shows up here, not as every screenshot
    // timing out. This enumerates shareable content but does not capture pixels.
    do {
        _ = try await withCrossProcessLock(named: "screencapture") {
            try await withTimeout(seconds: 5, label: "Capture service probe") {
                try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                    .windows.count
            }
        }
        return CaptureServiceDiagnostic(status: .responsive, detail: "ScreenCaptureKit shareable content responded.")
    } catch {
        return CaptureServiceDiagnostic(
            status: .notResponding,
            detail: "ScreenCaptureKit did not respond: \(error)"
        )
    }
    #else
    return CaptureServiceDiagnostic(status: .skipped, detail: "Screen capture is unsupported on Linux.")
    #endif
}

func recommendedNextAction(
    accessibility: Bool,
    screenRecording: Bool,
    captureServiceStatus: CaptureServiceStatus
) -> String {
    if !accessibility {
        return "Grant Accessibility to the responsible host app, then rerun `computer-use-mcp health_report`."
    }
    if !screenRecording {
        return "Grant Screen Recording to the responsible host app, then rerun `computer-use-mcp health_report`."
    }
    if captureServiceStatus == .notResponding {
        return "Restart the macOS screen-capture service with `killall -9 replayd`, then rerun `computer-use-mcp health_report`."
    }
    if captureServiceStatus == .skipped {
        return "Permissions are available. Run `computer-use-mcp health_report --probe-capture` when you need to check capture-service responsiveness."
    }
    return "Permissions and capture probe are healthy. For production distribution, launch from a signed, notarized app bundle so TCC grants attach to a stable identity."
}

private func daemonDiagnostics() -> DaemonDiagnostics {
    let paths = daemonRuntimePaths(createRuntimeDirectory: false)
    let manager = FileManager.default
    return DaemonDiagnostics(
        runtimeDirectory: paths.directory,
        runtimeDirectoryExists: manager.fileExists(atPath: paths.directory),
        socketPath: paths.socket,
        socketExists: manager.fileExists(atPath: paths.socket),
        lockPath: paths.lock,
        lockExists: manager.fileExists(atPath: paths.lock),
        logPath: paths.log,
        logExists: manager.fileExists(atPath: paths.log),
        secretPath: paths.secret,
        secretExists: manager.fileExists(atPath: paths.secret),
        secretContentsReported: false
    )
}

private func executablePath() -> String {
    if let executableURL = Bundle.main.executableURL {
        return executableURL.standardizedFileURL.path
    }
    return URL(fileURLWithPath: CommandLine.arguments.first ?? "computer-use-mcp").standardizedFileURL.path
}

private func tccAttributionNote(parent: ProcessIdentity?) -> String {
    let parentName = parent?.name ?? "the process that launched this binary"
    return "macOS may attribute CLI TCC grants to \(parentName) or another responsible host app; a signed app bundle gives production installs a stable identity."
}

struct HealthReport: Codable, Sendable {
    let reportVersion: Int
    let version: String
    let executablePath: String
    let bundleIdentifier: String?
    let process: ProcessDiagnostics
    let permissions: PermissionDiagnostics
    let captureService: CaptureServiceDiagnostic
    let daemon: DaemonDiagnostics
    let inputDelivery: InputDeliveryDiagnostic?
    /// Absent when no daemon has persisted a telemetry snapshot yet (or
    /// telemetry is disabled with "no_telemetry").
    let telemetry: TelemetryReport?
    let tccAttribution: String
    let recommendedNextAction: String

    var ready: Bool {
        permissions.accessibility.granted
            && permissions.screenRecording.granted
            && captureService.status != .notResponding
    }

    var provenReady: Bool {
        permissions.accessibility.granted
            && permissions.screenRecording.granted
            && captureService.status == .responsive
    }
}

struct ProcessDiagnostics: Codable, Sendable {
    let current: ProcessIdentity
    let parent: ProcessIdentity?

    static func current() -> ProcessDiagnostics {
        #if os(macOS)
        let pid = ProcessInfo.processInfo.processIdentifier
        let currentApp = NSRunningApplication.current
        let currentExecutablePath = executablePath()
        let current = ProcessIdentity(
            pid: pid,
            name: ProcessInfo.processInfo.processName,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? currentApp.bundleIdentifier,
            bundlePath: Bundle.main.bundleURL.standardizedFileURL.path,
            executablePath: currentExecutablePath
        )
        let parent = ProcessIdentity(pid: getppid())
        return ProcessDiagnostics(current: current, parent: parent)
        #else
        let pid = ProcessInfo.processInfo.processIdentifier
        let current = ProcessIdentity(
            pid: pid,
            name: ProcessInfo.processInfo.processName,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            bundlePath: Bundle.main.bundleURL.standardizedFileURL.path,
            executablePath: executablePath()
        )
        let parent = ProcessIdentity(pid: getppid())
        return ProcessDiagnostics(current: current, parent: parent)
        #endif
    }
}

struct ProcessIdentity: Codable, Sendable {
    let pid: Int32
    let name: String?
    let bundleIdentifier: String?
    let bundlePath: String?
    let executablePath: String?

    init(pid: Int32, name: String?, bundleIdentifier: String?, bundlePath: String?, executablePath: String?) {
        self.pid = pid
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.executablePath = executablePath
    }

    init?(pid: Int32) {
        guard pid > 0 else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        let path = app?.executableURL?.standardizedFileURL.path ?? processExecutablePath(pid: pid)
        self.pid = pid
        self.name = app?.localizedName ?? path.map { URL(fileURLWithPath: $0).lastPathComponent }
        self.bundleIdentifier = app?.bundleIdentifier
        self.bundlePath = app?.bundleURL?.standardizedFileURL.path
        self.executablePath = path
    }

    var summary: String {
        var parts = ["pid \(pid)"]
        if let name {
            parts.append(name)
        }
        if let bundleIdentifier {
            parts.append(bundleIdentifier)
        } else {
            parts.append("no bundle id")
        }
        return parts.joined(separator: ", ")
    }
}

private func processExecutablePath(pid: Int32) -> String? {
    #if os(macOS)
    var buffer = [CChar](repeating: 0, count: 4096)
    let result = buffer.withUnsafeMutableBufferPointer { pointer in
        proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
    }
    guard result > 0 else { return nil }
    let bytes = buffer.prefix(Int(result)).map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
    #else
    return nil
    #endif
}

struct PermissionDiagnostics: Codable, Sendable {
    let accessibility: PermissionStatus
    let screenRecording: PermissionStatus
}

struct PermissionStatus: Codable, Sendable {
    let granted: Bool
    let status: String
    let requiredFor: String

    var displayStatus: String {
        granted ? "granted" : "NOT GRANTED"
    }
}

enum CaptureServiceStatus: String, Codable, Sendable {
    case responsive
    case notResponding = "not_responding"
    case skipped
}

struct CaptureServiceDiagnostic: Codable, Sendable {
    let status: CaptureServiceStatus
    let detail: String

    var displayStatus: String {
        switch status {
        case .responsive:
            return "responsive"
        case .notResponding:
            return "NOT RESPONDING"
        case .skipped:
            return "skipped"
        }
    }
}

/// Telemetry section of the health report, derived from the snapshot the
/// daemon persists (health_report runs in a separate process, so the
/// daemon's in-memory counters are not directly visible here). The snapshot
/// is written at most every 15 seconds, hence the age note.
private func telemetryDiagnostics(now: Date = Date()) -> TelemetryReport? {
    let path = telemetrySnapshotPath()
    guard let snapshot = TelemetrySnapshot.read(atPath: path) else { return nil }
    return TelemetryReport(snapshot: snapshot, path: path, now: now)
}

struct TelemetryReport: Codable, Sendable {
    let snapshotPath: String
    let snapshotAgeSeconds: Double
    let snapshotAgeNote: String
    let uptimeSeconds: Double
    let tools: [String: TelemetryToolReport]
    let firstPerceiveToFirstActSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case snapshotPath = "snapshot_path"
        case snapshotAgeSeconds = "snapshot_age_seconds"
        case snapshotAgeNote = "snapshot_age_note"
        case uptimeSeconds = "uptime_seconds"
        case tools
        case firstPerceiveToFirstActSeconds = "first_perceive_to_first_act_seconds"
    }

    init(snapshot: TelemetrySnapshot, path: String, now: Date) {
        let age = max(0, now.timeIntervalSince(snapshot.writtenAt))
        snapshotPath = path
        snapshotAgeSeconds = age
        snapshotAgeNote =
            "Snapshot written \(Int(age))s ago; the daemon persists at most every 15 seconds."
        uptimeSeconds = snapshot.uptimeSeconds
        tools = snapshot.tools.mapValues(TelemetryToolReport.init)
        firstPerceiveToFirstActSeconds = snapshot.firstPerceiveToFirstActSeconds
    }

    /// Manual encoding so first_perceive_to_first_act_seconds appears as an
    /// explicit null before the funnel has been observed, instead of being
    /// dropped from the JSON.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(snapshotPath, forKey: .snapshotPath)
        try container.encode(snapshotAgeSeconds, forKey: .snapshotAgeSeconds)
        try container.encode(snapshotAgeNote, forKey: .snapshotAgeNote)
        try container.encode(uptimeSeconds, forKey: .uptimeSeconds)
        try container.encode(tools, forKey: .tools)
        try container.encode(firstPerceiveToFirstActSeconds, forKey: .firstPerceiveToFirstActSeconds)
    }
}

struct TelemetryToolReport: Codable, Sendable {
    let calls: Int
    let errors: Int
    let meanMs: Double

    enum CodingKeys: String, CodingKey {
        case calls
        case errors
        case meanMs = "mean_ms"
    }

    init(counter: TelemetryCounter) {
        calls = counter.calls
        errors = counter.errors
        meanMs = counter.meanMs ?? 0
    }
}

struct DaemonDiagnostics: Codable, Sendable {
    let runtimeDirectory: String
    let runtimeDirectoryExists: Bool
    let socketPath: String
    let socketExists: Bool
    let lockPath: String
    let lockExists: Bool
    let logPath: String
    let logExists: Bool
    let secretPath: String
    let secretExists: Bool
    let secretContentsReported: Bool
}
