 #if os(macOS)
// Background-safe synthetic input delivery.
//
// The ladder, in order of preference, for delivering a mouse/scroll/key event
// without moving the user's real cursor or stealing focus:
//
//   Tier 1  AX action (AXPress etc.)        — handled by callers, no event posted
//   Tier 2  per-window NSEvent → CGEventPostToPid  — routed to a specific window
//   Tier 2.5 SLEventPostToPid (SkyLight SPI) — FLAGGED prototype, default off
//   Tier 3  CGEventPostToPid (no window affinity)  — delivered to the pid
//   Tier 4  global cursor (CGWarp + session tap)   — GUARDED, opt-in, restores cursor
//
// Tiers 2–3 use CGEventPostToPid, which delivers to a process without
// foreground activation and never touches the system cursor. It is documented
// as app-dependent (some apps that require real key focus may drop events);
// there is no reliable success signal, so escalation to Tier 4 is never
// automatic — it requires the caller's explicit opt-in.

import Foundation
#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
#endif

// Private SPI mapping an AX window element to its CGWindowID, used as the
// NSEvent windowNumber. Undocumented but stable; always guard the result.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

func windowID(for axWindow: AXUIElement) -> CGWindowID? {
    var id = CGWindowID(0)
    guard _AXUIElementGetWindow(axWindow, &id) == .success, id != 0 else { return nil }
    return id
}

enum InputTier: String {
    case accessibilityAction = "tier1-ax-action"
    case accessibilityAttribute = "tier1-ax-attribute"
    case perWindow = "tier2-per-window-nsevent"
    case skyLight = "tier25-skylight-sleventpostto-pid"
    case perPid = "tier3-cgeventpostto-pid"
    case globalCursor = "tier4-global-cursor"
    case pasteboard = "pasteboard"
    case launchServices = "launchservices"
    case windowManagement = "ax-window-management"
}

enum KeyDeliveryMode: String, Equatable {
    case skyLight = "tier25-skylight-sleventpostto-pid"
    case perPid = "tier3-cgeventpostto-pid"
    case globalSessionTap = "tier4-global-session-tap"
}

/// Why the ladder skipped a higher-priority tier for this delivery. Pure
/// telemetry — the tier actually chosen is unchanged; these only explain it,
/// so a caller (and the agent reading _meta) knows whether the event took the
/// precise AX path or a droppable synthetic one, and why the earlier tiers
/// were unavailable.
enum FallbackReason: String, Equatable, Sendable {
    /// No accessibility action for this gesture on the target (Tier 1 skipped);
    /// delivery fell to a synthetic event.
    case axActionUnsupported = "ax-action-unsupported"
    /// No CGWindowID resolved for the window, so window-affined Tier 2 was
    /// unavailable and the event went to the pid (Tier 3).
    case windowNumberUnresolved = "window-number-unresolved"
    /// The window exposed no frame, so Tier 2 coordinate bridging was
    /// impossible and the event went to the pid (Tier 3).
    case windowFrameUnresolved = "window-frame-unresolved"
    /// NSEvent→CGEvent window bridging returned nil despite a resolvable
    /// window, so Tier 2 fell to the pid (Tier 3).
    case eventBridgeFailed = "event-bridge-failed"
    /// The optional SkyLight Tier 2.5 rung was enabled, but the private
    /// SLEventPostToPid symbol was absent or posting failed, so delivery fell
    /// through to public per-pid CoreGraphics. This private SPI is dlopen'd and
    /// env-gated because it may break across macOS releases and can be rejected
    /// by notarization/App Review.
    case skyLightUnavailable = "skylight-unavailable"
    /// The caller opted into the guarded global-cursor path (Tier 4),
    /// bypassing the background-safe tiers.
    case globalCursorRequested = "global-cursor-requested"
    /// scroll only: no scrollable container was found on the target's AX
    /// ancestor chain, so the wheel was posted at the raw hit point.
    case noScrollContainerFound = "no-scroll-container-found"
    /// scroll only: the container's AX page-scroll action fired but no movement
    /// was observed, so delivery fell through to the synthetic wheel.
    case scrollActionUnverified = "scroll-action-unverified"

    // Multi-strategy AX chain rungs that fired but whose effect was not
    // observed, so the chain fell through to the next rung. Surfaced so the
    // agent sees which AX strategies were tried before the one that landed (or
    // before delivery fell through to synthetic injection).
    case chainAXPressUnverified = "chain-ax-press-unverified"
    case chainAXConfirmUnverified = "chain-ax-confirm-unverified"
    case chainAXOpenUnverified = "chain-ax-open-unverified"
    case chainAXPickUnverified = "chain-ax-pick-unverified"
    case chainSelectionRelayUnverified = "chain-selection-relay-unverified"
    case chainChildActionUnverified = "chain-child-action-unverified"
    case chainAncestorActionUnverified = "chain-ancestor-action-unverified"
}

/// The tier a delivery actually used plus, in tier order, why each
/// higher-priority tier was skipped.
struct DeliveryOutcome: Equatable {
    let tier: InputTier
    let fallbackReasons: [FallbackReason]

    init(tier: InputTier, fallbackReasons: [FallbackReason] = []) {
        self.tier = tier
        self.fallbackReasons = fallbackReasons
    }
}

/// Reasons window-affined Tier 2 was unavailable for a context, given whether
/// the NSEvent→CGEvent bridge succeeded. Pure and deterministic so the mapping
/// is unit-testable; the live path calls it with the real bridge result. An
/// empty result means Tier 2 was viable (and used).
func perWindowFallbackReasons(context: DeliveryContext, bridgeSucceeded: Bool) -> [FallbackReason] {
    var reasons: [FallbackReason] = []
    if context.windowNumber == nil { reasons.append(.windowNumberUnresolved) }
    if context.windowFrame == nil { reasons.append(.windowFrameUnresolved) }
    // Both inputs present but the bridge still failed: the bridge itself is the
    // reason Tier 2 was skipped, not a missing input.
    if context.windowNumber != nil, context.windowFrame != nil, !bridgeSucceeded {
        reasons.append(.eventBridgeFailed)
    }
    return reasons
}

/// Tiers that post synthetic events an app can silently drop (no success
/// signal). AX tiers fail loudly and the global tiers use the real input
/// path, so neither needs a "did it land" hint. Kept next to the tier enums
/// so a new tier is classified where it is defined.
func isDroppableBackgroundDeliveryTier(_ rawTier: String) -> Bool {
    rawTier == InputTier.perWindow.rawValue
        || rawTier == InputTier.skyLight.rawValue
        || rawTier == InputTier.perPid.rawValue
        || rawTier == KeyDeliveryMode.skyLight.rawValue
        || rawTier == KeyDeliveryMode.perPid.rawValue
}

struct DeliveryContext {
    let pid: pid_t
    /// CGWindowID of the target window, when resolvable (enables Tier 2).
    let windowNumber: CGWindowID?
    /// Target window's global frame (top-left origin), for coordinate conversion.
    let windowFrame: CGRect?
    let allowGlobalCursor: Bool
}

enum MouseButtonKind {
    case left, right, middle

    var cgButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }
    var downType: CGEventType {
        switch self {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }
    var upType: CGEventType {
        switch self {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }
}

/// Deliver a click at a global point. Returns the tier actually used.
///
/// Background-safe by default (Tier 2/3). When the caller explicitly opts in
/// with allow_global_cursor — the escape hatch for stubborn apps that drop
/// per-pid events — it uses the Tier 4 real-cursor path instead.
@discardableResult
func deliverClick(
    at point: CGPoint, button: MouseButtonKind, clickCount: Int, context: DeliveryContext
) throws -> DeliveryOutcome {
    if context.allowGlobalCursor {
        let tier = deliverClickGlobal(at: point, button: button, clickCount: clickCount, context: context)
        return DeliveryOutcome(tier: tier, fallbackReasons: [.globalCursorRequested])
    }

    let source = CGEventSource(stateID: .privateState)
    func makeEvent(_ type: CGEventType, clickState: Int) -> CGEvent? {
        let event = CGEvent(
            mouseEventSource: source, mouseType: type,
            mouseCursorPosition: point, mouseButton: button.cgButton
        )
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        return event
    }

    var pairs: [(down: CGEvent, up: CGEvent)] = []
    for clickState in 1...clickCount {
        guard let down = makeEvent(button.downType, clickState: clickState),
            let up = makeEvent(button.upType, clickState: clickState)
        else {
            throw ToolError.failed("Could not synthesize a click event.")
        }
        pairs.append((down, up))
    }

    if let windowNumber = context.windowNumber, let frame = context.windowFrame {
        let bridgedPairs = pairs.compactMap { pair -> (down: CGEvent, up: CGEvent)? in
            guard
                let localDown = bridgedWindowEvent(from: pair.down, point: point, windowNumber: windowNumber, windowFrame: frame),
                let localUp = bridgedWindowEvent(from: pair.up, point: point, windowNumber: windowNumber, windowFrame: frame)
            else {
                return nil
            }
            return (localDown, localUp)
        }
        if bridgedPairs.count == pairs.count {
            for pair in bridgedPairs {
                pair.down.postToPid(context.pid)
                pair.up.postToPid(context.pid)
            }
            return DeliveryOutcome(
                tier: .perWindow,
                fallbackReasons: perWindowFallbackReasons(context: context, bridgeSucceeded: true)
            )
        }
    }

    let status = skyLightStatus(LiveSkyLightEventPosting.shared)
    let postedSkyLight = postSkyLightMouseClick(
        point: point, button: button, clickCount: clickCount, context: context)
    if postedSkyLight {
        return DeliveryOutcome(
            tier: .skyLight,
            fallbackReasons: syntheticFallbackReasons(context: context, bridgeSucceeded: false, skyLightStatus: .available)
        )
    }
    let finalSkyLightStatus: SkyLightAttemptStatus = status == .available ? .unavailable : status

    for pair in pairs {
        pair.down.postToPid(context.pid)
        pair.up.postToPid(context.pid)
    }
    return DeliveryOutcome(
        tier: .perPid,
        fallbackReasons: syntheticFallbackReasons(context: context, bridgeSucceeded: false, skyLightStatus: finalSkyLightStatus)
    )
}

func syntheticFallbackReasons(
    context: DeliveryContext,
    bridgeSucceeded: Bool,
    skyLightStatus: SkyLightAttemptStatus
) -> [FallbackReason] {
    var reasons = perWindowFallbackReasons(context: context, bridgeSucceeded: bridgeSucceeded)
    if !bridgeSucceeded, skyLightStatus == .unavailable {
        reasons.append(.skyLightUnavailable)
    }
    return reasons
}

/// Build a window-routed CGEvent by bridging an NSEvent carrying a windowNumber.
/// NSEvent locations are window-local, bottom-left origin.
private func bridgedWindowEvent(
    from cgEvent: CGEvent, point: CGPoint, windowNumber: CGWindowID, windowFrame: CGRect
) -> CGEvent? {
    let localX = point.x - windowFrame.origin.x
    // Window-local bottom-left Y: the distance up from the window's bottom
    // edge. The screen-height terms of the top-left→bottom-left flip cancel,
    // so this holds on any display — offset and negative origins included.
    let localY = windowFrame.maxY - point.y

    let nsType: NSEvent.EventType
    switch cgEvent.type {
    case .leftMouseDown: nsType = .leftMouseDown
    case .leftMouseUp: nsType = .leftMouseUp
    case .rightMouseDown: nsType = .rightMouseDown
    case .rightMouseUp: nsType = .rightMouseUp
    case .otherMouseDown: nsType = .otherMouseDown
    case .otherMouseUp: nsType = .otherMouseUp
    case .leftMouseDragged: nsType = .leftMouseDragged
    default: return nil
    }
    let clickState = Int(cgEvent.getIntegerValueField(.mouseEventClickState))
    let event = NSEvent.mouseEvent(
        with: nsType, location: NSPoint(x: localX, y: localY), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Int(windowNumber),
        context: nil, eventNumber: 0, clickCount: max(1, clickState), pressure: nsType.isDown ? 1 : 0
    )
    return event?.cgEvent
}

private extension NSEvent.EventType {
    // Button-held events carry full pressure (down and drag); releases carry 0.
    var isDown: Bool {
        self == .leftMouseDown || self == .rightMouseDown || self == .otherMouseDown
            || self == .leftMouseDragged
    }
}

/// Tier 4: guarded global cursor. Moves the real cursor, posts to the session
/// tap, then restores the cursor. Only reached on explicit opt-in.
private func deliverClickGlobal(
    at point: CGPoint, button: MouseButtonKind, clickCount: Int, context: DeliveryContext
) -> InputTier {
    let saved = CGEvent(source: nil)?.location
    CGWarpMouseCursorPosition(point)
    let source = CGEventSource(stateID: .combinedSessionState)
    for clickState in 1...clickCount {
        let down = CGEvent(mouseEventSource: source, mouseType: button.downType, mouseCursorPosition: point, mouseButton: button.cgButton)
        down?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        down?.post(tap: .cgSessionEventTap)
        let up = CGEvent(mouseEventSource: source, mouseType: button.upType, mouseCursorPosition: point, mouseButton: button.cgButton)
        up?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        up?.post(tap: .cgSessionEventTap)
    }
    if let saved { CGWarpMouseCursorPosition(saved) }
    return .globalCursor
}

/// Deliver scroll wheel events at a global point. Distributes the delta across
/// steps with error diffusion so the posted amounts sum exactly to the request
/// and a small axis is never truncated to zero.
func deliverScroll(at point: CGPoint, deltaX: Int, deltaY: Int, context: DeliveryContext) -> InputTier {
    let source = CGEventSource(stateID: .privateState)
    let stepCount = max(1, max(abs(deltaX), abs(deltaY)) / 40)
    var emittedX = 0
    var emittedY = 0
    func makeEvent(wheelX: Int, wheelY: Int, phase: CGScrollPhase) -> CGEvent? {
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                wheel1: Int32(wheelY), wheel2: Int32(wheelX), wheel3: 0
            )
        else { return nil }
        event.location = point
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(wheelY))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(wheelX))
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Int64(wheelY * 65_536))
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Int64(wheelX * 65_536))
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(CGMomentumScrollPhase.none.rawValue))
        event.setIntegerValueField(.scrollWheelEventScrollCount, value: 1)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        if let windowNumber = context.windowNumber {
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowNumber))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowNumber))
        }
        return event
    }
    for step in 1...stepCount {
        let targetX = Int((Double(deltaX) * Double(step) / Double(stepCount)).rounded())
        let targetY = Int((Double(deltaY) * Double(step) / Double(stepCount)).rounded())
        let stepX = targetX - emittedX
        let stepY = targetY - emittedY
        emittedX = targetX
        emittedY = targetY
        // Positive delta_y scrolls content up; wheel1 up is positive, so negate.
        let phase: CGScrollPhase = step == 1 ? .began : .changed
        makeEvent(wheelX: stepX, wheelY: -stepY, phase: phase)?.postToPid(context.pid)
    }
    makeEvent(wheelX: 0, wheelY: 0, phase: .ended)?.postToPid(context.pid)
    return .perPid
}

/// Deliver a drag gesture from one global point to another.
func deliverDrag(from: CGPoint, to: CGPoint, context: DeliveryContext) async -> InputTier {
    let source = CGEventSource(stateID: .privateState)
    var tier: InputTier = context.windowNumber != nil ? .perWindow : .perPid
    func post(_ type: CGEventType, _ p: CGPoint) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
        else { return }
        // Prefer window-affined delivery (Tier 2) when resolvable, like clicks.
        if let windowNumber = context.windowNumber, let frame = context.windowFrame,
            let bridged = bridgedWindowEvent(from: event, point: p, windowNumber: windowNumber, windowFrame: frame)
        {
            bridged.postToPid(context.pid)
            tier = .perWindow
        } else {
            event.postToPid(context.pid)
            tier = .perPid
        }
    }
    post(.leftMouseDown, from)
    // Abort guard: the button is held from here on, so every exit path must
    // release it. A drag that completes releases at the destination; one that
    // bails early (cancellation, a future throw) releases at the origin —
    // dropping where it began so a half-finished drag is a no-op instead of a
    // stuck mouse button.
    var released = false
    var aborted = true
    func release() {
        guard !released else { return }
        released = true
        post(.leftMouseUp, dragReleasePoint(from: from, to: to, aborted: aborted))
    }
    defer { release() }

    let steps = 24
    for i in 1...steps {
        if Task.isCancelled { return tier }  // aborted stays true → defer drops at origin
        let t = Double(i) / Double(steps)
        let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        post(.leftMouseDragged, p)
        try? await Task.sleep(for: .milliseconds(16))
    }
    aborted = false
    release()
    return tier
}

/// Where a drag releases its button: the destination on normal completion, or
/// the origin when aborting so the gesture drops where it began (a no-op)
/// rather than stranding a held button. Pure, unit-tested.
func dragReleasePoint(from: CGPoint, to: CGPoint, aborted: Bool) -> CGPoint {
    aborted ? from : to
}

/// Split text into Unicode-typing chunks: one grapheme cluster per chunk, each
/// as its UTF-16 code units. A cluster that is several units (an emoji, a
/// combining sequence) is delivered whole on a single key event so it is never
/// torn apart mid-scalar. Pure, so the chunking is unit-testable without
/// posting any events.
func unicodeTypingChunks(_ text: String) -> [[UniChar]] {
    text.map { Array(String($0).utf16) }
}

/// Type arbitrary text into the target pid via synthetic Unicode key events —
/// the background-safe fallback for type_text when the element is not
/// AX-value-settable (custom/web fields). Each grapheme cluster rides a
/// keyDown/keyUp pair whose Unicode string is overridden, posted to the pid
/// (Tier 3 discipline: never a global post, never the user's real cursor). Key
/// events land on whatever the app has focused, so the caller focuses the
/// target first. Returns the delivery tier used.
@discardableResult
func typeUnicodeText(_ text: String, context: DeliveryContext) throws -> InputTier {
    let source = CGEventSource(stateID: .privateState)
    var usedSkyLight = !text.isEmpty
    for chunk in unicodeTypingChunks(text) {
        if postSkyLightUnicodeKeyboard(chunk, pid: context.pid) {
            continue
        }
        usedSkyLight = false
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else {
            throw ToolError.failed("Could not synthesize a keyboard event for text entry.")
        }
        // Override the (meaningless) virtual key 0 with the cluster's actual
        // characters; set on both edges so apps that read on either land it.
        chunk.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        down.postToPid(context.pid)
        up.postToPid(context.pid)
    }
    return usedSkyLight ? .skyLight : .perPid
}

func keyDeliveryMode(context: DeliveryContext, targetAppIsActive: Bool) throws -> KeyDeliveryMode {
    guard context.allowGlobalCursor else {
        return .perPid
    }
    guard targetAppIsActive else {
        throw ToolError.failed(
            "Global keyboard delivery was requested, but the target app is not foreground. "
                + "Bring the target app to the foreground or retry without allow_global_cursor."
        )
    }
    return .globalSessionTap
}

/// Deliver a key chord to the target process.
@discardableResult
func deliverKey(_ chord: KeyChord, context: DeliveryContext, targetAppIsActive: Bool) throws -> KeyDeliveryMode {
    let mode = try keyDeliveryMode(context: context, targetAppIsActive: targetAppIsActive)
    let source = CGEventSource(stateID: .privateState)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: true),
        let up = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: false)
    else {
        throw ToolError.failed("Could not synthesize a key event.")
    }
    down.flags = chord.flags
    up.flags = chord.flags
    if mode == .globalSessionTap {
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    } else if postSkyLightKey(chord, pid: context.pid) {
        return .skyLight
    } else {
        down.postToPid(context.pid)
        up.postToPid(context.pid)
    }
    return mode
}
#endif
