// Human-interference yield: real user input takes priority over the agent.
//
// Background delivery never moves the user's cursor or steals focus, so the
// only collision surfaces are (a) the app the user is actively working in —
// their real events and our synthetic ones would interleave inside the same
// process — and (b) the global escape hatches, which take over the real
// pointer/keyboard. Gate exactly those: app-scoped mutating tools when the
// target app is frontmost while the user's hands are on the hardware, and any
// allow_global_cursor action while the user is active anywhere. Actions on
// apps the user is not using are never blocked.
//
// User activity is read from the HID hardware event state, which synthetic
// delivery (private-source events posted to a pid or window) does not update —
// the agent cannot trip its own guard.

import Foundation
import MCP
#if os(macOS)
import CoreGraphics
#endif

/// Pure yield decision, separated from system state for tests.
func interferenceShouldYield(
    targetPid: pid_t?,
    frontmostPid: pid_t?,
    usesGlobalPath: Bool,
    secondsSinceUserInput: Double,
    idleThreshold: Double
) -> Bool {
    guard idleThreshold > 0, secondsSinceUserInput < idleThreshold else { return false }
    if usesGlobalPath { return true }
    guard let targetPid, let frontmostPid else { return false }
    return targetPid == frontmostPid
}

enum InterferenceGuard {
    /// Disable with no_interference_yield / COMPUTER_USE_MCP_NO_INTERFERENCE_YIELD=1.
    static let isEnabled: Bool = Config.bool("no_interference_yield") != true

    /// Seconds the hardware must be quiet before acting where the user is
    /// working ("interference_idle_seconds", default 1). 0 disables the guard.
    static let idleThreshold: Double = Config.double("interference_idle_seconds") ?? 1.0

    /// How long to wait for the user to pause before returning the error.
    static let graceSeconds: Double = 2.0

    /// Seconds since the last hardware input event. HID system state counts
    /// physical keyboard/mouse activity, not events posted to pids/windows.
    static func secondsSinceUserInput() -> Double {
        let kinds: [CGEventType] = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .mouseMoved, .leftMouseDragged, .scrollWheel, .keyDown,
        ]
        return kinds.map {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)
        }.min() ?? .infinity
    }

    /// Returns nil when clear to act. Otherwise waits up to graceSeconds for
    /// the user to pause, then returns a recoverable error message.
    static func waitForUserPause(toolName: String, arguments: [String: Value]) async -> String? {
        guard isEnabled, appScopedToolNames.contains(toolName) else { return nil }
        let threshold = idleThreshold
        // Fast path: an idle user can never yield — skip resolving the app.
        guard threshold > 0, secondsSinceUserInput() < threshold else { return nil }
        let usesGlobalPath = arguments.bool("allow_global_cursor") == true
            || arguments.bool("allow_global_keyboard") == true
        let targetPid = arguments.string("app").flatMap { try? resolveApp($0).pid }
        let deadline = ContinuousClock.now + .seconds(graceSeconds)
        while true {
            let idle = secondsSinceUserInput()
            let frontmost = FrontmostAppSnapshot.current()
            guard
                interferenceShouldYield(
                    targetPid: targetPid, frontmostPid: frontmost?.pid,
                    usesGlobalPath: usesGlobalPath,
                    secondsSinceUserInput: idle, idleThreshold: threshold
                )
            else { return nil }
            guard ContinuousClock.now < deadline else {
                let surface =
                    usesGlobalPath
                    ? "this action uses the real cursor/keyboard"
                    : "the target app \"\(frontmost?.name ?? "unknown")\" is the app the user is working in"
                return
                    "User activity detected: \(surface), and hardware input was "
                    + String(format: "%.1f", idle) + "s ago. Yielding so the agent does not "
                    + "interleave with the user's work. Retry in a moment — actions on apps "
                    + "the user is not using are never blocked. Set interference_idle_seconds:0 "
                    + "to disable this guard."
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}
