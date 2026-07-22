 #if os(macOS)
// Text and value manipulation via the accessibility API: type_text,
// set_value, select_text, perform_secondary_action.

import Foundation
import MCP
#if os(macOS)
import ApplicationServices
#endif

// MARK: - type_text

func typeTextImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    let text = try args.requireString("text")
    try ArgumentBounds.checkStringLength(text, argument: "text", maximum: ArgumentBounds.maxTypeTextCharacters)
    let confirmed = SafetyPolicy.confirmed(args)
    try SafetyPolicy.check(app: app, confirmed: confirmed)
    let focus = FocusChangeTracker.start()

    let element: AXUIElement
    let described: String
    let snapshotElement: SnapshotElement?
    let windowTitle: String?
    if let elementID = args.string("element_id") {
        let target = try await resolveTarget(app: app, elementID: elementID)
        element = target.element
        described = describeTarget(target)
        snapshotElement = target.snapshotElement
        windowTitle = target.snapshot.windowTitle
    } else {
        guard let focused = axElement(app.axApplication, kAXFocusedUIElementAttribute) else {
            throw ToolError.failed(
                "\(app.name) has no focused element. Pass element_id for the field to type into."
            )
        }
        element = focused
        described = "the focused element (\(axRole(focused)))"
        snapshotElement = nil
        windowTitle = await SnapshotStore.shared.load(forPid: app.pid)?.windowTitle
    }

    try SafetyPolicy.checkTyping(into: element, app: app, confirmed: confirmed)
    // Read (before): capture the field's value before the insertion.
    let before = ActionVerifier.captureBefore(element, family: .type, snapshotElement: snapshotElement)
    let tier = try insertText(text, into: element, app: app, described: described)
    let warning = readBackWarning(typed: text, element: element)
    let verifier = ActionVerifier(
        family: .type, intent: .insertText(text), deliveryTier: tier.rawValue,
        dispatchSucceeded: true, hasTargetElement: snapshotElement != nil,
        snapshotElement: snapshotElement, before: before, beforeWindowTitle: windowTitle)
    return try await stateResult(
        app: app, windowTitle: windowTitle,
        note: "Typed \(text.count) characters into \(described). "
            + (warning ?? "Verify the new value below."),
        screenshot: screenshotDetail(args),
        focusTelemetry: focus.finish(deliveryTier: tier.rawValue),
        verifier: verifier
    )
}

/// Read the element's value back after insertion and verify the typed text
/// actually landed — some apps report success for the AX write and then
/// ignore it. Skipped for secure fields (never echo), long texts, and huge
/// documents where the full-value read would be expensive.
private func readBackWarning(typed: String, element: AXUIElement) -> String? {
    guard axString(element, kAXSubroleAttribute) != (kAXSecureTextFieldSubrole as String) else { return nil }
    if let count = (axAttribute(element, "AXNumberOfCharacters") as? NSNumber)?.intValue,
        count > 200_000
    {
        return nil
    }
    return typedTextWarning(typed: typed, currentValue: axString(element, kAXValueAttribute))
}

/// Pure part of the read-back check, separated for tests. nil when the typed
/// text is present or verification is not feasible.
func typedTextWarning(typed: String, currentValue: String?) -> String? {
    guard typed.count <= 500, !typed.isEmpty, let currentValue else { return nil }
    guard !currentValue.contains(typed) else { return nil }
    return
        "Warning: the element's value does not contain the typed text after insertion — "
        + "the app may have ignored or transformed the input. Inspect the state below "
        + "before proceeding."
}

/// Insert text at the element's current selection (collapsed selection =
/// caret). Prefers the canonical kAXSelectedText replacement, then splicing the
/// full value; if the element accepts neither (custom/web fields), falls back
/// to background-safe synthetic Unicode key events. Returns the tier used.
private func insertText(_ text: String, into element: AXUIElement, app: ResolvedApp, described: String) throws -> InputTier {
    var settable = DarwinBoolean(false)

    // Preferred: replace the current selection.
    if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
        settable.boolValue,
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    {
        return .accessibilityAttribute
    }

    // Next: splice into the full value at the selected range.
    guard
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
        settable.boolValue
    else {
        // The element exposes no settable AX value. Focus it (best effort) so
        // synthetic keys land here, then type through Unicode key events posted
        // to the pid — same background-safe, pid-targeted discipline as the
        // click ladder, never a global post. The secure-field gate already ran
        // in typeTextImpl, so this path stays behind that confirmation.
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let context = DeliveryContext(pid: app.pid, windowNumber: nil, windowFrame: nil, allowGlobalCursor: false)
        return try typeUnicodeText(text, context: context)
    }

    let current = axString(element, kAXValueAttribute) ?? ""
    let nsCurrent = current as NSString
    var range = CFRange(location: nsCurrent.length, length: 0)
    if let rangeValue = axAttribute(element, kAXSelectedTextRangeAttribute),
        CFGetTypeID(rangeValue) == AXValueGetTypeID()
    {
        AXValueGetValue(rangeValue as! AXValue, .cfRange, &range)
    }
    let start = max(0, min(range.location, nsCurrent.length))
    let length = max(0, min(range.length, nsCurrent.length - start))
    let updated = nsCurrent.replacingCharacters(in: NSRange(location: start, length: length), with: text)

    guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, updated as CFString) == .success
    else {
        throw ToolError.failed("Could not set the value of \(described).")
    }

    // Place the caret after the inserted text.
    var caret = CFRange(location: start + (text as NSString).length, length: 0)
    if let caretValue = AXValueCreate(.cfRange, &caret) {
        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, caretValue)
    }
    return .accessibilityAttribute
}

// MARK: - set_value

func setValueImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    let confirmed = SafetyPolicy.confirmed(args)
    try SafetyPolicy.check(app: app, confirmed: confirmed)
    let focus = FocusChangeTracker.start()
    let target = try await resolveTarget(app: app, elementID: args.requireString("element_id"))
    try SafetyPolicy.checkTyping(into: target.element, app: app, confirmed: confirmed)
    // An empty value is valid (clearing a field), so accept "" rather than
    // treating it as a missing argument.
    guard let value = args.string("value") else {
        throw ToolError.invalidArguments("\"value\" (string) is required.")
    }
    try ArgumentBounds.checkStringLength(value, argument: "value", maximum: ArgumentBounds.maxSetValueCharacters)
    try SafetyPolicy.checkValueChange(
        currentValue: axString(target.element, kAXValueAttribute), newValue: value, app: app, confirmed: confirmed
    )

    // Read (before): capture the target's fields before dispatch.
    let before = ActionVerifier.captureBefore(
        target.element, family: .setValue, snapshotElement: target.snapshotElement)
    let windowTitle = target.snapshot.windowTitle
    func verifier(
        intent: ActionIntent, tier: InputTier, dispatched: Bool, resolved: ActionOutcome? = nil
    ) -> ActionVerifier {
        ActionVerifier(
            family: .setValue, intent: intent, deliveryTier: tier.rawValue, dispatchSucceeded: dispatched,
            hasTargetElement: true, snapshotElement: target.snapshotElement, before: before,
            beforeWindowTitle: windowTitle, resolved: resolved)
    }

    // Checkboxes and radio buttons: treat as semantic toggle.
    if target.snapshotElement.role == "AXCheckBox" || target.snapshotElement.role == "AXRadioButton" {
        guard let desired = Bool(value.lowercased()) ?? (value == "1" ? true : value == "0" ? false : nil)
        else {
            throw ToolError.invalidArguments("For \(target.snapshotElement.role), value must be true or false.")
        }
        // Already-satisfied is a success, not a wasted press: skip dispatch when
        // the control is already in the requested state (the reducer classifies
        // it success from the before-state).
        let current = before.beforeSelected ?? false
        if current != desired {
            try performAXAction(kAXPressAction as String, on: target)
        }
        return try await stateResult(
            app: app, windowTitle: windowTitle,
            note: "Set \(describeTarget(target)) to \(desired).",
            screenshot: screenshotDetail(args),
            focusTelemetry: focus.finish(deliveryTier: InputTier.accessibilityAction.rawValue),
            verifier: verifier(intent: .toggle(desired), tier: .accessibilityAction, dispatched: current != desired)
        )
    }

    var settable = DarwinBoolean(false)
    guard
        AXUIElementIsAttributeSettable(target.element, kAXValueAttribute as CFString, &settable) == .success,
        settable.boolValue
    else {
        // No settable value: retrying won't help — classify unsupported rather
        // than throw (isError stays false, the agent learns to switch tools).
        return try await stateResult(
            app: app, windowTitle: windowTitle,
            note: "\(describeTarget(target)) does not accept a direct value; nothing was set.",
            screenshot: screenshotDetail(args),
            focusTelemetry: focus.finish(deliveryTier: InputTier.accessibilityAttribute.rawValue),
            verifier: verifier(
                intent: .setText(value), tier: .accessibilityAttribute, dispatched: false,
                resolved: .unsupported(
                    .unsupported,
                    "\(describeTarget(target)) does not accept a direct value. Use click/type_text, "
                        + "or check the element's actions in get_app_state."))
        )
    }

    // Numeric elements (sliders, steppers) want numbers, not strings. A
    // non-numeric string into a numeric field is a coercion failure — do not
    // send it (today's code silently would).
    let currentValue = axAttribute(target.element, kAXValueAttribute)
    let isNumeric = currentValue.map { CFGetTypeID($0) == CFNumberGetTypeID() } ?? false
    let newValue: CFTypeRef
    let intent: ActionIntent
    if isNumeric {
        guard let number = Double(value) else {
            return try await stateResult(
                app: app, windowTitle: windowTitle,
                note: "\(describeTarget(target)) takes a number; \"\(value)\" is not numeric and was not applied.",
                screenshot: screenshotDetail(args),
                focusTelemetry: focus.finish(deliveryTier: InputTier.accessibilityAttribute.rawValue),
                verifier: verifier(
                    intent: .setText(value), tier: .accessibilityAttribute, dispatched: false,
                    resolved: .unsupported(
                        .coercion,
                        "\(describeTarget(target)) takes a number; \"\(value)\" is not numeric."))
            )
        }
        newValue = NSNumber(value: number)
        intent = .setNumber(number)
    } else {
        newValue = value as CFString
        intent = .setText(value)
    }

    guard AXUIElementSetAttributeValue(target.element, kAXValueAttribute as CFString, newValue) == .success
    else {
        throw ToolError.failed("Setting the value of \(describeTarget(target)) failed.")
    }
    return try await stateResult(
        app: app, windowTitle: windowTitle,
        note: "Set the value of \(describeTarget(target)). Verify it below.",
        screenshot: screenshotDetail(args),
        focusTelemetry: focus.finish(deliveryTier: InputTier.accessibilityAttribute.rawValue),
        verifier: verifier(intent: intent, tier: .accessibilityAttribute, dispatched: true)
    )
}

// MARK: - select_text

func selectTextImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    let focus = FocusChangeTracker.start()
    let target = try await resolveTarget(app: app, elementID: args.requireString("element_id"))
    let text = try args.requireString("text")
    let occurrence = max(1, args.integer("occurrence") ?? 1)

    guard let value = axString(target.element, kAXValueAttribute) else {
        throw ToolError.failed("\(describeTarget(target)) has no text value to select within.")
    }

    let nsValue = value as NSString
    var searchStart = 0
    var found = NSRange(location: NSNotFound, length: 0)
    for _ in 0..<occurrence {
        found = nsValue.range(
            of: text, options: [], range: NSRange(location: searchStart, length: nsValue.length - searchStart)
        )
        guard found.location != NSNotFound else { break }
        searchStart = found.location + 1
    }
    guard found.location != NSNotFound else {
        throw ToolError.failed(
            "\"\(text)\" (occurrence \(occurrence)) was not found in \(describeTarget(target)). "
                + "Provide the text exactly as it appears in the element's value."
        )
    }

    // position: select the match (default), or collapse the caret to one end —
    // for inserting text before/after a landmark with type_text.
    let position = args.string("position") ?? "select"
    var range: CFRange
    let note: String
    switch position {
    case "select":
        range = CFRange(location: found.location, length: found.length)
        note = "Selected \"\(text)\" in \(describeTarget(target))."
    case "before":
        range = CFRange(location: found.location, length: 0)
        note = "Placed the cursor before \"\(text)\" in \(describeTarget(target))."
    case "after":
        range = CFRange(location: found.location + found.length, length: 0)
        note = "Placed the cursor after \"\(text)\" in \(describeTarget(target))."
    default:
        throw ToolError.invalidArguments("position must be select, before, or after.")
    }
    guard let rangeValue = AXValueCreate(.cfRange, &range),
        AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
            == .success
    else {
        throw ToolError.failed("\(describeTarget(target)) did not accept the text selection.")
    }
    return try await stateResult(
        app: app, windowTitle: target.snapshot.windowTitle,
        note: note,
        screenshot: screenshotDetail(args),
        focusTelemetry: focus.finish(deliveryTier: InputTier.accessibilityAttribute.rawValue)
    )
}

// MARK: - read_text

func readTextImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    let target = try await resolveTarget(app: app, elementID: args.requireString("element_id"))

    // Visible-range path: for a large text surface, pull only the on-screen
    // slice (rendered to markdown) instead of the whole value. Activates when
    // the caller asks (visible_only:true), or by default once the value is
    // past the threshold and no explicit offset/length window was requested.
    // An explicit visible_only:false, or an offset/length, keeps the classic
    // full-value read; the path is best-effort and falls through when the
    // element exposes no parameterized range attribute.
    let visibleOnly = args.bool("visible_only")
    let hasExplicitWindow = args["offset"] != nil || args["length"] != nil
    let charCount = (axAttribute(target.element, "AXNumberOfCharacters") as? NSNumber)?.intValue
    let isLarge = (charCount ?? 0) > TextExtraction.largeValueThreshold
    let useVisible = visibleOnly == true || (visibleOnly == nil && !hasExplicitWindow && isLarge)
    if useVisible {
        if let visible = TextExtraction.visibleText(of: target.element) {
            let total = charCount.map { " of \($0) total" } ?? ""
            let header =
                "Visible text of \(describeTarget(target)) — "
                + "chars \(visible.range.location)..<\(visible.range.location + visible.range.length)\(total) "
                + "(scroll for more, or omit visible_only for the full value)"
            return .text(header + ":\n" + visible.markdown)
        }
        // Web content (WKWebView) carries no character range; pull its rich
        // text via text markers and render it to markdown instead.
        if let markdown = TextExtraction.webAreaMarkdown(of: target.element) {
            let header =
                "Rich text of \(describeTarget(target)) — web content rendered to markdown "
                + "(omit visible_only for the raw value)"
            return .text(header + ":\n" + markdown)
        }
    }

    guard let value = axString(target.element, kAXValueAttribute) else {
        throw ToolError.failed("\(describeTarget(target)) has no readable text value.")
    }
    let offset = args.integer("offset") ?? 0
    let requested = args.integer("length") ?? 20_000
    try ArgumentBounds.checkReadText(offset: offset, length: requested)
    let characters = Array(value)
    guard offset < characters.count || characters.isEmpty else {
        throw ToolError.invalidArguments("offset \(offset) is past the end (\(characters.count) chars).")
    }
    let slice = String(characters[offset..<min(characters.count, offset + max(1, requested))])
    var header = "Text of \(describeTarget(target)) — \(characters.count) chars total"
    if offset > 0 || offset + slice.count < characters.count {
        header += ", showing \(offset)..<\(offset + slice.count) (use offset/length for more)"
    }
    return .text(header + ":\n" + slice)
}

// MARK: - perform_secondary_action

func performSecondaryActionImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    let confirmed = SafetyPolicy.confirmed(args)
    try SafetyPolicy.check(app: app, confirmed: confirmed)
    let focus = FocusChangeTracker.start()
    let target = try await resolveTarget(app: app, elementID: args.requireString("element_id"))
    let action = args.string("action") ?? "AXShowMenu"

    let available = axActionNames(target.element)
    guard available.contains(action) else {
        throw ToolError.failed(
            "\(describeTarget(target)) does not support \(action). "
                + "Available actions: \(available.joined(separator: ", "))."
        )
    }
    // Activating actions can be destructive (e.g. AXPress on a Delete button);
    // gate them like a click. Menu/stepper actions stay ungated.
    let activatingActions: Set<String> = [
        kAXPressAction as String, "AXConfirm", "AXPick", "AXOpen",
    ]
    if activatingActions.contains(action) {
        try SafetyPolicy.checkClick(label: clickableLabel(target.element), app: app, confirmed: confirmed)
    }
    try performAXAction(action, on: target)
    // Secondary actions are usually menu-shaped: success when the tree changes
    // (a context menu appeared), verifier_ambiguous when nothing observable
    // followed — menu state is frequently unreadable via accessibility.
    let verifier = ActionVerifier(
        family: .menu, intent: .openMenu, deliveryTier: InputTier.accessibilityAction.rawValue,
        dispatchSucceeded: true, hasTargetElement: false, snapshotElement: nil,
        beforeWindowTitle: target.snapshot.windowTitle)
    return try await stateResult(
        app: app, windowTitle: target.snapshot.windowTitle,
        note: "Performed \(action) on \(describeTarget(target)).",
        screenshot: screenshotDetail(args),
        focusTelemetry: focus.finish(deliveryTier: InputTier.accessibilityAction.rawValue),
        verifier: verifier
    )
}
#endif
