// Resolve a target app by name or bundle identifier, and enumerate
// controllable apps.

import AppKit
import Foundation

struct ResolvedApp {
    let pid: pid_t
    let name: String
    let bundleIdentifier: String

    var axApplication: AXUIElement {
        AXUIElementCreateApplication(pid)
    }
}

/// Fresh enumeration of running GUI apps. NSWorkspace.runningApplications is
/// a KVO-updated snapshot that goes stale in the daemon (its main thread never
/// services a run loop), silently hiding every app launched after daemon
/// start. Building NSRunningApplication objects from a raw pid scan queries
/// LaunchServices directly and is always current. The scan is cached for one
/// second so the gate pipeline and tool handler resolving the same app within
/// a single call do not repeat it.
func freshRunningApplications() -> [NSRunningApplication] {
    RunningApplicationsCache.shared.current()
}

private final class RunningApplicationsCache: @unchecked Sendable {
    static let shared = RunningApplicationsCache()
    private let lock = NSLock()
    private var apps: [NSRunningApplication] = []
    private var fetchedAt: ContinuousClock.Instant?

    func current() -> [NSRunningApplication] {
        lock.lock()
        defer { lock.unlock() }
        if let fetchedAt, fetchedAt + .seconds(1) > .now {
            return apps
        }
        apps = Self.scan()
        fetchedAt = .now
        return apps
    }

    private static func scan() -> [NSRunningApplication] {
        let pids = allProcessIDs()
        guard !pids.isEmpty else { return NSWorkspace.shared.runningApplications }
        return pids.compactMap { pid in
            guard let app = NSRunningApplication(processIdentifier: pid),
                app.activationPolicy != .prohibited
            else { return nil }
            return app
        }
    }
}

/// Every pid on the system, in the kernel's newest-first order. Despite the
/// header's byte-oriented wording, proc_listallpids returns the number of
/// pids written (verified empirically: 786 returned for 785 processes), while
/// the buffer size it takes is in bytes — dividing the return value by the
/// pid size silently dropped the oldest three quarters of the list and made
/// login-time apps unresolvable.
func allProcessIDs() -> [pid_t] {
    var pids = [pid_t](repeating: 0, count: 8192)
    let returned = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard returned > 0 else { return [] }
    return pids.prefix(min(Int(returned), pids.count)).filter { $0 > 0 }
}

func resolveApp(_ identifier: String) throws -> ResolvedApp {
    let running = freshRunningApplications()
    let query = identifier.lowercased()

    let match = running.first { $0.bundleIdentifier?.lowercased() == query }
        ?? running.first { $0.localizedName?.lowercased() == query }
        ?? running.first {
            $0.activationPolicy == .regular && ($0.localizedName?.lowercased().hasPrefix(query) ?? false)
        }

    guard let app = match else {
        let visible = running
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
            .sorted()
            .joined(separator: ", ")
        throw ToolError.failed(
            "\"\(identifier)\" is not running. Only running apps can be controlled — open it "
                + "first, then retry. Currently running: \(visible)."
        )
    }
    return ResolvedApp(
        pid: app.processIdentifier,
        name: app.localizedName ?? identifier,
        bundleIdentifier: app.bundleIdentifier ?? "unknown"
    )
}

func runningAppsDescription() -> String {
    let running = freshRunningApplications()
        .filter { $0.activationPolicy == .regular }
        .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

    var lines = ["Running apps (controllable now):"]
    for app in running {
        let name = app.localizedName ?? "?"
        let bundle = app.bundleIdentifier ?? "?"
        let state = app.isHidden ? " hidden" : ""
        lines.append("  \(name) (\(bundle), pid \(app.processIdentifier))\(state)")
    }

    let applications = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
    let installed =
        applications
        .filter { $0.hasSuffix(".app") }
        .map { String($0.dropLast(4)) }
        .sorted()
    if !installed.isEmpty {
        lines.append("")
        lines.append("Installed apps (open one first to control it): \(installed.joined(separator: ", "))")
    }
    return lines.joined(separator: "\n")
}
