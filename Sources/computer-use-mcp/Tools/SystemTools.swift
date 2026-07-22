 #if os(macOS)
// System-level tools: open_app, open_url, list_windows, manage_window,
// click_menu_item, and clipboard access.

import Foundation
import MCP
#if os(macOS)
import AppKit
import ApplicationServices
#endif

// MARK: - open_app

func openAppImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let identifier = try args.requireString("app")
    let activate = args.bool("activate") ?? false
    let confirmed = SafetyPolicy.confirmed(args)
    let focus = FocusChangeTracker.start(focusChangeAllowed: activate)

    // Already running: report (and optionally activate) rather than relaunch.
    if let running = try? resolveApp(identifier) {
        try SafetyPolicy.checkOpenApp(identifier: running.name, activate: activate, isAlreadyRunning: true, confirmed: confirmed)
        if activate {
            NSRunningApplication(processIdentifier: running.pid)?.activate()
        }
        let note = "\(running.name) is already running\(activate ? " (activated)" : "")."
        if let result = try? await stateResult(app: running, windowTitle: nil, note: note) {
            return result.withFocusTelemetry(focus.finish(deliveryTier: InputTier.launchServices.rawValue))
        }
        return CallTool.Result.text(note + " It has no queryable window — press_key cmd+n may create one.")
            .withFocusTelemetry(focus.finish(deliveryTier: InputTier.launchServices.rawValue))
    }

    guard let url = applicationURL(for: identifier) else {
        throw ToolError.failed(
            "No app named \"\(identifier)\" found. Use a running-app name, a bundle id, "
                + "an app name from /Applications, or a full .app path. See list_apps."
        )
    }
    try SafetyPolicy.checkOpenApp(identifier: url.lastPathComponent, activate: activate, isAlreadyRunning: false, confirmed: confirmed)

    let configuration = NSWorkspace.OpenConfiguration()
    // Launch without stealing focus unless explicitly asked to.
    configuration.activates = activate
    let pid: pid_t = try await withCheckedThrowingContinuation { continuation in
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            if let app {
                continuation.resume(returning: app.processIdentifier)
            } else {
                continuation.resume(
                    throwing: ToolError.failed(
                        "Launching \(url.lastPathComponent) failed: \(error?.localizedDescription ?? "unknown error")."
                    ))
            }
        }
    }

    // Wait for the app to come up with a window (bounded).
    guard let running = NSRunningApplication(processIdentifier: pid) else {
        throw ToolError.failed("The launched app (pid \(pid)) exited immediately.")
    }
    let app = ResolvedApp(
        pid: pid, name: running.localizedName ?? identifier,
        bundleIdentifier: running.bundleIdentifier ?? "unknown"
    )
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if (try? targetWindow(for: app, title: nil)) != nil { break }
        try? await Task.sleep(for: .milliseconds(300))
    }

    // activates=false only binds LaunchServices — modern macOS still grants a
    // freshly launching regular app the activation it requests itself. When
    // that happens on a background launch, hand focus straight back.
    var note = "Launched \(app.name)."
    if !activate, let before = focus.before, before.pid != pid,
        FrontmostAppSnapshot.current()?.pid == pid,
        let previous = NSRunningApplication(processIdentifier: before.pid)
    {
        previous.activate()
        try? await Task.sleep(for: .milliseconds(150))
        note += " It took focus while launching; focus was returned to \(before.name)."
    }

    if let result = try? await stateResult(app: app, windowTitle: nil, note: note) {
        return result.withFocusTelemetry(focus.finish(deliveryTier: InputTier.launchServices.rawValue))
    }
    return CallTool.Result.text(
        "Launched \(app.name) (pid \(app.pid)), but it has no queryable window yet — it may "
            + "be showing an open-file dialog or need press_key cmd+n to create one."
    ).withFocusTelemetry(focus.finish(deliveryTier: InputTier.launchServices.rawValue))
}

/// Find an app on disk by bundle id, /Applications name, or full path.
private func applicationURL(for identifier: String) -> URL? {
    if identifier.contains("."), !identifier.hasSuffix(".app"),
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
    {
        return url
    }
    if identifier.hasSuffix(".app"), FileManager.default.fileExists(atPath: identifier) {
        return URL(fileURLWithPath: identifier)
    }
    let directories = [
        "/Applications", "/System/Applications", "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]
    for directory in directories {
        let exact = directory + "/" + identifier + ".app"
        if FileManager.default.fileExists(atPath: exact) { return URL(fileURLWithPath: exact) }
    }
    for directory in directories {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
        if let hit = entries.first(where: { $0.lowercased() == identifier.lowercased() + ".app" }) {
            return URL(fileURLWithPath: directory + "/" + hit)
        }
    }
    return nil
}

// MARK: - open_url

func openURLImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let raw = try args.requireString("url")
    let confirmed = SafetyPolicy.confirmed(args)
    try requireFocusChangeAllowed(
        args,
        reason: "Opening a URL or file path can launch or activate its default handler."
    )
    let focus = FocusChangeTracker.start(focusChangeAllowed: true)

    let url: URL
    if let parsed = URL(string: raw), parsed.scheme != nil {
        url = parsed
    } else if FileManager.default.fileExists(atPath: (raw as NSString).expandingTildeInPath) {
        url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    } else {
        throw ToolError.invalidArguments("\"\(raw)\" is not a valid URL or existing file path.")
    }

    try SafetyPolicy.checkOpenURL(url, confirmed: confirmed)

    guard NSWorkspace.shared.open(url) else {
        throw ToolError.failed("macOS refused to open \(url.absoluteString) (no handler?).")
    }
    try? await Task.sleep(for: .milliseconds(300))
    return CallTool.Result.text("Opened \(url.absoluteString) in the default handler. Call get_app_state on the handling app to continue.")
        .withFocusTelemetry(focus.finish(deliveryTier: InputTier.launchServices.rawValue))
}

// MARK: - list_windows

func listWindowsImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    try requireAppAlive(app)

    let windows = axElements(app.axApplication, kAXWindowsAttribute)
    guard !windows.isEmpty else {
        return .text("\(app.name) has no windows right now.")
    }
    var lines = ["Windows of \(app.name) (pid \(app.pid)):"]
    for window in windows {
        var parts: [String] = []
        let title = axString(window, kAXTitleAttribute) ?? ""
        parts.append("\"\(title)\"")
        if let subrole = axString(window, kAXSubroleAttribute), subrole != "AXStandardWindow" {
            parts.append(subrole)  // AXDialog, AXSystemDialog, AXFloatingWindow…
        }
        if let frame = axFrame(window) {
            parts.append("(\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height)) pt)")
        }
        if axBool(window, kAXMinimizedAttribute) == true { parts.append("minimized") }
        if axBool(window, kAXMainAttribute) == true { parts.append("main") }
        if axBool(window, kAXFocusedAttribute) == true { parts.append("focused") }
        if windowHasSheet(window) { parts.append("HAS OPEN SHEET/DIALOG") }
        lines.append("  " + parts.joined(separator: " "))
    }
    lines.append("Target a window by its title via the window_title argument of get_app_state or manage_window.")
    return .text(lines.joined(separator: "\n"))
}

private func windowHasSheet(_ window: AXUIElement) -> Bool {
    axElements(window, kAXChildrenAttribute).contains { axRole($0) == "AXSheet" }
}

// MARK: - manage_window

func manageWindowImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    let action = try args.requireString("action")
    let window = try targetWindow(for: app, title: args.string("window_title"))
    let described = "window \"\(window.title ?? "untitled")\" of \(app.name)"
    let confirmed = SafetyPolicy.confirmed(args)
    try SafetyPolicy.checkWindowAction(action: action, targetDescription: described, app: app, confirmed: confirmed)
    if action == "raise" {
        try requireFocusChangeAllowed(args, reason: "Raising a window can change foreground focus.")
    }
    let focus = FocusChangeTracker.start(focusChangeAllowed: action == "raise")

    func setAttribute(_ name: String, _ value: CFTypeRef) throws {
        let error = AXUIElementSetAttributeValue(window.element, name as CFString, value)
        guard error == .success else {
            throw ToolError.failed("Could not \(action) \(described) (\(axErrorDescription(error))).")
        }
    }

    // Each action builds a human note and an outcome that reports what actually
    // happened, read back from the window rather than trusted from the AX write
    // (which silently clamps or no-ops in many apps).
    let note: String
    var outcome: ActionOutcome?

    switch action {
    case "raise":
        let beforeMain = axBool(window.element, kAXMainAttribute)
        let error = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        guard error == .success else {
            throw ToolError.failed("Could not raise \(described) (\(axErrorDescription(error))).")
        }
        note = "Raised \(described)."
        let after = await WindowMotion.settleBool(
            desired: true, read: { axBool(window.element, kAXMainAttribute) })
        outcome = WindowMotion.raiseOutcome(described: described, before: beforeMain, after: after)
    case "minimize", "unminimize":
        let desired = action == "minimize"
        outcome = try await verifyBooleanWindowState(
            window: window.element, attribute: kAXMinimizedAttribute, desired: desired, described: described,
            achieved: desired ? "minimized" : "restored", already: desired ? "already minimized" : "not minimized")
        note = "\(desired ? "Minimized" : "Restored") \(described)."
    case "fullscreen", "exit_fullscreen":
        let desired = action == "fullscreen"
        outcome = try await verifyBooleanWindowState(
            window: window.element, attribute: "AXFullScreen", desired: desired, described: described,
            achieved: desired ? "in full screen" : "out of full screen",
            already: desired ? "already in full screen" : "not in full screen")
        note = "\(desired ? "Entered" : "Left") full screen for \(described)."
    case "move":
        guard let x = args.number("x"), let y = args.number("y") else {
            throw ToolError.invalidArguments("move requires x and y (global screen points, top-left origin).")
        }
        try ArgumentBounds.checkWindowPosition(x: x, y: y)
        guard let before = axFrame(window.element) else {
            throw ToolError.failed("Could not read the current frame of \(described).")
        }
        let target = CGRect(x: x, y: y, width: before.width, height: before.height)
        try preflightWindowTarget(target, described: described)
        var point = CGPoint(x: x, y: y)
        let positionValue = AXValueCreate(.cgPoint, &point)!
        try setAttribute(kAXPositionAttribute, positionValue)
        note = "Moved \(described) to (\(Int(x)),\(Int(y))) pt."
        outcome = await settledFrameOutcome(
            action: action, window: window.element, dimension: .position,
            target: target, before: before, described: described,
            requestedX: x, requestedY: y, requestedWidth: nil, requestedHeight: nil,
            attribute: kAXPositionAttribute, value: positionValue)
    case "resize":
        guard let width = args.number("width"), let height = args.number("height") else {
            throw ToolError.invalidArguments("resize requires width and height (points).")
        }
        try ArgumentBounds.checkWindowSize(width: width, height: height)
        guard let before = axFrame(window.element) else {
            throw ToolError.failed("Could not read the current frame of \(described).")
        }
        let target = CGRect(origin: before.origin, size: CGSize(width: width, height: height))
        try preflightWindowTarget(target, described: described)
        var size = CGSize(width: width, height: height)
        let sizeValue = AXValueCreate(.cgSize, &size)!
        try setAttribute(kAXSizeAttribute, sizeValue)
        note = "Resized \(described) to \(Int(width))x\(Int(height)) pt."
        outcome = await settledFrameOutcome(
            action: action, window: window.element, dimension: .size,
            target: target, before: before, described: described,
            requestedX: nil, requestedY: nil, requestedWidth: width, requestedHeight: height,
            attribute: kAXSizeAttribute, value: sizeValue)
    case "close":
        guard let button = axElement(window.element, kAXCloseButtonAttribute) else {
            throw ToolError.failed("\(described) has no close button.")
        }
        let error = AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard error == .success else {
            throw ToolError.failed("Could not close \(described) (\(axErrorDescription(error))).")
        }
        note = "Closed \(described). The app may show a save dialog — check list_windows."
        let gone = await WindowMotion.settleBool(
            desired: false, read: { windowStillPresent(window.element, in: app) }) == false
        outcome = WindowMotion.closeOutcome(
            described: described, gone: gone,
            sheetAppeared: !gone && windowHasSheet(window.element))
    default:
        throw ToolError.invalidArguments(
            "Unknown action \"\(action)\". Use raise, minimize, unminimize, move, resize, fullscreen, exit_fullscreen, or close."
        )
    }

    // Surface a clamp or a non-effect in the human text (success-with-clamp has
    // no humanSentence, but the requested-vs-actual divergence is worth stating).
    let finalNote = outcome.flatMap { $0.failureDomain != nil ? "\($0.summary)\n\n\(note)" : nil } ?? note

    // Minimize/close can leave no queryable window; degrade to the note.
    if let result = try? await stateResult(app: app, windowTitle: nil, note: finalNote) {
        return result
            .withFocusTelemetry(focus.finish(deliveryTier: InputTier.windowManagement.rawValue))
            .withActionOutcome(outcome)
    }
    return CallTool.Result.text(finalNote)
        .withFocusTelemetry(focus.finish(deliveryTier: InputTier.windowManagement.rawValue))
        .withActionOutcome(outcome)
}

/// Pre-validate a window target frame is finite and on-screen before writing it
/// — an offscreen or degenerate move is rejected as a recoverable error rather
/// than stranding the window where it cannot be grabbed.
private func preflightWindowTarget(_ target: CGRect, described: String) throws {
    switch WindowMotion.validate(target: target, displays: WindowMotion.activeDisplayBounds()) {
    case .none:
        return
    case .invalidTargetFrame(let message), .offscreenTargetFrame(let message):
        throw ToolError.invalidArguments(message)
    }
}

/// Settle-poll the window frame after a move/resize (it may still be animating,
/// and the app may clamp it), issue one corrective re-write if it landed off the
/// requested dimension, then classify the settled frame against the request.
private func settledFrameOutcome(
    action: String, window: AXUIElement, dimension: WindowMotion.Dimension,
    target: CGRect, before: CGRect, described: String,
    requestedX: Double?, requestedY: Double?, requestedWidth: Double?, requestedHeight: Double?,
    attribute: String, value: CFTypeRef
) async -> ActionOutcome {
    let settle = await WindowMotion.settle(
        target: target, dimension: dimension,
        read: { axFrame(window) },
        correct: { _ = AXUIElementSetAttributeValue(window, attribute as CFString, value) })
    guard let after = settle.frame else {
        return .ambiguous(.verification, "Could not read \(described)'s frame after the \(action).")
    }
    return ActionVerifier.windowOutcome(
        action: action,
        requestedWidth: requestedWidth, requestedHeight: requestedHeight,
        requestedX: requestedX, requestedY: requestedY,
        before: before, after: after)
}

/// Toggle a boolean window state (minimize/fullscreen), skipping the write when
/// it is already satisfied, then read the state back to confirm the flip.
private func verifyBooleanWindowState(
    window: AXUIElement, attribute: String, desired: Bool, described: String,
    achieved: String, already: String
) async throws -> ActionOutcome {
    let before = axBool(window, attribute)
    // Already in the requested state: a correct no-op, skip the write.
    if before == desired {
        return WindowMotion.booleanStateOutcome(
            described: described, achieved: achieved, already: already,
            desired: desired, before: before, after: before)
    }
    let error = AXUIElementSetAttributeValue(
        window, attribute as CFString, (desired ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    guard error == .success else {
        throw ToolError.failed("Could not update \(described) (\(axErrorDescription(error))).")
    }
    let after = await WindowMotion.settleBool(desired: desired, read: { axBool(window, attribute) })
    return WindowMotion.booleanStateOutcome(
        described: described, achieved: achieved, already: already,
        desired: desired, before: before, after: after)
}

/// Whether the window element is still among the app's live windows (used to
/// confirm a close actually removed it).
private func windowStillPresent(_ element: AXUIElement, in app: ResolvedApp) -> Bool {
    axElements(app.axApplication, kAXWindowsAttribute).contains { CFEqual($0, element) }
}

// MARK: - click_menu_item

func clickMenuItemImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    let confirmed = SafetyPolicy.confirmed(args)
    try SafetyPolicy.check(app: app, confirmed: confirmed)
    let focus = FocusChangeTracker.start()
    let path = try args.requireString("path")
    let segments = path.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }
    guard segments.count >= 2 else {
        throw ToolError.invalidArguments(
            "Provide a menu path with at least menu and item, e.g. \"File > Save\" or \"Format > Font > Bold\"."
        )
    }

    guard let menuBar = axElement(app.axApplication, kAXMenuBarAttribute) else {
        throw ToolError.failed("\(app.name) exposes no menu bar via accessibility.")
    }

    var current = menuBar
    for (index, segment) in segments.enumerated() {
        let candidates = await menuChildren(of: current)
        guard let match = matchMenuItem(segment, in: candidates) else {
            let available = candidates.compactMap { axString($0, kAXTitleAttribute) }
                .filter { !$0.isEmpty }.joined(separator: ", ")
            throw ToolError.failed(
                "No menu item \"\(segment)\" under \"\(segments.prefix(index).joined(separator: " > "))\". "
                    + "Available: \(available)."
            )
        }
        current = match
    }

    let label = axString(current, kAXTitleAttribute) ?? segments.last!
    try SafetyPolicy.checkClick(label: label, app: app, confirmed: confirmed)
    if axBool(current, kAXEnabledAttribute) == false {
        // A disabled item cannot fire — classify unsupported rather than throw.
        let verifier = ActionVerifier(
            family: .menu, intent: .openMenu, deliveryTier: InputTier.accessibilityAction.rawValue,
            dispatchSucceeded: false, hasTargetElement: false, snapshotElement: nil,
            resolved: .unsupported(.unsupported, "Menu item \"\(path)\" is disabled right now."))
        return try await stateResult(
            app: app, windowTitle: nil, note: "Menu item \"\(path)\" is disabled; nothing was selected.",
            screenshot: screenshotDetail(args),
            focusTelemetry: focus.finish(deliveryTier: InputTier.accessibilityAction.rawValue),
            verifier: verifier)
    }
    let error = AXUIElementPerformAction(current, kAXPressAction as CFString)
    guard error == .success else {
        throw ToolError.failed("Pressing menu item \"\(path)\" failed (\(axErrorDescription(error))).")
    }
    try? await Task.sleep(for: .milliseconds(120))
    let verifier = ActionVerifier(
        family: .menu, intent: .openMenu, deliveryTier: InputTier.accessibilityAction.rawValue,
        dispatchSucceeded: true, hasTargetElement: false, snapshotElement: nil)
    return try await stateResult(
        app: app, windowTitle: nil, note: "Selected menu \(segments.joined(separator: " > ")).",
        screenshot: screenshotDetail(args),
        focusTelemetry: focus.finish(deliveryTier: InputTier.accessibilityAction.rawValue),
        verifier: verifier
    )
}

/// Children of a menu container, descending the single AXMenu wrapper when
/// present. A submenu's items populate lazily — only once the menu is shown —
/// so when the wrapper exists but is empty, perform the item's show/press
/// action, let it settle, and read again. The open is gated on the presence of
/// an AXMenu wrapper, so a leaf command (which has none) is never pressed here:
/// an intermediate item is only ever opened, never activated. Background-safe:
/// the AX action delivers to the element with no real cursor.
private func menuChildren(of element: AXUIElement) async -> [AXUIElement] {
    func descend(_ raw: [AXUIElement]) -> [AXUIElement] {
        guard let menu = raw.first(where: { axRole($0) == "AXMenu" }) else { return raw }
        return axElements(menu, kAXChildrenAttribute)
    }
    let raw = axElements(element, kAXChildrenAttribute)
    let items = descend(raw)
    guard items.isEmpty, raw.contains(where: { axRole($0) == "AXMenu" }) else { return items }

    // The submenu wrapper is present but empty: show it to force population.
    for action in ["AXShowMenu", kAXPressAction as String] where axActionNames(element).contains(action) {
        guard AXUIElementPerformAction(element, action as CFString) == .success else { continue }
        try? await Task.sleep(for: .milliseconds(120))
        break
    }
    return descend(axElements(element, kAXChildrenAttribute))
}

/// Match a menu segment against items: exact title (case-insensitive) first,
/// then prefix, both ignoring a trailing ellipsis.
private func matchMenuItem(_ segment: String, in items: [AXUIElement]) -> AXUIElement? {
    let query = segment.lowercased().replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespaces)
    func normalize(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespaces)
    }
    let titled = items.compactMap { item -> (AXUIElement, String)? in
        guard let title = axString(item, kAXTitleAttribute), !title.isEmpty else { return nil }
        return (item, normalize(title))
    }
    return titled.first { $0.1 == query }?.0 ?? titled.first { $0.1.hasPrefix(query) }?.0
}

// MARK: - clipboard

func readClipboardImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let pasteboard = NSPasteboard.general
    guard let text = pasteboard.string(forType: .string) else {
        let types = pasteboard.types?.map(\.rawValue).joined(separator: ", ") ?? "none"
        return .text("The clipboard has no plain-text content (types present: \(types)).")
    }
    return .text("Clipboard text (\(text.count) chars):\n\(text)")
}

func writeClipboardImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let text = try args.requireString("text")
    try ArgumentBounds.checkStringLength(text, argument: "text", maximum: ArgumentBounds.maxClipboardCharacters)
    try SafetyPolicy.checkClipboardWrite(confirmed: SafetyPolicy.confirmed(args))
    let focus = FocusChangeTracker.start()
    let pasteboard = NSPasteboard.general

    // clearContents() wipes the user's clipboard before the new value lands; a
    // rejected write would then strand them with an empty clipboard. Capture
    // the prior text and, via a defer guard, restore it on any early exit that
    // did not commit the new value.
    let previous = pasteboard.string(forType: .string)
    var committed = false
    defer {
        if let restore = clipboardRestoreValue(committed: committed, previous: previous) {
            pasteboard.clearContents()
            pasteboard.setString(restore, forType: .string)
        }
    }

    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string) else {
        throw ToolError.failed("The clipboard rejected the write; restored the previous contents.")
    }
    committed = true
    return CallTool.Result.text("Replaced the clipboard with \(text.count) characters. Paste with press_key cmd+v.")
        .withFocusTelemetry(focus.finish(deliveryTier: InputTier.pasteboard.rawValue))
}

/// The clipboard text to restore after a write attempt: nil once the new value
/// has committed (leave it in place), otherwise the prior contents so a failed
/// write never strands the user with an empty clipboard. Pure, unit-tested.
func clipboardRestoreValue(committed: Bool, previous: String?) -> String? {
    committed ? nil : previous
}

// MARK: - wait_for

func waitForImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    let label = args.string("label")
    let role = args.string("role")
    let valueContains = args.string("value_contains")
    guard label != nil || role != nil || valueContains != nil else {
        throw ToolError.invalidArguments("Provide at least one of label, role, or value_contains.")
    }
    let waitForGone = args.bool("gone") ?? false
    let timeout = min(60.0, max(1.0, args.number("timeout_seconds") ?? 10))

    let start = Date()
    let deadline = start.addingTimeInterval(timeout)
    var conditionMet = false
    repeat {
        let window = try? targetWindow(for: app, title: args.string("window_title"))
        let found = window.map { elementExists(in: $0.element, role: role, label: label, valueContains: valueContains) } ?? false
        if found != waitForGone {
            conditionMet = true
            break
        }
        try? await Task.sleep(for: .milliseconds(400))
    } while Date() < deadline

    let what = [
        role.map { "role \($0)" }, label.map { "label \"\($0)\"" }, valueContains.map { "value containing \"\($0)\"" },
    ].compactMap { $0 }.joined(separator: ", ")
    let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
    let note = conditionMet
        ? "Condition met after \(elapsed)s: \(what)\(waitForGone ? " is gone" : " appeared")."
        : "TIMED OUT after \(Int(timeout))s waiting for \(what)\(waitForGone ? " to disappear" : ""). Current state below."
    return try await stateResult(app: app, windowTitle: args.string("window_title"), note: note)
}

/// Lightweight existence search over the live AX tree (bounded depth/breadth).
private func elementExists(
    in root: AXUIElement, role: String?, label: String?, valueContains: String?, depth: Int = 0
) -> Bool {
    if depth <= 14 {
        let matchesRole = role.map { axRole(root).lowercased() == $0.lowercased() } ?? true
        let matchesLabel = label.map { query in
            let texts = [
                axString(root, kAXTitleAttribute), axString(root, kAXDescriptionAttribute),
                axString(root, "AXPlaceholderValue"),
            ]
            return texts.contains { $0?.lowercased().contains(query.lowercased()) ?? false }
        } ?? true
        let matchesValue = valueContains.map {
            axString(root, kAXValueAttribute)?.lowercased().contains($0.lowercased()) ?? false
        } ?? true
        if matchesRole && matchesLabel && matchesValue { return true }
        for child in axElements(root, kAXChildrenAttribute).prefix(150) {
            if elementExists(in: child, role: role, label: label, valueContains: valueContains, depth: depth + 1) {
                return true
            }
        }
    }
    return false
}
#endif
