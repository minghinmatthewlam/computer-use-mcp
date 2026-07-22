// Server-side client for the agent-cursor overlay helper process.
//
// On by default; opt out for headless/CI use with COMPUTER_USE_MCP_CURSOR=0.
// Commands travel over a FIFO shared by every server process: before each
// spatial action the server tells the singleton helper to glide to the target
// and waits the animation duration — the animate-then-act choreography. If no
// helper is alive, one is spawned; if another session's helper already is,
// it is reused. Each daemon connection gets its own visually distinct cursor
// (color + short session label) so concurrent agents are distinguishable.
// The overlay is purely cosmetic; it never moves the real cursor, and a
// dead/failed helper never blocks or fails the action.

import Foundation
#if os(macOS)
import CoreGraphics
#endif

actor AgentCursor {
    static let shared = AgentCursor()

    private var writeFD: Int32 = -1
    /// Keeps the spawned Process object alive so Foundation reaps it on exit.
    private var spawnedHelper: Process?
    private let enabled = Config.bool("cursor") != false
    // Awaited before the action fires. Slightly less than the overlay's own
    // animation so the cursor is still arriving as the action lands (natural)
    // while keeping per-action latency low.
    private let glideDuration = Duration.milliseconds(160)

    /// Glide the overlay cursor to a global top-left point, then return so the
    /// caller can deliver the actual action. No-op when disabled. `targetWindow`
    /// (the CGWindowID the action targets) z-orders the cursor just above that
    /// window, so occluders of the target also occlude the cursor.
    func glide(to point: CGPoint, targetWindow: CGWindowID? = nil) async {
        guard enabled else { return }
        guard let x = safeInt(point.x), let y = safeInt(point.y) else { return }
        let session = currentSessionID()
        guard await send(
            "move \(x) \(y) \(targetWindow ?? 0) \(session)\n", spawningIfNeeded: true
        ) else { return }
        try? await Task.sleep(for: glideDuration)
    }

    /// Tell a running helper the agent is still mid-task so the cursor's idle
    /// fade is postponed. Never spawns the helper — activity without movement
    /// (key presses, perception) should not summon a cursor that isn't there.
    func keepAlive() async {
        guard enabled else { return }
        _ = await send("ping\n", spawningIfNeeded: false)
    }

    /// Ripple at a global top-left point after an action landed there, so the
    /// user sees the click itself, not just the cursor arriving. Never spawns
    /// the helper: a glide always precedes the actions that pulse.
    func pulse(at point: CGPoint, targetWindow: CGWindowID? = nil) async {
        guard enabled else { return }
        guard let x = safeInt(point.x), let y = safeInt(point.y) else { return }
        let session = currentSessionID()
        _ = await send(
            "pulse \(x) \(y) \(targetWindow ?? 0) \(session)\n", spawningIfNeeded: false
        )
    }

    /// Switch the overlay's status pill to (or from) the recording state while
    /// teach mode captures the user. Spawns the helper so the indicator is
    /// visible for the whole recording, not just after the first glide.
    func setRecording(_ on: Bool) async {
        guard enabled else { return }
        _ = await send("record \(on ? "on" : "off")\n", spawningIfNeeded: on)
    }

    /// Remove this connection's cursor when the daemon session disconnects.
    /// Never spawns the helper and never fails the caller.
    func dropSession(_ session: Int32) async {
        guard enabled else { return }
        _ = await send("drop \(session)\n", spawningIfNeeded: false)
    }

    private func currentSessionID() -> String {
        if let session = DaemonSessionContext.sessionID {
            return String(session)
        }
        return overlayDefaultSessionID
    }

    private func send(_ command: String, spawningIfNeeded: Bool) async -> Bool {
        for attempt in 0..<2 {
            if writeFD < 0 {
                writeFD = Self.openFifo()
            }
            if writeFD < 0 {
                guard spawningIfNeeded else { return false }
                await spawnAndConnect()
                guard writeFD >= 0 else { return false }
            }
            // Tiny single-line writes to a FIFO with a live reader are atomic.
            // EPIPE (write fails, SIGPIPE is ignored at startup) means the
            // helper exited since we connected: drop the fd and retry once,
            // which reconnects or respawns.
            if command.withCString({ write(writeFD, $0, strlen($0)) >= 0 }) { return true }
            close(writeFD)
            writeFD = -1
            if !spawningIfNeeded || attempt == 1 { return false }
        }
        return false
    }

    private func spawnAndConnect() async {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        task.arguments = ["overlay"]
        task.standardInput = FileHandle.nullDevice  // commands arrive via the FIFO
        task.standardOutput = FileHandle.nullDevice
        // The helper outlives its spawner by design, so it must not hold the
        // server's stderr open (a host waiting for that fd to close would
        // hang). Inherit stderr only when overlay debugging is on.
        if ProcessInfo.processInfo.environment["COMPUTER_USE_MCP_OVERLAY_DEBUG"] != "1" {
            task.standardError = FileHandle.nullDevice
        }
        do {
            try task.run()
        } catch {
            return
        }
        spawnedHelper = task
        // Wait for the helper (this one, or an incumbent that wins the
        // singleton race) to open the read end.
        let deadline = Date().addingTimeInterval(2)
        while writeFD < 0 && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            writeFD = Self.openFifo()
        }
    }

    private static func openFifo() -> Int32 {
        // O_NONBLOCK write-open succeeds only while a reader (a live helper)
        // has the FIFO open, and fails with ENXIO/ENOENT otherwise — exactly
        // the liveness probe we need. It stays non-blocking for writes too:
        // commands are far smaller than the pipe buffer, so a short write can
        // only mean a wedged helper, and dropping a cosmetic glide is the
        // right degradation.
        open(overlayFifoPath(), O_WRONLY | O_NONBLOCK)
    }
}
