// Verifier-first outcome contract: move mutating tools from "success = the AX
// call didn't throw" to "success = the action's effect was observed." Every
// mutating tool captures the acted-on element's fields before dispatch, then
// re-reads them (and the whole-window change bit) after, diffs the fields that
// matter for the action family, and reduces to a four-value classification plus
// a failure domain. The verdict rides in its own `computer-use-mcp/outcome`
// _meta block; isError is unchanged (a verified no-effect is not a throw).
//
// See docs/outcome-contract.md for the design and the per-tool trap matrix.

import Foundation
import MCP
#if os(macOS)
import ApplicationServices
#endif

let actionOutcomeMetaKey = "computer-use-mcp/outcome"

// MARK: - Classification and failure domain

/// The verifier's verdict on whether an action's intended effect occurred.
/// Serialized as the snake_case rawValue.
enum ActionClassification: String, Sendable {
    /// The effect was observed, or the target was already in the requested
    /// state (idempotent no-op is a success, not a failure).
    case success

    /// The target cannot perform this action at all (disabled control, no
    /// settable value, unsupported AX action). Retrying won't help.
    case unsupported

    /// The action dispatched without error but no confirming effect was
    /// observed — the case today's contract silently reports as success.
    case effectNotVerified = "effect_not_verified"

    /// The action dispatched, but the verifier could not read enough state to
    /// judge. Never a hard error — the action may well have worked.
    case verifierAmbiguous = "verifier_ambiguous"
}

/// Why an action did not reach `success`. nil when classification == .success.
enum FailureDomain: String, Sendable {
    /// The target could not be resolved to a live, matching element (stale id,
    /// relocated element). Pairs with verifier_ambiguous.
    case targeting

    /// The control cannot perform the action (disabled, no settable value).
    /// Pairs with unsupported.
    case unsupported

    /// The requested value could not be represented for this element
    /// (non-numeric string into a numeric field). Pairs with unsupported.
    case coercion

    /// The synthetic event was posted but likely dropped; the delivery tier is
    /// one an app can silently swallow. Pairs with effect_not_verified.
    case transport

    /// Dispatch reported success but the reread showed no confirming change.
    /// Pairs with effect_not_verified.
    case verification

    /// The target is inside web content, where AX can echo a value write back
    /// without proving the renderer/DOM observed it.
    case web

    /// The app accepted the action but applied app-specific semantics that
    /// diverge from the request (clamped a window frame, snapped a slider).
    /// Pairs with success or effect_not_verified.
    case appSpecificSemantics = "app_specific_semantics"
}

// MARK: - Field-level evidence

/// Before/after evidence for one action. All-optional so one type covers
/// click/type/set_value/scroll/window/menu. `nil` means "not captured for this
/// action family," never "false" — a three-valued bool distinguishes "did not
/// change" (false) from "not observed" (nil).
struct ActionVerification: Sendable {
    // Target identity across the action.
    var targetRelocated: Bool? = nil
    var refreshedTargetStrategy: String? = nil

    // Target-local field snapshots (populated when we hold the acted-on element).
    var beforeValuePreview: String? = nil
    var afterValuePreview: String? = nil
    var beforeSelected: Bool? = nil
    var afterSelected: Bool? = nil
    var beforeFocused: Bool? = nil
    var afterFocused: Bool? = nil

    // Whole-window observations (available even for coordinate clicks).
    var renderedTextChanged: Bool? = nil
    var focusedElementChanged: Bool? = nil
    var windowTitleChanged: Bool? = nil
    var windowFrameChanged: Bool? = nil
    var scrollPositionChanged: Bool? = nil
    /// Scroll only: visible rows/children, element positions, or edge content
    /// changed in the scroll container after delivery.
    var scrollContentChanged: Bool? = nil
    /// Scroll only: the container was already pinned at the boundary in the
    /// requested direction, so "no movement" is expected, not a dropped event.
    var scrollAtExtent: Bool? = nil
    /// The acted-on element is inside an AXWebArea, where AXValue readback can
    /// be an accessibility echo rather than renderer/DOM evidence.
    var targetInWebArea: Bool? = nil
    /// A post-state diff line changed somewhere other than the acted target.
    /// For web text writes this diagnostic bit is only true when that line
    /// includes the requested text.
    var independentElementChanged: Bool? = nil

    // Derived: any target-local field moved.
    var targetStateChanged: Bool? = nil

    /// Human-readable trail. Never load-bearing for the classification.
    var notes: [String] = []

    /// True when any whole-window signal shows a change.
    var windowChanged: Bool {
        renderedTextChanged == true || windowTitleChanged == true
            || focusedElementChanged == true || windowFrameChanged == true
            || scrollPositionChanged == true
    }

    var value: Value {
        var fields: [String: Value] = [:]
        func put(_ key: String, _ flag: Bool?) {
            if let flag { fields[key] = .bool(flag) }
        }
        func putString(_ key: String, _ text: String?) {
            if let text { fields[key] = .string(text) }
        }
        put("target_relocated", targetRelocated)
        putString("refreshed_target_strategy", refreshedTargetStrategy)
        putString("before_value_preview", beforeValuePreview)
        putString("after_value_preview", afterValuePreview)
        put("before_selected", beforeSelected)
        put("after_selected", afterSelected)
        put("before_focused", beforeFocused)
        put("after_focused", afterFocused)
        put("rendered_text_changed", renderedTextChanged)
        put("focused_element_changed", focusedElementChanged)
        put("window_title_changed", windowTitleChanged)
        put("window_frame_changed", windowFrameChanged)
        put("scroll_position_changed", scrollPositionChanged)
        put("scroll_content_changed", scrollContentChanged)
        put("scroll_at_extent", scrollAtExtent)
        put("target_in_web_area", targetInWebArea)
        put("independent_element_changed", independentElementChanged)
        put("target_state_changed", targetStateChanged)
        if !notes.isEmpty {
            fields["notes"] = .array(notes.map { .string($0) })
        }
        return .object(fields)
    }
}

// MARK: - The outcome envelope

struct ActionOutcome: Sendable {
    let classification: ActionClassification
    let failureDomain: FailureDomain?
    let summary: String
    let verification: ActionVerification?
    let webAXEchoRisk: Bool

    init(
        classification: ActionClassification,
        failureDomain: FailureDomain?,
        summary: String,
        verification: ActionVerification?,
        webAXEchoRisk: Bool = false
    ) {
        self.classification = classification
        self.failureDomain = failureDomain
        self.summary = summary
        self.verification = verification
        self.webAXEchoRisk = webAXEchoRisk
    }

    var isSuccess: Bool { classification == .success }

    /// A sentence to prepend to the human-readable result body for non-success
    /// outcomes, so a human reading the transcript sees the verdict without
    /// parsing _meta. nil for success.
    var humanSentence: String? {
        isSuccess ? nil : summary
    }

    var value: Value {
        var fields: [String: Value] = [
            "classification": .string(classification.rawValue),
            "summary": .string(summary),
        ]
        if let failureDomain {
            fields["failure_domain"] = .string(failureDomain.rawValue)
        }
        if let verification {
            fields["verification"] = verification.value
        }
        if webAXEchoRisk {
            fields["web_ax_echo_risk"] = .bool(true)
        }
        return .object(fields)
    }

    static func success(_ summary: String, _ verification: ActionVerification? = nil) -> ActionOutcome {
        ActionOutcome(classification: .success, failureDomain: nil, summary: summary, verification: verification)
    }

    static func unsupported(
        _ domain: FailureDomain, _ summary: String, _ verification: ActionVerification? = nil
    ) -> ActionOutcome {
        ActionOutcome(classification: .unsupported, failureDomain: domain, summary: summary, verification: verification)
    }

    static func effectNotVerified(
        _ domain: FailureDomain, _ summary: String, _ verification: ActionVerification? = nil
    ) -> ActionOutcome {
        ActionOutcome(
            classification: .effectNotVerified, failureDomain: domain, summary: summary, verification: verification)
    }

    static func ambiguous(
        _ domain: FailureDomain?, _ summary: String, _ verification: ActionVerification? = nil
    ) -> ActionOutcome {
        ActionOutcome(
            classification: .verifierAmbiguous, failureDomain: domain, summary: summary, verification: verification)
    }
}

// MARK: - Action family and intent

enum ActionFamily: Sendable {
    case click, type, setValue, scroll, window, menu, secondaryAction, drag

    /// Families that read fields off the acted-on element itself. The rest are
    /// judged purely from whole-window observations.
    var readsTargetFields: Bool {
        switch self {
        case .click, .type, .setValue: return true
        case .scroll, .window, .menu, .secondaryAction, .drag: return false
        }
    }
}

/// What an action is trying to do, carried so the pure reducer can decide
/// already-satisfied (pre-dispatch) and satisfied (post-reread).
enum ActionIntent: Sendable, Equatable {
    /// Generic activation (button press); success is any observed change.
    case activate
    /// A click whose intended effect is focus/caret placement.
    case focusTarget
    /// Toggle a checkbox/radio to a desired boolean state.
    case toggle(Bool)
    /// Insert text at the caret (type_text); success = value contains the text.
    case insertText(String)
    /// Set a field to an exact string value (set_value).
    case setText(String)
    /// Set a numeric value (slider/stepper); success within a step tolerance.
    case setNumber(Double)
    /// Scroll content.
    case scrollContent
    /// Open a menu / context menu.
    case openMenu

    /// Pre-dispatch idempotent no-op: the target is already in the requested
    /// state, so dispatch can be skipped and the outcome is success.
    func alreadySatisfied(by v: ActionVerification) -> Bool {
        switch self {
        case .toggle(let want):
            return v.beforeSelected == want
        case .setText(let want):
            return v.beforeValuePreview == want
        case .setNumber(let want):
            guard let text = v.beforeValuePreview, let current = Double(text) else { return false }
            return abs(current - want) < numberEpsilon
        case .activate, .focusTarget, .insertText, .scrollContent, .openMenu:
            return false
        }
    }

    /// Post-reread: does the observed after-state satisfy the intent? Returns an
    /// optional app-specific-semantics note when the effect landed but diverged
    /// from the exact request (slider snapped to a step).
    func satisfiedByAfter(_ v: ActionVerification) -> (satisfied: Bool, semanticsNote: String?) {
        switch self {
        case .toggle(let want):
            guard let selected = v.afterSelected else { return (false, nil) }
            return (selected == want, nil)
        case .insertText(let text):
            guard let after = v.afterValuePreview else { return (false, nil) }
            return (after.contains(text), nil)
        case .setText(let want):
            guard let after = v.afterValuePreview else { return (false, nil) }
            return (after == want, nil)
        case .setNumber(let want):
            guard let text = v.afterValuePreview, let current = Double(text) else { return (false, nil) }
            if abs(current - want) < numberEpsilon { return (true, nil) }
            let step = max(1.0, abs(want) * 0.05)
            if abs(current - want) <= step {
                return (true, "Snapped to the nearest step: requested \(want), applied \(current).")
            }
            return (false, nil)
        case .activate, .focusTarget, .scrollContent, .openMenu:
            return (false, nil)
        }
    }
}

private let numberEpsilon = 1e-6

// MARK: - The reducer (pure — one test per §4 matrix row)

extension ActionVerifier {
    /// The decision procedure of docs/outcome-contract.md §4.7. Pure: a function
    /// of the merged before/after evidence plus dispatch context. `rereadFailed`
    /// means the after-reread of the target threw (relocated/gone).
    static func reduce(
        family: ActionFamily,
        intent: ActionIntent,
        verification v: ActionVerification,
        rereadFailed: Bool,
        dispatchSucceeded: Bool,
        deliveryTier: String,
        hasTargetElement: Bool
    ) -> ActionOutcome {
        // Step 1: already-satisfied short-circuit (also valid post-dispatch).
        if intent.alreadySatisfied(by: v) {
            var record = v
            record.notes.append("Target was already in the requested state.")
            return .success("The target was already in the requested state.", record)
        }

        let droppable = isDroppableBackgroundDeliveryTier(deliveryTier)
        let windowChanged = v.windowChanged

        switch family {
        case .click, .secondaryAction, .drag:
            if intent == .focusTarget, v.afterFocused == true, !rereadFailed {
                return .success("The target is focused after the click.", v)
            }
            if v.targetStateChanged == true {
                return .success("The target's state changed after the action.", v)
            }
            if windowChanged {
                return .success("The UI changed after the action.", v)
            }
            if rereadFailed {
                return .ambiguous(.targeting, "The target could not be re-read; no confirming change was observed.", v)
            }
            if !hasTargetElement {
                return .ambiguous(
                    .targeting,
                    "No confirming change was observed after this click, and there is no element to re-read.", v)
            }
            if droppable {
                return .effectNotVerified(
                    .transport,
                    "No confirming change was observed; the event was delivered via a droppable "
                        + "background tier and may not have landed.", v)
            }
            return .effectNotVerified(
                .verification,
                "No confirming change was observed after this action; the app may have ignored it.", v)

        case .type:
            let (ok, _) = intent.satisfiedByAfter(v)
            if ok {
                if let webEcho = webAXEchoDowngradeIfNeeded(verification: v, deliveryTier: deliveryTier) {
                    return webEcho
                }
                return .success("The typed text is present in the field.", v)
            }
            if windowChanged {
                if let webEcho = webAXEchoDowngradeIfNeeded(verification: v, deliveryTier: deliveryTier) {
                    return webEcho
                }
                return .success("The typed text is reflected in the UI.", v)
            }
            if v.afterValuePreview == nil {
                var record = v
                record.notes.append("Value not observable (secure field or unreadable); could not confirm.")
                return .ambiguous(.verification, "Could not confirm the typed text landed (value not observable).", record)
            }
            if rereadFailed {
                return .ambiguous(.targeting, "The field could not be re-read after typing.", v)
            }
            if droppable {
                return .effectNotVerified(
                    .transport,
                    "The field's value does not reflect the typed text; the keystrokes may have been dropped.", v)
            }
            return .effectNotVerified(
                .verification, "The field's value does not reflect the typed text; the app may have ignored it.", v)

        case .setValue:
            let (ok, note) = intent.satisfiedByAfter(v)
            if ok {
                if let webEcho = webAXEchoDowngradeIfNeeded(verification: v, deliveryTier: deliveryTier) {
                    return webEcho
                }
                var record = v
                if let note { record.notes.append(note) }
                let outcome = ActionOutcome(
                    classification: .success,
                    failureDomain: note == nil ? nil : .appSpecificSemantics,
                    summary: note ?? "The value was set as requested.", verification: record)
                return outcome
            }
            if v.afterValuePreview == nil {
                return .ambiguous(.targeting, "The value could not be re-read after setting it.", v)
            }
            if rereadFailed {
                return .ambiguous(.targeting, "The element could not be re-read after setting its value.", v)
            }
            return .effectNotVerified(
                .verification, "The value did not change to the requested value; the app may have rejected it.", v)

        case .scroll:
            if v.scrollPositionChanged == true || v.scrollContentChanged == true {
                return .success("The content scrolled.", v)
            }
            if v.scrollAtExtent == true {
                var record = v
                record.notes.append("Already scrolled to the extent in the requested direction.")
                return .success("Already at the end of the scrollable content.", record)
            }
            if v.scrollPositionChanged == nil && v.scrollContentChanged == nil {
                return .ambiguous(.targeting, "Could not observe whether the content scrolled.", v)
            }
            let summary =
                "Wheel events were delivered but no content movement was observed; the target may not accept "
                + "background scroll. Try PageDown/PageUp keys or an element ScrollUpByPage/ScrollDownByPage action."
            if droppable {
                return .effectNotVerified(.transport, summary, v)
            }
            return .effectNotVerified(.verification, summary, v)

        case .window:
            // manage_window classifies via ActionVerifier.windowOutcome (numeric
            // frame compare); this branch is a fallback for direct reducer use.
            if v.windowFrameChanged == true {
                return .success("The window frame changed.", v)
            }
            return .effectNotVerified(.verification, "The window frame did not change.", v)

        case .menu:
            if windowChanged {
                return .success("The UI changed after the menu action.", v)
            }
            return .ambiguous(
                .verification,
                "The menu action fired but no observable UI change followed; menu state is often not "
                    + "readable via accessibility.", v)
        }
    }

    /// Window-frame classification (§4.5). Pure and numeric so it is unit-tested
    /// without a live window. `requested` is the requested size/position;
    /// `before`/`after` are the observed window frames. Tolerance absorbs the
    /// sub-pixel and title-bar noise; a clamped-but-moved frame is a success
    /// with an app-specific-semantics note, a frame that did not move at all is
    /// effect_not_verified.
    static func windowOutcome(
        action: String,
        requestedWidth: Double?, requestedHeight: Double?,
        requestedX: Double?, requestedY: Double?,
        before: CGRect, after: CGRect
    ) -> ActionOutcome {
        var v = ActionVerification()
        let tolerance = 2.0
        let isResize = action == "resize"
        let requested: (Double, Double)? =
            isResize
            ? requestedWidth.map { ($0, requestedHeight ?? Double(after.height)) }
            : requestedX.map { ($0, requestedY ?? Double(after.origin.y)) }
        let beforeValue =
            isResize
            ? (Double(before.width), Double(before.height))
            : (Double(before.origin.x), Double(before.origin.y))
        let afterValue =
            isResize
            ? (Double(after.width), Double(after.height))
            : (Double(after.origin.x), Double(after.origin.y))

        v.windowFrameChanged =
            abs(beforeValue.0 - afterValue.0) > tolerance || abs(beforeValue.1 - afterValue.1) > tolerance
        v.beforeValuePreview = frameString(beforeValue)
        v.afterValuePreview = frameString(afterValue)

        guard let requested else {
            return .success("The window \(action) was applied.", v)
        }

        let reachedRequest =
            abs(afterValue.0 - requested.0) <= tolerance && abs(afterValue.1 - requested.1) <= tolerance
        if reachedRequest {
            return .success("The window reached the requested \(action).", v)
        }
        if v.windowFrameChanged == true {
            v.notes.append(
                "Requested \(frameString(requested)), applied \(frameString(afterValue)) — clamped by the app.")
            return ActionOutcome(
                classification: .success, failureDomain: .appSpecificSemantics,
                summary: "The window \(action) was clamped: requested \(frameString(requested)), "
                    + "applied \(frameString(afterValue)).", verification: v)
        }
        return .effectNotVerified(
            .verification,
            "The window did not \(action): it stayed at \(frameString(afterValue)), not the requested "
                + "\(frameString(requested)).", v)
    }

    private static func frameString(_ pair: (Double, Double)) -> String {
        "\(roundedIntegerDescription(pair.0))x\(roundedIntegerDescription(pair.1))"
    }

    private static func webAXEchoDowngradeIfNeeded(
        verification v: ActionVerification, deliveryTier: String
    ) -> ActionOutcome? {
        guard v.targetInWebArea == true else { return nil }
        guard deliveryTier == InputTier.accessibilityAttribute.rawValue else { return nil }
        guard v.independentElementChanged != true else { return nil }
        var record = v
        record.notes.append(
            "The only confirming signal was AX-observed local state or tree change; no independent web-content diff corroborated it."
        )
        return ActionOutcome(
            classification: .effectNotVerified,
            failureDomain: .web,
            summary:
                "The target is inside web content. Accessibility reported a change, but no independent "
                + "web-content change confirmed that the renderer or DOM observed it.",
            verification: record,
            webAXEchoRisk: true)
    }
}

// MARK: - The verifier: captures before-state, reduces after the reread

/// Built by a handler post-dispatch, carrying the before-capture plus the
/// context the reducer needs. `stateResult` re-resolves the target, captures
/// the after-state, and calls `finalize`.
struct ActionVerifier: Sendable {
    let family: ActionFamily
    let intent: ActionIntent
    let deliveryTier: String
    let dispatchSucceeded: Bool
    let hasTargetElement: Bool
    /// Locator for the acted-on element, re-resolved for the after-read. nil for
    /// coordinate clicks and whole-window families.
    let snapshotElement: SnapshotElement?
    /// Fields captured before dispatch (before_* slots filled).
    var before: ActionVerification = ActionVerification()
    /// Window title before dispatch, for the window-title-changed bit.
    var beforeWindowTitle: String? = nil
    /// A fully decided outcome (already-satisfied / unsupported / skipped
    /// dispatch), when the handler classified pre-dispatch. finalize returns it
    /// verbatim without an after-reread.
    var resolved: ActionOutcome? = nil

    /// Capture the target-local before fields for a family that reads them.
    static func captureBefore(
        _ element: AXUIElement?, family: ActionFamily, snapshotElement: SnapshotElement? = nil
    ) -> ActionVerification {
        var v = ActionVerification()
        guard family.readsTargetFields, let element else { return v }
        v.beforeValuePreview = verifierValuePreview(element)
        v.beforeSelected = verifierToggleState(element)
        v.beforeFocused = axBool(element, kAXFocusedAttribute)
        v.targetInWebArea = targetIsInWebArea(element, snapshotElement: snapshotElement)
        return v
    }

    /// The verdict when the caller asked for no state (include_state=false): a
    /// pre-resolved outcome still stands, otherwise we cannot have observed
    /// anything, so the honest answer is verifier_ambiguous — never a success
    /// manufactured without a reread.
    func skippedStateOutcome() -> ActionOutcome {
        if let resolved { return resolved }
        var record = before
        record.notes.append("State verification skipped (include_state=false).")
        return .ambiguous(nil, "State verification was skipped (include_state=false).", record)
    }

    private func independentElementChanged(in diff: TreeDiff?) -> Bool? {
        guard let diff else { return nil }
        switch (family, intent) {
        case (.type, .insertText(let text)), (.setValue, .setText(let text)):
            return diff.hasChangeIndependent(of: snapshotElement, matching: text)
        case (.setValue, .setNumber):
            return false
        default:
            return diff.hasChangeIndependent(of: snapshotElement)
        }
    }

    /// Re-resolve the target, read the after-state, and reduce to an outcome.
    /// A reread problem degrades the classification; it never throws.
    func finalize(
        windowElement: AXUIElement?, treeChanged: Bool, diff: TreeDiff?, afterWindowTitle: String?
    ) async -> ActionOutcome {
        if let resolved { return resolved }

        var v = before
        v.renderedTextChanged = treeChanged
        v.independentElementChanged = independentElementChanged(in: diff)
        if family == .scroll {
            if let changed = scrollRelevantChange(in: diff), v.scrollContentChanged != true {
                v.scrollContentChanged = changed
            } else if !treeChanged, v.scrollContentChanged == nil {
                v.scrollContentChanged = false
            }
            if treeChanged, v.scrollPositionChanged != true, v.scrollContentChanged != true {
                v.notes.append("The window tree changed, but no scroll-specific movement signal changed.")
            }
        }
        if let beforeWindowTitle {
            v.windowTitleChanged = beforeWindowTitle != afterWindowTitle
        }

        var rereadFailed = false
        if family.readsTargetFields, let snapshotElement, let windowElement {
            do {
                let live = try await resolveElement(snapshotElement, in: windowElement)
                v.captureAfter(live, family: family)
                v.refreshedTargetStrategy = "locator-path"
                if let atIndex = snapshotElement.id.firstIndex(of: "@") {
                    v.notes.append("Target resolved from generation \(snapshotElement.id[snapshotElement.id.index(after: atIndex)...]).")
                }
            } catch {
                rereadFailed = true
                v.targetRelocated = true
                v.notes.append("Target could not be re-resolved after the action (relocated or gone).")
            }
        }

        return ActionVerifier.reduce(
            family: family, intent: intent, verification: v,
            rereadFailed: rereadFailed, dispatchSucceeded: dispatchSucceeded,
            deliveryTier: deliveryTier, hasTargetElement: hasTargetElement)
    }
}

extension ActionVerification {
    /// Read the target-local after fields and derive `targetStateChanged`.
    mutating func captureAfter(_ element: AXUIElement, family: ActionFamily) {
        guard family.readsTargetFields else { return }
        afterValuePreview = verifierValuePreview(element)
        afterSelected = verifierToggleState(element)
        afterFocused = axBool(element, kAXFocusedAttribute)
        targetStateChanged =
            beforeValuePreview != afterValuePreview || beforeSelected != afterSelected
    }
}

/// The truncated, secure-field-aware value preview, reused from the type_text
/// read-back guard: never echo a secure field, and skip huge documents.
func verifierValuePreview(_ element: AXUIElement) -> String? {
    guard axString(element, kAXSubroleAttribute) != (kAXSecureTextFieldSubrole as String) else { return nil }
    if let count = (axAttribute(element, "AXNumberOfCharacters") as? NSNumber)?.intValue, count > 200_000 {
        return nil
    }
    guard let value = axString(element, kAXValueAttribute) else { return nil }
    return value.count > 2000 ? String(value.prefix(2000)) : value
}

/// Boolean toggle state of a checkbox/radio (AXValue "1"/"0") or a selectable
/// row (AXSelected). nil when the element has no such state.
func verifierToggleState(_ element: AXUIElement) -> Bool? {
    if let value = axString(element, kAXValueAttribute), value == "0" || value == "1" {
        return value == "1"
    }
    return axBool(element, "AXSelected")
}

// MARK: - _meta attachment

extension CallTool.Result {
    func withActionOutcome(_ outcome: ActionOutcome?) -> CallTool.Result {
        guard let outcome else { return self }
        return mergingMetaField(actionOutcomeMetaKey, outcome.value)
    }
}
