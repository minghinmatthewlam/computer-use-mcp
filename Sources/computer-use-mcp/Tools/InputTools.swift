// press_key, scroll, drag — the synthetic-input tools.

import Foundation
import MCP
#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
#endif

func pressKeyImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    let confirmed = SafetyPolicy.confirmed(args)
    try SafetyPolicy.check(app: app, confirmed: confirmed)
    let allowGlobalKeyboard = try allowGlobalKeyboardArgument(args)
    let focus = FocusChangeTracker.start(focusChangeAllowed: allowGlobalKeyboard)
    let combo = try args.requireString("key")
    let chord = try Keymap.parse(combo)
    try SafetyPolicy.checkKey(
        combo: combo, chord: chord,
        focused: axElement(app.axApplication, kAXFocusedUIElementAttribute),
        app: app, confirmed: confirmed
    )

    let window = try? targetWindow(for: app, title: await SnapshotStore.shared.load(forPid: app.pid)?.windowTitle)
    let context = DeliveryContext(
        pid: app.pid,
        windowNumber: window.flatMap { windowID(for: $0.element) },
        windowFrame: window?.frame,
        allowGlobalCursor: allowGlobalKeyboard
    )
    let targetAppIsActive = NSRunningApplication(processIdentifier: app.pid)?.isActive == true
    let deliveryMode = try deliverKey(chord, context: context, targetAppIsActive: targetAppIsActive)
    try? await Task.sleep(for: .milliseconds(80))

    return try await stateResult(
        app: app, windowTitle: window?.title, note: "Pressed \(combo).",
        screenshot: screenshotDetail(args),
        focusTelemetry: focus.finish(deliveryTier: deliveryMode.rawValue)
    )
}

func scrollImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    try SafetyPolicy.check(app: app, confirmed: SafetyPolicy.confirmed(args))
    let focus = FocusChangeTracker.start()
    let target = try await resolvePointTarget(args, app: app)

    // Route the wheel to the real scroll container, not whatever leaf the point
    // landed on: walk the AX ancestor chain and rank candidates for
    // scrollability. The container's own viewport (not a ~20px row) then also
    // sizes a semantic direction+pages scroll correctly.
    let ranked = target.element.map { rankedScrollContainers(from: $0) } ?? []

    let direction = args.string("direction")
    var deltaX = args.integer("delta_x") ?? 0
    var deltaY = args.integer("delta_y") ?? 0
    if let direction {
        let pages = try ArgumentBounds.checkScrollPages(args.number("pages") ?? 1)
        // Size a page from the top-ranked container's *visible* viewport (not a
        // ~20px leaf row, nor a web area's full content height); fall back to the
        // hit element, then a default page height.
        let viewport = (ranked.first ?? target.element)
            .flatMap { visibleViewport(of: $0, windowFrame: target.deliveryContext.windowFrame) }
        func pageDelta(_ size: CGFloat) throws -> Int {
            let raw = Double(size) * pages
            guard raw.isFinite, abs(raw) <= Double(ArgumentBounds.maxScrollDelta), let delta = safeInt(raw) else {
                throw ToolError.invalidArguments(
                    "The requested scroll distance is outside the supported delta range."
                )
            }
            return delta
        }
        switch direction {
        case "down": deltaY = try pageDelta(viewport?.height ?? 400)
        case "up": deltaY = -(try pageDelta(viewport?.height ?? 400))
        case "right": deltaX = try pageDelta(viewport?.width ?? 400)
        case "left": deltaX = -(try pageDelta(viewport?.width ?? 400))
        default:
            throw ToolError.invalidArguments("direction must be up, down, left, or right.")
        }
    }
    guard deltaX != 0 || deltaY != 0 else {
        throw ToolError.invalidArguments("Provide direction (+ optional pages), or a non-zero delta_x/delta_y.")
    }
    try ArgumentBounds.checkScrollDelta(deltaX: deltaX, deltaY: deltaY)

    // Pick the container to drive. Post the wheel at the hit point itself — it
    // already lies inside every ancestor we walked up through, so it is over the
    // chosen container; relocating to a container centre can land the event on a
    // sibling region (an outer scroll area's centre sits over other content).
    // Only synthesize a point from the container when the target exposes none.
    let container = chooseScrollContainer(ranked, deltaX: deltaX, deltaY: deltaY)
    var fallbackReasons: [FallbackReason] = []
    let point: CGPoint
    if let hit = target.point {
        point = hit
    } else if let container, let frame = axFrame(container) {
        point = CGPoint(x: frame.midX, y: frame.midY)
    } else {
        if container == nil { fallbackReasons.append(.noScrollContainerFound) }
        point = try target.requirePoint()
    }

    // Evidence read off the chosen container's own scroll bars: whether it is
    // already pinned in the scroll direction (so "no movement" is expected), and
    // a before/after position signature that confirms the content actually moved.
    var before = ActionVerification()
    before.scrollAtExtent = container.flatMap { scrollAtExtent(container: $0, deltaX: deltaX, deltaY: deltaY) }
    if let container {
        before.notes.append(
            "Routed the scroll to a \(axRole(container)) container "
                + "(\(ranked.count) scrollable candidate\(ranked.count == 1 ? "" : "s") on the ancestor chain).")
    }
    let beforeOffset = container.flatMap(scrollOffsetSignature)
    let beforeMovement = scrollMovementFingerprint(container: container, target: target.element)

    await AgentCursor.shared.glide(to: point, targetWindow: target.deliveryContext.windowNumber)

    // Tier 1: drive the scroll through accessibility, which lands in the
    // background where a SwiftUI List / WKWebView swallow a synthetic wheel. Two
    // AX strategies for a semantic direction, each verified via the movement
    // fingerprint; on no observed movement, fall through to the next, then to
    // the wheel — the same chain philosophy as the click tier 1.
    if let direction {
        let pageCount = max(1, Int((args.number("pages") ?? 1).rounded()))
        func tier1Success(via: String, positionChanged: Bool = false, contentChanged: Bool = true) async throws -> CallTool.Result {
            if positionChanged { before.scrollPositionChanged = true }
            if contentChanged { before.scrollContentChanged = true }
            before.notes.append("Scrolled via \(via) (tier 1).")
            let verifier = ActionVerifier(
                family: .scroll, intent: .scrollContent,
                deliveryTier: InputTier.accessibilityAction.rawValue,
                dispatchSucceeded: true, hasTargetElement: false, snapshotElement: nil,
                before: before, beforeWindowTitle: target.snapshot.windowTitle)
            return try await stateResult(
                app: app, windowTitle: target.snapshot.windowTitle,
                note: "Scrolled \(direction)\(pageCount > 1 ? " \(pageCount) pages" : "") at \(target.description).",
                screenshot: screenshotDetail(args),
                focusTelemetry: focus.finish(
                    deliveryTier: InputTier.accessibilityAction.rawValue, fallbackReasons: fallbackReasons),
                verifier: verifier)
        }

        // Strategy 1: set the container's scroll-bar value. NSScrollView-backed
        // lists (AppKit tables, the fixture row-list) do NOT honor
        // AXScrollDownByPage via perform (it returns attributeUnsupported), but
        // their AXScrollBar value is settable and moves the content in the
        // background — the most reliable native path. The bar lives on the
        // AXScrollArea, so use the nearest ranked container that exposes it.
        // Verified against the target element (not the bar we just set, which
        // would be circular).
        let vertical = direction == "down" || direction == "up"
        let barAttribute = vertical ? "AXVerticalScrollBar" : "AXHorizontalScrollBar"
        if let barContainer = ranked.first(where: { axElement($0, barAttribute) != nil }),
            let bar = axElement(barContainer, barAttribute),
            let current = (axAttribute(bar, kAXValueAttribute) as? NSNumber)?.doubleValue
        {
            let forward = direction == "down" || direction == "right"
            let proportion = scrollBarPageProportion(bar, vertical: vertical) ?? 0.9
            let newValue = scrolledBarValue(
                current: current, pageProportion: proportion, pages: args.number("pages") ?? 1, forward: forward)
            if abs(newValue - current) > 1e-6 {
                let ok =
                    AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: newValue))
                    == .success
                try? await Task.sleep(for: .milliseconds(80))
                // The scroll took iff the bar now holds a different position: a
                // container that honors the set moves and keeps the new value; one
                // that ignores it leaves the old value in place. This reads the
                // bar itself (not the target), so it works even when the caller
                // scrolled via the container's own id, whose frame never moves.
                let after = (axAttribute(bar, kAXValueAttribute) as? NSNumber)?.doubleValue ?? current
                if ok, abs(after - current) > 1e-4 {
                    return try await tier1Success(
                        via: "setting the container's scroll-bar position",
                        positionChanged: true, contentChanged: false)
                }
                if !fallbackReasons.contains(.scrollActionUnverified) {
                    fallbackReasons.append(.scrollActionUnverified)
                }
            }
        }

        // Strategy 2: the container's own page-scroll action (some AppKit /
        // custom scroll areas honor it, though NSScrollView reports it
        // unsupported on perform). The action lives on the AXScrollArea, which
        // may be an ancestor of the innermost qualifier, so use the nearest
        // ranked container that advertises it.
        if let action = scrollPageAction(for: direction),
            let actionContainer = ranked.first(where: { axActionNames($0).contains(action) })
        {
            let fingerprint = scrollMovementFingerprint(container: actionContainer, target: target.element)
            var performed = true
            for _ in 0..<pageCount where performed {
                performed = AXUIElementPerformAction(actionContainer, action as CFString) == .success
            }
            try? await Task.sleep(for: .milliseconds(80))
            let moved = scrollMovementChanged(
                before: fingerprint,
                after: scrollMovementFingerprint(container: actionContainer, target: target.element)) == true
            if performed, moved {
                return try await tier1Success(via: "the container's \(action) action")
            }
            fallbackReasons.append(.scrollActionUnverified)
        }

        // Strategy 3: reveal an off-screen descendant. Web areas expose no
        // settable scroll bar or page action, but their content supports
        // AXScrollToVisible, and scrolling a descendant that sits ~pages
        // viewports away into view advances the content by that much.
        if let container,
            let reveal = descendantToRevealForScroll(
                container: container, direction: direction, pages: args.number("pages") ?? 1,
                windowFrame: target.deliveryContext.windowFrame)
        {
            let fingerprint = scrollMovementFingerprint(container: container, target: target.element)
            let performed = AXUIElementPerformAction(reveal, "AXScrollToVisible" as CFString) == .success
            try? await Task.sleep(for: .milliseconds(80))
            let moved = scrollMovementChanged(
                before: fingerprint,
                after: scrollMovementFingerprint(container: container, target: target.element)) == true
            if performed, moved {
                return try await tier1Success(via: "revealing an off-screen element (AXScrollToVisible)")
            }
            if !fallbackReasons.contains(.scrollActionUnverified) {
                fallbackReasons.append(.scrollActionUnverified)
            }
        }
    }

    // Tier 2: synthetic wheel at the hit point.
    let tier = deliverScroll(at: point, deltaX: deltaX, deltaY: deltaY, context: target.deliveryContext)
    try? await Task.sleep(for: .milliseconds(80))

    if let container, let beforeOffset, let afterOffset = scrollOffsetSignature(container) {
        before.scrollPositionChanged = beforeOffset != afterOffset
    }
    if let moved = scrollMovementChanged(
        before: beforeMovement,
        after: scrollMovementFingerprint(container: container, target: target.element))
    {
        before.scrollContentChanged = moved
    }

    let verifier = ActionVerifier(
        family: .scroll, intent: .scrollContent, deliveryTier: tier.rawValue,
        dispatchSucceeded: true, hasTargetElement: false, snapshotElement: nil,
        before: before, beforeWindowTitle: target.snapshot.windowTitle)
    return try await stateResult(
        app: app, windowTitle: target.snapshot.windowTitle,
        note: "Scrolled (\(deltaX),\(deltaY)) at \(target.description).",
        screenshot: screenshotDetail(args),
        focusTelemetry: focus.finish(deliveryTier: tier.rawValue, fallbackReasons: fallbackReasons),
        verifier: verifier
    )
}

func dragImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    try SafetyPolicy.check(app: app, confirmed: SafetyPolicy.confirmed(args))
    let focus = FocusChangeTracker.start()
    guard let snapshot = await SnapshotStore.shared.load(forPid: app.pid) else {
        throw ToolError.failed("Call get_app_state for \(app.name) before dragging.")
    }
    let from = try screenPoint(x: try args.requireNumber("from_x"), y: try args.requireNumber("from_y"), snapshot: snapshot)
    let to = try screenPoint(x: try args.requireNumber("to_x"), y: try args.requireNumber("to_y"), snapshot: snapshot)

    // Gate a drop onto a destructive target (e.g. the Trash) like a click.
    let confirmed = SafetyPolicy.confirmed(args)
    if let destination = accessibilityElement(at: to, pid: app.pid) {
        try SafetyPolicy.checkClick(label: clickableLabel(destination), app: app, confirmed: confirmed)
    }

    let window = try? targetWindow(for: app, title: snapshot.windowTitle)
    let context = DeliveryContext(
        pid: app.pid,
        windowNumber: window.flatMap { windowID(for: $0.element) },
        windowFrame: window?.frame,
        allowGlobalCursor: false
    )
    await AgentCursor.shared.glide(to: from, targetWindow: context.windowNumber)
    let tier = await deliverDrag(from: from, to: to, context: context)
    await AgentCursor.shared.pulse(at: to, targetWindow: context.windowNumber)
    try? await Task.sleep(for: .milliseconds(80))

    // Drag is a coordinate gesture with no re-readable target: success on a
    // whole-window change, verifier_ambiguous otherwise (a drag with no visible
    // effect could be a legitimate no-op).
    let verifier = ActionVerifier(
        family: .drag, intent: .activate, deliveryTier: tier.rawValue,
        dispatchSucceeded: true, hasTargetElement: false, snapshotElement: nil,
        beforeWindowTitle: snapshot.windowTitle)
    return try await stateResult(
        app: app, windowTitle: snapshot.windowTitle,
        note: "Dragged from (\(roundedIntegerDescription(from.x)),\(roundedIntegerDescription(from.y))) "
            + "to (\(roundedIntegerDescription(to.x)),\(roundedIntegerDescription(to.y))).",
        screenshot: screenshotDetail(args),
        focusTelemetry: focus.finish(deliveryTier: tier.rawValue),
        verifier: verifier
    )
}
