// Multi-strategy AX action chains.
//
// Tier 1 of a click used to be a single AXPress: perform it, trust the
// `.success` return. That trusts the app's word — the same false-success trap
// the outcome contract exists to catch. Instead we run a declarative *chain* of
// AX strategies (press, confirm, open, pick, selection-relay, a child's action,
// an ancestor's action) and verify each rung's effect with the same read-act-read
// the outcome verifier uses. A rung that fires without an observed effect falls
// through to the next; only a rung whose effect is observed "lands." When the
// whole AX chain is exhausted, delivery falls through to the tier-2 synthetic
// ladder, unchanged.
//
// The chain is a data table (`clickChain`) so secondary_action / set_value
// chains can be added later without new plumbing. Inspired by
// lahfir/agent-desktop's chain_defs.rs, adapted to our verifier.

import Foundation
#if os(macOS)
import ApplicationServices
import CoreGraphics
#endif

// MARK: - Chain definition (data-driven)

/// Where, relative to the clicked element, a rung looks for something to act on.
enum ChainScope: Sendable {
    /// The target element itself, if it supports the action.
    case selfElement
    /// The nearest ancestor (excluding self) that supports the action.
    case ancestor
    /// The nearest descendant that supports the action.
    case child
}

/// What a rung does to the element it resolves.
enum ChainAction: Sendable, Equatable {
    /// Perform a named AX action (AXPress, AXConfirm, AXOpen, AXPick).
    case axAction(String)
    /// Set AXSelected = true, for role-appropriate selectable elements (rows,
    /// cells, options) whose "click" semantics are selection, not a press.
    case selectionRelay
}

/// One rung of a chain.
struct ChainRung: Sendable {
    /// Stable id, surfaced in delivery telemetry (the landed rung) and, when the
    /// rung fired without a verified effect, in fallback_reasons.
    let id: String
    let scope: ChainScope
    let action: ChainAction
    /// The fallback_reasons vocabulary entry when this rung fires unverified.
    let unverifiedReason: FallbackReason
}

/// The click chain, in priority order (docs task #5). Every rung is verified;
/// the first whose effect is observed wins.
let clickChain: [ChainRung] = [
    ChainRung(id: "ax-press", scope: .selfElement, action: .axAction(kAXPressAction as String),
        unverifiedReason: .chainAXPressUnverified),
    ChainRung(id: "ax-confirm", scope: .selfElement, action: .axAction("AXConfirm"),
        unverifiedReason: .chainAXConfirmUnverified),
    ChainRung(id: "ax-open", scope: .selfElement, action: .axAction("AXOpen"),
        unverifiedReason: .chainAXOpenUnverified),
    ChainRung(id: "ax-pick", scope: .selfElement, action: .axAction("AXPick"),
        unverifiedReason: .chainAXPickUnverified),
    ChainRung(id: "selection-relay", scope: .selfElement, action: .selectionRelay,
        unverifiedReason: .chainSelectionRelayUnverified),
    ChainRung(id: "child-press", scope: .child, action: .axAction(kAXPressAction as String),
        unverifiedReason: .chainChildActionUnverified),
    ChainRung(id: "ancestor-press", scope: .ancestor, action: .axAction(kAXPressAction as String),
        unverifiedReason: .chainAncestorActionUnverified),
]

// MARK: - Pure fall-through state machine (unit-tested)

/// One rung's result: it did not apply, it fired but no effect was observed, or
/// it fired and the effect landed.
enum RungAttempt: Sendable, Equatable {
    case skipped
    case firedUnverified
    case landed
}

/// The outcome of running a chain: which rung landed (nil ⇒ none), and the ids
/// of rungs that fired without a verified effect (they become fallback reasons).
struct ChainResult: Sendable, Equatable {
    let landedRungID: String?
    let firedUnverifiedRungIDs: [String]
    var landed: Bool { landedRungID != nil }
}

/// The pure fall-through: try each rung in order; the first that lands wins,
/// unapplicable rungs are skipped, fired-unverified rungs are recorded. Async
/// so the live attempt can await AX reads; deterministic and unit-testable with
/// a synchronous closure.
func runActionChain(
    _ rungs: [ChainRung], attempt: (ChainRung) async -> RungAttempt
) async -> ChainResult {
    var firedUnverified: [String] = []
    for rung in rungs {
        switch await attempt(rung) {
        case .skipped:
            continue
        case .firedUnverified:
            firedUnverified.append(rung.id)
        case .landed:
            return ChainResult(landedRungID: rung.id, firedUnverifiedRungIDs: firedUnverified)
        }
    }
    return ChainResult(landedRungID: nil, firedUnverifiedRungIDs: firedUnverified)
}

/// The fallback_reasons for the rungs that fired without landing, in order.
func firedUnverifiedReasons(_ result: ChainResult, in rungs: [ChainRung] = clickChain) -> [FallbackReason] {
    result.firedUnverifiedRungIDs.compactMap { id in
        rungs.first { $0.id == id }?.unverifiedReason
    }
}

// MARK: - Live element resolution and action

/// The element a rung acts on, or nil when the rung does not apply here.
func resolveRungElement(_ rung: ChainRung, target: AXUIElement) -> AXUIElement? {
    switch rung.scope {
    case .selfElement:
        return rungActionSupported(rung.action, by: target) ? target : nil
    case .ancestor:
        guard var current = axElement(target, kAXParentAttribute) else { return nil }
        for _ in 0..<5 {
            if rungActionSupported(rung.action, by: current) { return current }
            guard let parent = axElement(current, kAXParentAttribute) else { return nil }
            current = parent
        }
        return nil
    case .child:
        return firstDescendant(of: target, supporting: rung.action, maxNodes: 40)
    }
}

private func rungActionSupported(_ action: ChainAction, by element: AXUIElement) -> Bool {
    switch action {
    case .axAction(let name):
        return axActionNames(element).contains(name)
    case .selectionRelay:
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, "AXSelected" as CFString, &settable) == .success
            && settable.boolValue
    }
}

/// Perform a rung's action; true when the AX call reported success (which the
/// verifier then confirms — or refutes).
func performRungAction(_ action: ChainAction, on element: AXUIElement) -> Bool {
    switch action {
    case .axAction(let name):
        return AXUIElementPerformAction(element, name as CFString) == .success
    case .selectionRelay:
        return AXUIElementSetAttributeValue(element, "AXSelected" as CFString, kCFBooleanTrue) == .success
    }
}

/// Breadth-first nearest descendant supporting the action, bounded so a deep
/// tree cannot make one click walk the whole window.
private func firstDescendant(
    of root: AXUIElement, supporting action: ChainAction, maxNodes: Int
) -> AXUIElement? {
    var queue = axElements(root, kAXChildrenAttribute)
    var index = 0
    var visited = 0
    while index < queue.count && visited < maxNodes {
        let element = queue[index]
        index += 1
        visited += 1
        if rungActionSupported(action, by: element) { return element }
        queue.append(contentsOf: axElements(element, kAXChildrenAttribute))
    }
    return nil
}

// MARK: - Per-rung effect verification

/// A whole-window fingerprint used to detect a rung's effect on elements other
/// than the target itself (a button whose press changes a sibling readout).
/// Reuses the tree builder + the id-normalized fingerprint; coordinates are
/// irrelevant here, so origin/scale are fixed.
func chainWindowSignature(_ window: AXUIElement) -> String {
    treeFingerprint(buildTree(window: window, windowOrigin: .zero, pixelsPerPoint: 1, generation: "s0").text)
}

/// Did the rung's effect land? Mirrors the click-success predicate of the
/// outcome reducer: a focus-intent click lands when the target is focused; any
/// click lands when a target-local field changed or the window changed.
func clickEffectObserved(
    before: ActionVerification, after: ActionVerification, windowChanged: Bool, intent: ActionIntent
) -> Bool {
    if intent == .focusTarget, after.afterFocused == true { return true }
    if after.targetStateChanged == true { return true }
    return windowChanged
}

/// Run the click chain live against a target: for each rung, resolve + perform +
/// verify by read-act-read. Target-local fields are read first (cheap); the
/// whole-window fingerprint is only rebuilt when the target itself shows no
/// change (the button case), so a checkbox toggle pays no tree walk.
func runClickChain(
    target: AXUIElement,
    window: AXUIElement?,
    intent: ActionIntent,
    before: ActionVerification,
    beforeWindowSignature: String?,
    settle: @Sendable () async -> Void
) async -> ChainResult {
    await runActionChain(clickChain) { rung in
        guard let element = resolveRungElement(rung, target: target) else { return .skipped }
        guard performRungAction(rung.action, on: element) else { return .skipped }
        await settle()

        var after = before
        after.captureAfter(target, family: .click)
        // Cheap target-local signals first (no window rebuild).
        if clickEffectObserved(before: before, after: after, windowChanged: false, intent: intent) {
            return .landed
        }
        // Target itself inert: consult the whole-window fingerprint.
        guard let window, let beforeWindowSignature else { return .firedUnverified }
        let windowChanged = beforeWindowSignature != chainWindowSignature(window)
        return clickEffectObserved(before: before, after: after, windowChanged: windowChanged, intent: intent)
            ? .landed : .firedUnverified
    }
}
