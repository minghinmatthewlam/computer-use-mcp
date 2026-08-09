// click — by element id (preferred) or screenshot coordinates (fallback).
// Tier 1 uses the accessibility press/menu action when available (precise,
// background, no event posted); otherwise it descends the synthetic input
// ladder (per-window NSEvent → per-pid CGEvent → guarded global cursor).

import ApplicationServices
import Foundation
import MCP

func clickImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    let clickCount = try clickCountArgument(args)
    try requireAccessibilityTrusted()
    let buttonName = args.string("mouse_button") ?? "left"
    let confirmed = SafetyPolicy.confirmed(args)
    try SafetyPolicy.check(app: app, confirmed: confirmed)
    let allowGlobalCursor = try allowGlobalCursorArgument(args)
    let focus = FocusChangeTracker.start(
        focusChangeAllowed: allowGlobalCursor,
        cursorMovementAllowed: allowGlobalCursor
    )
    let target = try await resolvePointTarget(args, app: app, allowGlobalCursor: allowGlobalCursor)
    try SafetyPolicy.checkClick(label: clickTargetLabel(target), app: app, confirmed: confirmed)

    // Capture target-local state before deriving intent so a single checkbox
    // click can declare and verify the exact state transition it should cause.
    let before = ActionVerifier.captureBefore(
        target.element, family: .click, snapshotElement: target.snapshotElement)
    let intent = clickIntent(
        role: target.snapshotElement?.role,
        button: buttonName,
        clickCount: clickCount,
        beforeSelected: before.beforeSelected)

    // Read-act-read, pre-dispatch: a disabled control cannot perform the action.
    // Classify it `unsupported` and do not press a dead control — distinct from
    // a verified failure (retrying won't help), and not a raw throw.
    if let element = target.element, target.snapshotElement != nil,
        axBool(element, kAXEnabledAttribute) == false
    {
        let verifier = ActionVerifier(
            family: .click, intent: intent, deliveryTier: InputTier.accessibilityAction.rawValue,
            dispatchSucceeded: false, hasTargetElement: true, snapshotElement: target.snapshotElement,
            before: before,
            resolved: .unsupported(.unsupported, "\(target.description) is disabled and cannot be clicked."))
        return try await stateResult(
            app: app, windowTitle: target.snapshot.windowTitle,
            windowID: target.deliveryContext.windowNumber,
            note: "\(target.description) is disabled; no click was performed.",
            screenshot: screenshotDetail(args),
            focusTelemetry: focus.finish(deliveryTier: InputTier.accessibilityAction.rawValue),
            verifier: verifier)
    }

    let outcome: InputActionOutcome
    switch buttonName {
    case "left":
        outcome = try await leftClick(target, clickCount: clickCount, intent: intent, before: before)
    case "right":
        outcome = try rightClick(target)
    case "middle":
        let delivery = try deliverClick(at: target.requirePoint(), button: .middle, clickCount: clickCount, context: target.deliveryContext)
        outcome = InputActionOutcome(
            note: "Middle-clicked \(target.description) [\(delivery.tier.rawValue)].",
            deliveryTier: delivery.tier, fallbackReasons: delivery.fallbackReasons
        )
    default:
        throw ToolError.invalidArguments("mouse_button \"\(buttonName)\" is not supported.")
    }

    // The click landed: ripple the overlay at the point so the user sees it.
    if let point = target.point {
        await AgentCursor.shared.pulse(at: point, targetWindow: target.deliveryContext.windowNumber)
    }

    let verifier = ActionVerifier(
        family: .click, intent: intent, deliveryTier: outcome.deliveryTier.rawValue,
        dispatchSucceeded: true, hasTargetElement: target.snapshotElement != nil,
        snapshotElement: target.snapshotElement, before: before,
        beforeWindowTitle: target.snapshot.windowTitle)

    return try await stateResult(
        app: app, windowTitle: target.snapshot.windowTitle,
        windowID: target.deliveryContext.windowNumber, note: outcome.note,
        screenshot: screenshotDetail(args),
        focusTelemetry: focus.finish(
            deliveryTier: outcome.deliveryTier.rawValue, fallbackReasons: outcome.fallbackReasons,
            landedRung: outcome.landedRung),
        verifier: verifier
    )
}

/// The intended effect of a click, for the outcome verifier. A single left click
/// focuses text fields and toggles checkboxes with known state. Other clicks are
/// generic activations whose effect is an observed change.
func clickIntent(
    role: String?, button: String, clickCount: Int, beforeSelected: Bool?
) -> ActionIntent {
    guard button == "left", clickCount == 1 else { return .activate }
    if let role, isTextEntryRole(role) { return .focusTarget }
    if role == "AXCheckBox", let beforeSelected {
        return .toggle(!beforeSelected)
    }
    return .activate
}

func clickCountArgument(_ args: [String: Value]) throws -> Int {
    if args["click_count"] != nil {
        guard let rawClickCount = args.integer("click_count") else {
            throw ToolError.invalidArguments("\"click_count\" must be an integer.")
        }
        return try ArgumentBounds.checkClickCount(rawClickCount)
    }
    return 1
}

/// Best-effort label for the click target, for the safety check.
private func clickTargetLabel(_ target: PointTarget) -> String? {
    target.element.flatMap(clickableLabel)
}

private struct InputActionOutcome {
    let note: String
    let deliveryTier: InputTier
    let fallbackReasons: [FallbackReason]
    /// The AX chain rung whose verified effect landed the click (tier 1 only).
    let landedRung: String?

    init(
        note: String, deliveryTier: InputTier, fallbackReasons: [FallbackReason] = [], landedRung: String? = nil
    ) {
        self.note = note
        self.deliveryTier = deliveryTier
        self.fallbackReasons = fallbackReasons
        self.landedRung = landedRung
    }
}

private func leftClick(
    _ target: PointTarget, clickCount: Int, intent: ActionIntent, before: ActionVerification
) async throws -> InputActionOutcome {
    // Animate the (cosmetic) agent cursor to the target before acting.
    if let point = target.point {
        await AgentCursor.shared.glide(to: point, targetWindow: target.deliveryContext.windowNumber)
    }

    // Tier 1: the multi-strategy AX chain, for a single click on a resolved
    // element. Each rung is verified by read-act-read; the first whose effect
    // is observed wins. A rung that fires without a confirming change falls
    // through. (Double-clicks keep the legacy single-rung press below — verified
    // once by the outcome contract, not per-press.)
    if let element = target.element, clickCount == 1 {
        let window = axElement(element, kAXWindowAttribute)
        let beforeSignature = window.map(chainWindowSignature)
        let result = try await runClickChain(
            target: element, window: window, intent: intent, before: before,
            beforeWindowSignature: beforeSignature,
            settle: { try? await Task.sleep(for: .milliseconds(80)) })
        if let landed = result.landedRungID {
            return InputActionOutcome(
                note: "Pressed \(target.description) via accessibility chain [\(landed)].",
                deliveryTier: .accessibilityAction,
                fallbackReasons: firedUnverifiedReasons(result),
                landedRung: landed)
        }

        // The whole AX chain was exhausted without an observed effect. Fall
        // through to synthetic injection (unchanged ladder) when a point exists,
        // carrying the tried rungs so the agent sees the AX strategies failed.
        // The outcome verifier makes the final call (effect_not_verified here).
        let firedReasons = firedUnverifiedReasons(result)
        if target.point != nil {
            let delivery = try deliverClick(
                at: try target.requirePoint(), button: .left, clickCount: 1, context: target.deliveryContext)
            return InputActionOutcome(
                note: "Clicked \(target.description) [\(delivery.tier.rawValue)].",
                deliveryTier: delivery.tier,
                fallbackReasons: firedReasons + [.axActionUnsupported] + delivery.fallbackReasons)
        }
        // No point to inject at: the AX action was performed (if any rung fired),
        // just not confirmed — report it as a best-effort AX delivery rather than
        // failing; the verifier will classify it.
        return InputActionOutcome(
            note: "Performed an accessibility action on \(target.description); effect unconfirmed.",
            deliveryTier: .accessibilityAction, fallbackReasons: firedReasons)
    }

    // Legacy tier 1: a single AXPress (self-or-ancestor), for double-clicks.
    if let element = target.element,
        let pressable = selfOrAncestor(of: element, supporting: kAXPressAction as String)
    {
        try await performRepeatedAXPress(
            count: clickCount,
            primitive: { AXUIElementPerformAction(pressable, kAXPressAction as CFString) },
            betweenPresses: { try? await Task.sleep(for: .milliseconds(80)) },
            failureMessage: "AXPress failed on \(target.description)")
        let verb = clickCount > 1 ? "Double-pressed" : "Pressed"
        return InputActionOutcome(
            note: "\(verb) \(target.description) via accessibility [tier1-ax-action].",
            deliveryTier: .accessibilityAction
        )
    }

    // Tiers 2–4: synthetic click at the point. Tier 1 was unavailable (no
    // pressable element), which is the first reason delivery fell through.
    let delivery = try deliverClick(at: target.requirePoint(), button: .left, clickCount: clickCount, context: target.deliveryContext)
    let verb = clickCount > 1 ? "Double-clicked" : "Clicked"
    return InputActionOutcome(
        note: "\(verb) \(target.description) [\(delivery.tier.rawValue)].",
        deliveryTier: delivery.tier,
        fallbackReasons: [.axActionUnsupported] + delivery.fallbackReasons
    )
}

func performRepeatedAXPress(
    count: Int,
    primitive: () -> AXError,
    betweenPresses: () async -> Void,
    failureMessage: String
) async throws {
    try checkCancellationBeforeDelivery()
    for index in 0..<count {
        let error = primitive()
        guard error == .success else {
            throw ToolError.failed("\(failureMessage) (\(axErrorDescription(error))).")
        }
        guard index + 1 < count else { continue }
        await betweenPresses()
        // Delivery already began. Cancellation now is intentionally generic,
        // so Dispatch records unknown rather than a false safe-retry abort.
        if Task.isCancelled { throw CancellationError() }
    }
}

private func rightClick(_ target: PointTarget) throws -> InputActionOutcome {
    // Tier 1: accessibility context-menu action.
    if let element = target.element,
        let menu = selfOrAncestor(of: element, supporting: "AXShowMenu")
    {
        try checkCancellationBeforeDelivery()
        let error = AXUIElementPerformAction(menu, "AXShowMenu" as CFString)
        guard error == .success else {
            throw ToolError.failed("AXShowMenu failed on \(target.description) (\(axErrorDescription(error))).")
        }
        return InputActionOutcome(
            note: "Opened context menu on \(target.description) via accessibility [tier1-ax-action].",
            deliveryTier: .accessibilityAction
        )
    }
    let delivery = try deliverClick(at: target.requirePoint(), button: .right, clickCount: 1, context: target.deliveryContext)
    return InputActionOutcome(
        note: "Right-clicked \(target.description) [\(delivery.tier.rawValue)].",
        deliveryTier: delivery.tier,
        fallbackReasons: [.axActionUnsupported] + delivery.fallbackReasons
    )
}
