#if os(macOS)
// `overlay` subcommand — the agent-cursor overlay helper process.
//
// The MCP server is a headless async stdio process with no AppKit run loop, so
// the cosmetic cursor lives here, in its own process. This helper runs an
// .accessory NSApplication (no Dock icon, never frontmost) and glides per-session
// cursor glyphs toward target points it reads from a shared FIFO. Commands:
//   move/pulse <x> <y> [<win> [<session>]]
//   drop <session>
//   ping
//   record on|off
// Coordinates are global top-left screen space. The helper is a singleton (one
// process serves every concurrently running server) with one visually distinct
// cursor per session, and it never moves the real system cursor.
//
// One click-through borderless panel per display: with "Displays have separate
// Spaces" (the macOS default) a window is clipped to a single screen, so one
// panel — even sized to the union of all displays — can never draw on the
// others. Each session's cursor position is modeled in AppKit global coordinates
// and mirrored into every panel; each panel clips to its own screen, so the
// glyph appears on whichever display contains it (including straddling a
// boundary mid-glide).

#if os(macOS)
import AppKit
import QuartzCore
#endif

/// Stderr diagnostics, enabled with COMPUTER_USE_MCP_OVERLAY_DEBUG=1. The
/// helper inherits the server's stderr, so these reach the MCP host's logs.
func overlayDebug(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["COMPUTER_USE_MCP_OVERLAY_DEBUG"] == "1" else { return }
    FileHandle.standardError.write(Data("[overlay] \(message())\n".utf8))
}
@MainActor
func runOverlay() -> Never {
    // Singleton: the flock is held for the helper's lifetime (the kernel
    // releases it on exit or crash). A second helper — another server
    // spawning concurrently — exits and leaves the FIFO to the incumbent.
    let lockFD = open(overlayLockPath(), O_CREAT | O_WRONLY, 0o644)
    if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        overlayDebug("another overlay helper is already serving; exiting")
        exit(0)
    }
    prepareOverlayFifo()

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = OverlayController()
    app.delegate = controller
    controller.start()
    app.run()
    exit(0)
}
private func prepareOverlayFifo() {
    let path = overlayFifoPath()
    var status = stat()
    if stat(path, &status) == 0, (status.st_mode & S_IFMT) != S_IFIFO {
        unlink(path)  // a stale regular file would silently swallow commands
    }
    mkfifo(path, 0o600)  // EEXIST is fine: the FIFO persists across helpers
}

/// Per-session cursor state: color, label, layers, glide animation, and target.
@MainActor
private final class SessionCursor {
    let sessionID: String
    let color: NSColor
    let label: String
    var layers: [CALayer] = []
    var labelLayers: [CATextLayer] = []
    var visible = false
    var animating = false
    var fadeWork: DispatchWorkItem?
    var currentPoint = CGPoint.zero
    var startPoint = CGPoint.zero
    var targetPoint = CGPoint.zero
    var startTime: CFTimeInterval = 0
    /// Per-glide, scaled with distance: short hops stay snappy, long crossings
    /// stay smooth instead of teleporting.
    var duration: CFTimeInterval = 0.22
    var currentTarget: CGWindowID?

    init(sessionID: String) {
        self.sessionID = sessionID
        let components = overlaySessionColorComponents(for: sessionID)
        self.color = NSColor(
            calibratedRed: components.red,
            green: components.green,
            blue: components.blue,
            alpha: 1
        )
        self.label = overlaySessionLabel(for: sessionID)
    }
}

@MainActor
private final class OverlayController: NSObject, NSApplicationDelegate {
    /// The cursor glyph and click pulses live on their own panel per display so
    /// they can be dropped below a target's occluders (see applyTargetWindow)
    /// without dragging the always-on-top status chip down with them.
    private var cursorPanels: [NSPanel] = []
    private var displayLink: CADisplayLink?

    /// "Agent working" pill on every display, on a separate panel pinned at the
    /// idle level so it stays visible above app windows even while the cursor
    /// panel is lowered to shadow a background target. Disable with status_chip
    /// / COMPUTER_USE_MCP_STATUS_CHIP=0.
    private var chipPanels: [NSPanel] = []
    private var chipLayers: [CALayer] = []
    private var chipVisible = false
    private var chipFadeWork: DispatchWorkItem?
    private var recording = false
    private let chipEnabled = Config.bool("status_chip") != false

    /// One cursor per session id (color + short label).
    private var sessions: [String: SessionCursor] = [:]
    private let idleFadeDelay: TimeInterval = Config.double("cursor_idle_fade") ?? 12
    /// Last command of any kind, for the idle self-exit.
    private var lastCommand = Date()

    /// App name shown in the status chip when the target is not frontmost;
    /// nil renders the default "Agent working".
    private var backgroundTarget: String?
    /// Idle level: above every normal window so an untargeted cursor is always
    /// visible. When a target is set, its panel drops to `.normal` and is
    /// ordered just above the target, so anything occluding the target also
    /// occludes the cursor.
    private let panelIdleLevel: NSWindow.Level = .screenSaver
    /// Escape hatch (cursor_topmost / COMPUTER_USE_MCP_CURSOR_TOPMOST=1): keep
    /// the cursor unconditionally above every window, the pre-target-ordering
    /// behavior. Flip this if the target-relative ordering ever hides the glyph.
    private let topmostMode = Config.bool("cursor_topmost") == true

    func start() {
        guard NSScreen.screens.first != nil else { exit(0) }
        buildPanels()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        readFifo()
        scheduleIdleExitCheck()
    }

    // MARK: panels

    /// A borderless, click-through, all-Spaces panel sized to a screen — the
    /// shared shell for both the cursor and chip panels.
    private func makeClickThroughPanel(screen: NSScreen) -> NSPanel {
        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = panelIdleLevel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true  // click-through: real input passes through
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.wantsLayer = true
        panel.contentView = host
        return panel
    }

    private func buildPanels() {
        for screen in NSScreen.screens {
            let cursorPanel = makeClickThroughPanel(screen: screen)
            // Empty host: glyphs attach per session via attachLayers.
            cursorPanel.orderFrontRegardless()
            cursorPanels.append(cursorPanel)

            if chipEnabled {
                let chipPanel = makeClickThroughPanel(screen: screen)
                let chip = makeChipLayer(screenSize: screen.frame.size, scale: screen.backingScaleFactor)
                chip.opacity = chipVisible ? 1 : 0
                chipPanel.contentView?.layer?.addSublayer(chip)
                chipPanel.orderFrontRegardless()
                chipPanels.append(chipPanel)
                chipLayers.append(chip)
            }
        }
        for session in sessions.values {
            attachLayers(for: session)
            syncLayers(for: session)
        }
    }

    @objc private func screensChanged() {
        displayLink?.invalidate()
        displayLink = nil
        for session in sessions.values {
            session.animating = false
            for layer in session.layers {
                layer.removeFromSuperlayer()
            }
            for layer in session.labelLayers {
                layer.removeFromSuperlayer()
            }
            session.layers.removeAll()
            session.labelLayers.removeAll()
        }
        for panel in cursorPanels + chipPanels { panel.orderOut(nil) }
        cursorPanels.removeAll()
        chipPanels.removeAll()
        chipLayers.removeAll()
        buildPanels()
        // Panels were rebuilt at the idle level; restore the latest target z-order.
        if let session = sessions.values.first(where: { $0.currentTarget != nil }) {
            let target = session.currentTarget
            session.currentTarget = nil
            applyTargetWindow(target, for: session)
        }
        refreshChipText()
    }

    /// Look up or create the cursor for `sessionID`, attaching layers on first use.
    private func sessionCursor(_ sessionID: String) -> SessionCursor {
        if let existing = sessions[sessionID] { return existing }
        let session = SessionCursor(sessionID: sessionID)
        if let primary = NSScreen.screens.first {
            session.currentPoint = CGPoint(x: primary.frame.midX, y: primary.frame.midY)
        }
        sessions[sessionID] = session
        attachLayers(for: session)
        syncLayers(for: session)
        return session
    }

    /// Add a glyph + short label layer to every cursor panel for this session.
    private func attachLayers(for session: SessionCursor) {
        for layer in session.layers {
            layer.removeFromSuperlayer()
        }
        for layer in session.labelLayers {
            layer.removeFromSuperlayer()
        }
        session.layers.removeAll()
        session.labelLayers.removeAll()

        let opacity: Float = session.visible ? 1 : 0
        for panel in cursorPanels {
            let glyph = CALayer()
            glyph.contents = cursorGlyph(color: session.color)
            glyph.contentsScale = panel.backingScaleFactor
            glyph.bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
            glyph.anchorPoint = CGPoint(x: 0.0625, y: 0.9375)  // arrow tip at (2,30)
            glyph.opacity = opacity
            panel.contentView?.layer?.addSublayer(glyph)
            session.layers.append(glyph)

            let label = CATextLayer()
            label.string = session.label
            label.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
            label.fontSize = 9
            label.foregroundColor = NSColor.white.cgColor
            label.backgroundColor = session.color.withAlphaComponent(0.9).cgColor
            label.cornerRadius = 3
            label.alignmentMode = .center
            label.contentsScale = panel.backingScaleFactor
            label.bounds = CGRect(x: 0, y: 0, width: 22, height: 12)
            label.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            label.opacity = opacity
            // CATextLayer draws upside-down unless flipped for AppKit's bottom-up space.
            label.isWrapped = false
            panel.contentView?.layer?.addSublayer(label)
            session.labelLayers.append(label)
        }
    }

    /// Remove one session's cursor (layers + state) when its connection drops.
    private func dropSession(_ sessionID: String) {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        session.fadeWork?.cancel()
        session.fadeWork = nil
        session.animating = false
        for layer in session.layers {
            layer.removeFromSuperlayer()
        }
        for layer in session.labelLayers {
            layer.removeFromSuperlayer()
        }
        resetTargetWindowIfNeeded()
        ensureDisplayLink()
    }

    /// Mirror a session's global cursor position into every cursor panel's local
    /// space; each panel clips to its own screen, so the glyph shows where it belongs.
    private func syncLayers(for session: SessionCursor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, panel) in cursorPanels.enumerated() {
            guard index < session.layers.count else { continue }
            let pos = CGPoint(
                x: session.currentPoint.x - panel.frame.origin.x,
                y: session.currentPoint.y - panel.frame.origin.y
            )
            session.layers[index].position = pos
            if index < session.labelLayers.count {
                // Small tag just to the right of the arrow tip.
                session.labelLayers[index].position = CGPoint(x: pos.x + 20, y: pos.y - 6)
            }
        }
        CATransaction.commit()
    }

    /// Height of the primary display (origin at 0,0), used to flip Quartz
    /// global top-left coordinates into AppKit bottom-left coordinates. This is
    /// NOT NSScreen.main (that follows the key window).
    private var primaryHeight: CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?.frame.height ?? 0
    }

    // MARK: FIFO command loop

    /// Read commands from the shared FIFO on a background thread, marshaling
    /// them to the main actor. The blocking open waits for the first writer;
    /// an empty read means every writer closed (servers exited), so the FIFO
    /// is reopened and the helper waits for the next one.
    private nonisolated func readFifo() {
        DispatchQueue.global(qos: .userInteractive).async {
            let path = overlayFifoPath()
            while true {
                let fd = open(path, O_RDONLY)
                if fd < 0 {
                    Thread.sleep(forTimeInterval: 0.25)
                    continue
                }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                var pending = ""
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    pending += String(data: data, encoding: .utf8) ?? ""
                    while let newline = pending.firstIndex(of: "\n") {
                        let line = String(pending[..<newline])
                        pending = String(pending[pending.index(after: newline)...])
                        Self.handle(command: line)
                    }
                }
            }
        }
    }

    private nonisolated static func handle(command line: String) {
        overlayDebug("recv: \(line)")
        guard let command = OverlayCommand.parse(line) else { return }
        DispatchQueue.main.async {
            let controller = NSApp.delegate as? OverlayController
            switch command {
            case .ping:
                controller?.noteActivity()
            case .record(let on):
                controller?.setRecording(on)
            case .drop(let session):
                controller?.dropSession(session)
            case .move(let x, let y, let window, let session):
                controller?.beginGlide(
                    toGlobalTopLeft: CGPoint(x: x, y: y),
                    targetWindow: window.map { CGWindowID($0) },
                    sessionID: session
                )
            case .pulse(let x, let y, let window, let session):
                controller?.showPulse(
                    atGlobalTopLeft: CGPoint(x: x, y: y),
                    targetWindow: window.map { CGWindowID($0) },
                    sessionID: session
                )
            }
        }
    }

    // MARK: lifetime

    /// Without a spawning parent to die with (the FIFO outlives any single
    /// server), the helper reaps itself after a long quiet period instead.
    private func scheduleIdleExitCheck() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastCommand) > overlayIdleExitDelay {
                overlayDebug("idle exit")
                exit(0)
            }
            self.scheduleIdleExitCheck()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    // MARK: animation

    fileprivate func beginGlide(
        toGlobalTopLeft point: CGPoint, targetWindow: CGWindowID?, sessionID: String
    ) {
        let session = sessionCursor(sessionID)
        lastCommand = Date()
        applyTargetWindow(targetWindow, for: session)
        showChip()
        session.targetPoint = appKitPoint(fromGlobalTopLeft: point)
        session.startPoint = session.currentPoint
        session.startTime = CACurrentMediaTime()
        let distance = hypot(
            session.targetPoint.x - session.startPoint.x,
            session.targetPoint.y - session.startPoint.y
        )
        session.duration = min(0.32, max(0.12, distance / 2400))
        session.animating = true
        overlayDebug(
            "beginGlide session=\(sessionID) cg=\(point) appkit=\(session.targetPoint) from=\(session.startPoint)"
        )
        session.fadeWork?.cancel()
        session.fadeWork = nil
        session.visible = true
        let allLayers: [CALayer] = session.layers + session.labelLayers
        setOpacity(1, of: allLayers, animationDuration: nil)

        ensureDisplayLink()
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        var anyAnimating = false
        for session in sessions.values where session.animating {
            anyAnimating = true
            let elapsed = now - session.startTime
            let progress = min(1, elapsed / session.duration)
            let eased = easeOutCubic(progress)
            session.currentPoint = CGPoint(
                x: session.startPoint.x + (session.targetPoint.x - session.startPoint.x) * eased,
                y: session.startPoint.y + (session.targetPoint.y - session.startPoint.y) * eased
            )
            syncLayers(for: session)

            if progress >= 1 {
                session.animating = false
                overlayDebug("glide done session=\(session.sessionID) at \(session.currentPoint)")
                scheduleIdleFade(for: session)
            }
        }
        if !anyAnimating {
            displayLink?.isPaused = true  // stop per-frame wakeups while idle
        }
    }

    /// Start or resume the display link when any session is animating; pause when none are.
    private func ensureDisplayLink() {
        let anyAnimating = sessions.values.contains(where: \.animating)
        guard anyAnimating else {
            displayLink?.isPaused = true
            return
        }
        if displayLink == nil, let view = cursorPanels.first?.contentView {
            let link = view.displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    /// Keep-alive ping from any server: postpone the idle fade (if a fade is
    /// pending) and the idle self-exit. Perception-only work never summons the
    /// cursor, but it does show the status chip — the agent IS working.
    fileprivate func noteActivity() {
        lastCommand = Date()
        showChip()
        for session in sessions.values {
            guard session.visible, session.fadeWork != nil else { continue }
            session.fadeWork?.cancel()
            scheduleIdleFade(for: session)
        }
    }

    /// Fade one session's cursor away after a quiet period so it does not sit
    /// on the last target forever; the next glide restores it instantly.
    private func scheduleIdleFade(for session: SessionCursor) {
        let sessionID = session.sessionID
        let work = DispatchWorkItem { [weak self] in
            guard let self, let session = self.sessions[sessionID], !session.animating else { return }
            session.visible = false
            let allLayers: [CALayer] = session.layers + session.labelLayers
            self.setOpacity(0, of: allLayers, animationDuration: 0.4)
            session.currentTarget = nil
            // No target to shadow while every cursor is hidden: return the panels
            // to the idle level so the next glide starts from a known state.
            self.resetTargetWindowIfNeeded()
            overlayDebug("idle fade session=\(sessionID)")
        }
        session.fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleFadeDelay, execute: work)
    }

    /// Set opacity on layers, animated over `animationDuration` seconds or
    /// instantly when nil. The single fade helper for cursor and chip.
    private func setOpacity(_ value: Float, of layers: [CALayer], animationDuration: TimeInterval?) {
        CATransaction.begin()
        if let animationDuration {
            CATransaction.setAnimationDuration(animationDuration)
        } else {
            CATransaction.setDisableActions(true)
        }
        for layer in layers { layer.opacity = value }
        CATransaction.commit()
    }

    /// Quartz global top-left → AppKit bottom-left, using the PRIMARY screen
    /// height so it's correct on any display in the unified coordinate plane.
    private func appKitPoint(fromGlobalTopLeft point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    // MARK: target window z-order

    /// Order the cursor panel directly above the target window so anything
    /// occluding the target also occludes the cursor — but ONLY in the trust
    /// case that motivates it: a *different* app is frontmost AND its front
    /// window actually *overlaps* the target, so the cursor could otherwise
    /// appear to float over the app that is covering the target.
    ///
    /// In every other case — topmost escape hatch, the target itself frontmost,
    /// or the focused app merely side-by-side / on another display / a
    /// fullscreen Space elsewhere (no overlap) — the cursor stays at the idle
    /// level above all windows. Dropping a panel to `.normal` loses to
    /// fullscreen and cross-Space compositing, which made the glyph vanish while
    /// the target was plainly visible (the #18 regression); "prefer visible" is
    /// the safe default, and clipping is scoped to genuine occlusion (proven by
    /// the occlusion self-test).
    ///
    /// Panels are shared across sessions, so the most recent apply wins z-order.
    private func applyTargetWindow(_ id: CGWindowID?, for session: SessionCursor) {
        guard let id, let info = windowInfo(for: id) else {
            session.currentTarget = nil
            resetTargetWindowIfNeeded()
            return
        }
        let sameTarget = id == session.currentTarget
        session.currentTarget = id

        let center = appKitPoint(fromGlobalTopLeft: CGPoint(x: info.bounds.midX, y: info.bounds.midY))
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let isBackground = info.ownerPID != 0 && frontPID != nil && frontPID != info.ownerPID
        // Genuine occlusion only: the frontmost app's front window must overlap
        // the target's frame (both in Quartz global coordinates). Side-by-side
        // or cross-display focus does not overlap, so the cursor stays visible.
        let shouldClip =
            !topmostMode && isBackground
            && frontmostAppFrontWindowBounds(pid: frontPID).map { $0.intersects(info.bounds) } == true

        // Only the cursor panels move; the chip panels stay pinned on top.
        for panel in cursorPanels {
            if shouldClip && panel.frame.contains(center) {
                panel.level = .normal
                // Cross-process ordering: `relativeTo` takes the other window's
                // CGWindowID even when it belongs to a different app.
                panel.order(.above, relativeTo: Int(id))
            } else if panel.level != panelIdleLevel {
                panel.level = panelIdleLevel
                panel.orderFrontRegardless()
            }
        }

        let newBackgroundTarget = isBackground ? info.ownerName : nil
        if newBackgroundTarget != backgroundTarget || !sameTarget {
            backgroundTarget = newBackgroundTarget
            refreshChipText()
        }
    }

    /// Bounds (Quartz global top-left) of the frontmost app's front on-screen
    /// window, or nil if it has none — used to decide whether that app is
    /// actually covering the target or merely beside/behind it on another Space.
    private func frontmostAppFrontWindowBounds(pid: pid_t?) -> CGRect? {
        guard let pid,
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for window in list {  // front-to-back
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                (window[kCGWindowLayer as String] as? Int) == 0,
                let boundsDict = window[kCGWindowBounds as String]
            else { continue }
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict as! CFDictionary, &bounds) else { return nil }
            return bounds
        }
        return nil
    }

    /// Return cursor panels to the idle level when no session still shadows a
    /// target (idle fade, session drop, target window gone). If another session
    /// still has a target, re-apply that affinity instead.
    private func resetTargetWindowIfNeeded() {
        if let remaining = sessions.values.first(where: { $0.currentTarget != nil }) {
            // Re-apply (window gone → apply clears it and recurses once).
            applyTargetWindow(remaining.currentTarget, for: remaining)
            return
        }
        guard backgroundTarget != nil || cursorPanels.contains(where: { $0.level != panelIdleLevel })
        else { return }
        backgroundTarget = nil
        for panel in cursorPanels where panel.level != panelIdleLevel {
            panel.level = panelIdleLevel
            panel.orderFrontRegardless()
        }
        refreshChipText()
    }

    /// Bounds (global top-left), owner pid, and owner name for a CGWindowID, or
    /// nil if the window no longer exists — the caller then falls back to the
    /// idle level rather than pinning to a dead window.
    private func windowInfo(for id: CGWindowID) -> (bounds: CGRect, ownerPID: pid_t, ownerName: String)? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
            let dict = list.first,
            let boundsDict = dict[kCGWindowBounds as String]
        else { return nil }
        var bounds = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(boundsDict as! CFDictionary, &bounds) else { return nil }
        let ownerPID = (dict[kCGWindowOwnerPID as String] as? pid_t) ?? 0
        let ownerName = (dict[kCGWindowOwnerName as String] as? String) ?? ""
        return (bounds, ownerPID, ownerName)
    }

    // MARK: click pulse

    /// Expanding ring at the point an action just landed — the visual "the
    /// click happened", distinct from the cursor arriving.
    fileprivate func showPulse(
        atGlobalTopLeft point: CGPoint, targetWindow: CGWindowID?, sessionID: String
    ) {
        let session = sessionCursor(sessionID)
        lastCommand = Date()
        applyTargetWindow(targetWindow, for: session)
        showChip()
        // Pulses ride the cursor panels, so they clip against the target's
        // occluders exactly as the glyph does.
        let global = appKitPoint(fromGlobalTopLeft: point)
        for panel in cursorPanels {
            let local = CGPoint(x: global.x - panel.frame.origin.x, y: global.y - panel.frame.origin.y)
            guard panel.contentView?.bounds.contains(local) == true,
                let host = panel.contentView?.layer
            else { continue }

            let radius: CGFloat = 13
            let ring = CAShapeLayer()
            ring.path = CGPath(
                ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2),
                transform: nil
            )
            ring.fillColor = nil
            ring.strokeColor = session.color.cgColor
            ring.lineWidth = 3
            ring.contentsScale = panel.backingScaleFactor
            ring.position = local
            host.addSublayer(ring)

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.35
            scale.toValue = 1.8
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.95
            fade.toValue = 0.0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 0.45
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            ring.add(group, forKey: "pulse")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                ring.removeFromSuperlayer()
            }
        }
    }

    // MARK: status chip

    /// Show the "Agent working" pill; it fades after the same quiet period as
    /// the cursor. Every command (glide, pulse, keep-alive ping) refreshes it.
    /// While recording the pill stays pinned (see setRecording).
    private func showChip() {
        guard chipEnabled, !chipLayers.isEmpty, !recording else { return }
        if !chipVisible {
            chipVisible = true
            setOpacity(1, of: chipLayers, animationDuration: 0.3)
        }
        chipFadeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.chipLayers.isEmpty, !self.recording else { return }
            self.chipVisible = false
            self.setOpacity(0, of: self.chipLayers, animationDuration: 0.3)
        }
        chipFadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleFadeDelay, execute: work)
    }

    /// Teach mode: pin the pill in a red "Recording" state (no idle fade)
    /// while the user demonstrates, and revert when recording stops.
    fileprivate func setRecording(_ on: Bool) {
        recording = on
        for chip in chipLayers {
            (chip.sublayers?.first as? CALayer)?.backgroundColor =
                (on ? NSColor.systemRed : NSColor.systemBlue).cgColor
        }
        refreshChipText()
        if on {
            lastCommand = Date()
            chipFadeWork?.cancel()
            chipVisible = true
            setOpacity(1, of: chipLayers, animationDuration: 0.3)
        } else {
            chipVisible = false
            setOpacity(0, of: chipLayers, animationDuration: 0.3)
        }
    }

    /// The pill's text: names a background target when the target app isn't
    /// frontmost, so the user can see the agent is working elsewhere.
    private var chipText: String {
        if recording { return "Recording" }
        if let backgroundTarget { return "Working in \(backgroundTarget) (background)" }
        return "Agent working"
    }

    /// Re-lay out every chip for the current `chipText` (the pill grows to fit
    /// the longer "Working in … (background)" copy and stays right-anchored).
    private func refreshChipText() {
        guard chipEnabled else { return }
        let text = chipText
        for (index, chip) in chipLayers.enumerated() where index < chipPanels.count {
            layoutChip(chip, text: text, screenWidth: chipPanels[index].frame.width)
        }
    }

    /// Pill with a colored dot and status text, top-right of its display just
    /// below the menu bar. Click-through like everything else.
    private func makeChipLayer(screenSize: CGSize, scale: CGFloat) -> CALayer {
        let height: CGFloat = 28
        let chip = CALayer()
        chip.frame = CGRect(x: 0, y: screenSize.height - height - 40, width: 0, height: height)
        chip.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        chip.cornerRadius = height / 2
        chip.borderWidth = 1
        chip.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        let dot = CALayer()
        dot.frame = CGRect(x: 12, y: (height - 8) / 2, width: 8, height: 8)
        dot.cornerRadius = 4
        dot.backgroundColor = NSColor.systemBlue.cgColor
        chip.addSublayer(dot)

        let text = CATextLayer()
        text.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        text.fontSize = 12
        text.foregroundColor = NSColor.white.cgColor
        text.alignmentMode = .left
        text.contentsScale = scale
        chip.addSublayer(text)

        layoutChip(chip, text: chipText, screenWidth: screenSize.width)
        return chip
    }

    /// Size the pill to its text and pin it 16pt from the right screen edge.
    private func layoutChip(_ chip: CALayer, text: String, screenWidth: CGFloat) {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let height: CGFloat = 28
        let width = 28 + textWidth + 14  // dot inset + text + trailing pad
        chip.frame = CGRect(
            x: screenWidth - width - 16, y: chip.frame.origin.y,
            width: width, height: height
        )
        if let textLayer = chip.sublayers?.compactMap({ $0 as? CATextLayer }).first {
            textLayer.string = text
            textLayer.frame = CGRect(x: 28, y: 6.5, width: textWidth + 2, height: 16)
        }
    }

    private func easeOutCubic(_ t: Double) -> Double {
        let p = max(0, min(1, t))
        return 1 - pow(1 - p, 3)
    }

    // MARK: glyph

    private func cursorGlyph(color: NSColor) -> CGImage? {
        // Rendered at 2x so it stays crisp on Retina displays (each layer's
        // contentsScale maps it back to 32pt).
        let scale: CGFloat = 2
        let image = NSImage(size: NSSize(width: 32 * scale, height: 32 * scale))
        image.lockFocus()
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
        // The classic macOS arrow-with-tail silhouette, in the session color
        // with a white outline: reads as a real mouse but is clearly the agent's.
        // Tip at (2,30).
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 2.0, y: 30.0))    // tip
        arrow.line(to: NSPoint(x: 2.0, y: 4.5))     // left edge straight down
        arrow.line(to: NSPoint(x: 7.9, y: 9.8))     // notch toward the tail
        arrow.line(to: NSPoint(x: 12.0, y: 0.6))    // tail outer
        arrow.line(to: NSPoint(x: 16.3, y: 2.4))    // tail tip
        arrow.line(to: NSPoint(x: 12.1, y: 11.1))   // tail inner
        arrow.line(to: NSPoint(x: 19.6, y: 11.1))   // right wing
        arrow.close()
        color.setFill()
        arrow.fill()
        NSColor.white.setStroke()
        arrow.lineWidth = 1.7
        arrow.lineJoinStyle = .round
        arrow.stroke()
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
#else
import Foundation

func runOverlay() -> Never {
    fatalError("The agent cursor overlay is unsupported on Linux.")
}
#endif
