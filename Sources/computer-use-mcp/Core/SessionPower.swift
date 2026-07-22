// Power and lock-screen behavior for active sessions.
//
// While an agent is actively driving apps, the Mac must not idle-sleep out
// from under a long task — a power assertion is held during activity and
// released after a quiet period. The display is deliberately allowed to
// sleep; background delivery does not need it. When the screen is actually
// locked, mutating tools pause with a recoverable error instead of operating
// an invisible session (unlocking is the user's decision — no Codex-style
// auto-unlock behind a fake lock screen).

import Foundation
#if os(macOS)
import CoreGraphics
import IOKit.pwr_mgt
#endif

/// Recoverable pause for mutating tools while the screen is locked.
/// Read-only perception stays available. `isLocked` is an autoclosure so the
/// window-server query runs only after the (cheap) mutating-tool check.
func lockedScreenMessage(toolName: String, isLocked: @autoclosure () -> Bool) -> String? {
    guard isMutatingTool(toolName), isLocked() else { return nil }
    return
        "The screen is locked, so mutating computer-use actions are paused. Ask the user "
        + "to unlock the Mac and retry. Read-only tools (get_app_state, find, read_text) "
        + "remain available."
}

func screenIsLocked() -> Bool {
    screenIsLocked(session: CGSessionCopyCurrentDictionary() as? [String: Any])
}

/// Pure lock decision from a session dictionary snapshot.
/// A missing dictionary fails closed (locked) so mutating tools do not
/// proceed on an unknown session. When the dictionary is present, a missing
/// or false `CGSSessionScreenIsLocked` means unlocked.
func screenIsLocked(session: [String: Any]?) -> Bool {
    guard let session else { return true }
    return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
}

/// Holds a prevent-idle-system-sleep assertion while tool calls are flowing,
/// released after a quiet period. Disable with no_sleep_assertion.
actor SleepAssertion {
    static let shared = SleepAssertion()
    static let isEnabled: Bool = Config.bool("no_sleep_assertion") != true
    static let idleReleaseSeconds: Double = 120

    private var assertionID = IOPMAssertionID(0)
    private var held = false
    private var releaseTask: Task<Void, Never>?

    func noteActivity() {
        guard Self.isEnabled else { return }
        if !held {
            var id = IOPMAssertionID(0)
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "computer-use-mcp active session" as CFString,
                &id
            )
            if status == kIOReturnSuccess {
                assertionID = id
                held = true
            }
        }
        releaseTask?.cancel()
        releaseTask = Task {
            try? await Task.sleep(for: .seconds(Self.idleReleaseSeconds))
            guard !Task.isCancelled else { return }
            await self.release()
        }
    }

    private func release() {
        guard held else { return }
        IOPMAssertionRelease(assertionID)
        held = false
    }
}
