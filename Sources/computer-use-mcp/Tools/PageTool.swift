 #if os(macOS)
// page — CSS-selector-addressed web interaction for browser/webview surfaces.
//
// JS-capable hosts (Safari/Chromium and Electron with CDP) get DOM probes and
// DOM readback. WKWebView falls back to AX targeting and is deliberately
// downgraded when only AX evidence exists: a successful AX echo is not DOM
// proof.

import Foundation
#if os(Linux)
import FoundationNetworking
#endif
import MCP
#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
#endif

enum PageAction: String {
    case click
    case setText = "set_text"
}

enum PageHostType: String, Equatable {
    case chromium
    case safari
    case electron
    case wkWebView = "wk_webview"
    case unsupported
}

struct PageCoordinateProbe: Equatable {
    let viewportX: Double
    let viewportY: Double
    let contentScreenX: Double
    let contentScreenY: Double
    let devicePixelRatio: Double

    var screenPoint: CGPoint {
        CGPoint(x: contentScreenX + viewportX, y: contentScreenY + viewportY)
    }
}

struct PageDOMSnapshot: Equatable {
    let value: String?
    let text: String?
    let pageSignature: String?

    func differs(from other: PageDOMSnapshot?) -> Bool {
        guard let other else { return false }
        return value != other.value || text != other.text || pageSignature != other.pageSignature
    }
}

struct PageProbe {
    let coordinate: PageCoordinateProbe
    let snapshot: PageDOMSnapshot
}

protocol PageJavaScriptExecuting {
    func evaluate(_ javascript: String, app: ResolvedApp, window: TargetWindow, cdpPort: Int?, targetURLContains: String?) async throws
        -> String
    func insertText(
        _ text: String, selector: String, app: ResolvedApp, window: TargetWindow, cdpPort: Int?, targetURLContains: String?
    ) async throws
}

struct SystemPageJavaScriptExecutor: PageJavaScriptExecuting {
    func evaluate(
        _ javascript: String, app: ResolvedApp, window: TargetWindow, cdpPort: Int?, targetURLContains: String?
    ) async throws -> String {
        switch pageHostType(for: app) {
        case .safari, .chromium:
            return try await runBrowserAppleScript(javascript, app: app, window: window)
        case .electron:
            let port = try await resolveCDPPort(explicit: cdpPort)
            return try await CDPClient(port: port, targetURLContains: targetURLContains).evaluate(javascript)
        case .wkWebView:
            throw ToolError.failed("JavaScript execution is not available for WKWebView apps; using AX fallback when possible.")
        case .unsupported:
            throw ToolError.failed("The page tool does not know how to execute JavaScript in \(app.bundleIdentifier).")
        }
    }

    func insertText(
        _ text: String, selector: String, app: ResolvedApp, window: TargetWindow, cdpPort: Int?, targetURLContains: String?
    ) async throws {
        switch pageHostType(for: app) {
        case .electron:
            let port = try await resolveCDPPort(explicit: cdpPort)
            let client = CDPClient(port: port, targetURLContains: targetURLContains)
            _ = try await client.evaluate("document.querySelector(\(jsonString(selector)))?.focus()")
            try await client.insertText(text)
        case .safari, .chromium:
            let script = pageSetTextJavaScript(selector: selector, text: text)
            _ = try await runBrowserAppleScript(script, app: app, window: window)
        case .wkWebView:
            throw ToolError.failed("JavaScript text entry is not available for WKWebView apps; using AX fallback when possible.")
        case .unsupported:
            throw ToolError.failed("The page tool cannot insert text in \(app.bundleIdentifier).")
        }
    }
}

nonisolated(unsafe) var pageJavaScriptExecutor: PageJavaScriptExecuting = SystemPageJavaScriptExecutor()

func pageImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    let confirmed = SafetyPolicy.confirmed(args)
    try SafetyPolicy.check(app: app, confirmed: confirmed)

    let selector = try args.requireString("selector")
    let action = PageAction(rawValue: args.string("action") ?? PageAction.click.rawValue) ?? .click
    let verifySelector = args.string("verify_selector") ?? selector
    let cdpPort = args.integer("cdp_port")
    let targetURLContains = args.string("target_url_contains")
    let focus = FocusChangeTracker.start()
    let window = try targetWindow(for: app, title: args.string("window_title"))
    let host = pageHostType(for: app)

    switch action {
    case .click:
        try SafetyPolicy.checkClick(label: selector, app: app, confirmed: confirmed)
        return try await pageClick(
            app: app, window: window, selector: selector, verifySelector: verifySelector,
            host: host, args: args, focus: focus, cdpPort: cdpPort, targetURLContains: targetURLContains)
    case .setText:
        guard let text = args.string("text") else {
            throw ToolError.invalidArguments("\"text\" is required when action is set_text.")
        }
        try ArgumentBounds.checkStringLength(text, argument: "text", maximum: ArgumentBounds.maxSetValueCharacters)
        try SafetyPolicy.check(app: app, confirmed: confirmed)
        return try await pageSetText(
            app: app, window: window, selector: selector, text: text, verifySelector: verifySelector,
            host: host, args: args, focus: focus, cdpPort: cdpPort, targetURLContains: targetURLContains)
    }
}

private func pageClick(
    app: ResolvedApp,
    window: TargetWindow,
    selector: String,
    verifySelector: String,
    host: PageHostType,
    args: [String: Value],
    focus: FocusChangeTracker,
    cdpPort: Int?,
    targetURLContains: String?
) async throws -> CallTool.Result {
    if host == .wkWebView || host == .unsupported {
        return try await pageClickAXFallback(
            app: app, window: window, selector: selector, verifySelector: verifySelector,
            args: args, focus: focus, host: host)
    }

    let before = try await pageProbe(selector: selector, verifySelector: verifySelector, app: app, window: window, cdpPort: cdpPort, targetURLContains: targetURLContains)
    let point = before.coordinate.screenPoint
    let context = DeliveryContext(
        pid: app.pid, windowNumber: windowID(for: window.element),
        windowFrame: window.frame, allowGlobalCursor: false)
    let delivery = try deliverClick(at: point, button: .left, clickCount: 1, context: context)
    await AgentCursor.shared.pulse(at: point, targetWindow: context.windowNumber)
    try? await Task.sleep(for: .milliseconds(80))
    let after = try? await pageDOMSnapshot(
        selector: verifySelector, app: app, window: window, cdpPort: cdpPort,
        targetURLContains: targetURLContains)
    let outcome = classifyPageOutcome(
        evidence: .dom, action: .click, beforeDOM: before.snapshot, afterDOM: after,
        axChanged: nil, deliveryTier: delivery.tier.rawValue, host: host)
    let verifier = resolvedPageVerifier(outcome: outcome, tier: delivery.tier.rawValue)
    return try await stateResult(
        app: app, windowTitle: window.title,
        note: "Clicked \(selector) via page DOM coordinates at screen (\(roundedIntegerDescription(point.x)),\(roundedIntegerDescription(point.y))) [\(delivery.tier.rawValue)].",
        screenshot: screenshotDetail(args),
        focusTelemetry: focus.finish(deliveryTier: delivery.tier.rawValue, fallbackReasons: delivery.fallbackReasons),
        verifier: verifier)
}

private func pageSetText(
    app: ResolvedApp,
    window: TargetWindow,
    selector: String,
    text: String,
    verifySelector: String,
    host: PageHostType,
    args: [String: Value],
    focus: FocusChangeTracker,
    cdpPort: Int?,
    targetURLContains: String?
) async throws -> CallTool.Result {
    if host == .wkWebView || host == .unsupported {
        return try await pageSetTextAXFallback(
            app: app, window: window, selector: selector, text: text, verifySelector: verifySelector,
            args: args, focus: focus, host: host)
    }

    let before = try await pageDOMSnapshot(
        selector: verifySelector, app: app, window: window, cdpPort: cdpPort,
        targetURLContains: targetURLContains)
    try await pageJavaScriptExecutor.insertText(
        text, selector: selector, app: app, window: window, cdpPort: cdpPort, targetURLContains: targetURLContains)
    try? await Task.sleep(for: .milliseconds(80))
    let after = try? await pageDOMSnapshot(
        selector: verifySelector, app: app, window: window, cdpPort: cdpPort,
        targetURLContains: targetURLContains)
    let outcome = classifyPageOutcome(
        evidence: .dom, action: .setText, beforeDOM: before, afterDOM: after,
        axChanged: nil, deliveryTier: pageTextDeliveryTier(host: host), host: host, expectedText: text)
    let tier = pageTextDeliveryTier(host: host)
    return try await stateResult(
        app: app, windowTitle: window.title,
        note: "Set text in \(selector) via \(host.rawValue) page scripting.",
        screenshot: screenshotDetail(args),
        focusTelemetry: focus.finish(deliveryTier: tier),
        verifier: resolvedPageVerifier(outcome: outcome, tier: tier))
}

private func pageClickAXFallback(
    app: ResolvedApp,
    window: TargetWindow,
    selector: String,
    verifySelector: String,
    args: [String: Value],
    focus: FocusChangeTracker,
    host: PageHostType
) async throws -> CallTool.Result {
    let target = try findAXElement(selector: selector, in: window.element)
    let before = axFallbackReadbackSignature(selector: verifySelector, in: window.element)
    let point = axFrame(target).map { CGPoint(x: $0.midX, y: $0.midY) }
    let tier: InputTier
    var fallbackReasons: [FallbackReason] = []
    if let pressable = selfOrAncestor(of: target, supporting: kAXPressAction as String) {
        let error = AXUIElementPerformAction(pressable, kAXPressAction as CFString)
        guard error == .success else {
            throw ToolError.failed("AX fallback press failed for \(selector) (\(axErrorDescription(error))).")
        }
        tier = .accessibilityAction
    } else if let point {
        let delivery = try deliverClick(
            at: point, button: .left, clickCount: 1,
            context: DeliveryContext(pid: app.pid, windowNumber: windowID(for: window.element), windowFrame: window.frame, allowGlobalCursor: false))
        tier = delivery.tier
        fallbackReasons = [.axActionUnsupported] + delivery.fallbackReasons
    } else {
        throw ToolError.failed("AX fallback found \(selector), but it has no clickable frame.")
    }
    if let point {
        await AgentCursor.shared.pulse(at: point, targetWindow: windowID(for: window.element))
    }
    try? await Task.sleep(for: .milliseconds(80))
    let after = axFallbackReadbackSignature(selector: verifySelector, in: window.element)
    let outcome = classifyPageOutcome(
        evidence: .axOnly, action: .click, beforeDOM: nil, afterDOM: nil,
        axChanged: before != after, deliveryTier: tier.rawValue, host: host)
    return try await stateResult(
        app: app, windowTitle: window.title,
        note: "Clicked \(selector) through AX fallback [\(tier.rawValue)].",
        screenshot: screenshotDetail(args),
        focusTelemetry: focus.finish(deliveryTier: tier.rawValue, fallbackReasons: fallbackReasons),
        verifier: resolvedPageVerifier(outcome: outcome, tier: tier.rawValue))
}

private func pageSetTextAXFallback(
    app: ResolvedApp,
    window: TargetWindow,
    selector: String,
    text: String,
    verifySelector: String,
    args: [String: Value],
    focus: FocusChangeTracker,
    host: PageHostType
) async throws -> CallTool.Result {
    let target = try findAXElement(selector: selector, in: window.element)
    let readbackTarget = (try? findAXElement(selector: verifySelector, in: window.element)) ?? target
    let before = verifierValuePreview(readbackTarget)
    var settable = DarwinBoolean(false)
    guard
        AXUIElementIsAttributeSettable(target, kAXValueAttribute as CFString, &settable) == .success,
        settable.boolValue
    else {
        let outcome = ActionOutcome.unsupported(
            .unsupported, "AX fallback found \(selector), but it does not accept a direct value.")
        return try await stateResult(
            app: app, windowTitle: window.title,
            note: "\(selector) does not accept a direct AX value; no text was set.",
            screenshot: screenshotDetail(args),
            focusTelemetry: focus.finish(deliveryTier: InputTier.accessibilityAttribute.rawValue),
            verifier: resolvedPageVerifier(outcome: outcome, tier: InputTier.accessibilityAttribute.rawValue))
    }
    let error = AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, text as CFString)
    guard error == .success else {
        throw ToolError.failed("AX fallback set_value failed for \(selector) (\(axErrorDescription(error))).")
    }
    let after = verifierValuePreview(readbackTarget)
    let outcome = classifyPageOutcome(
        evidence: .axOnly, action: .setText, beforeDOM: nil, afterDOM: nil,
        axChanged: before != after, deliveryTier: InputTier.accessibilityAttribute.rawValue,
        host: host, expectedText: text)
    return try await stateResult(
        app: app, windowTitle: window.title,
        note: "Set text in \(selector) through AX fallback.",
        screenshot: screenshotDetail(args),
        focusTelemetry: focus.finish(deliveryTier: InputTier.accessibilityAttribute.rawValue),
        verifier: resolvedPageVerifier(outcome: outcome, tier: InputTier.accessibilityAttribute.rawValue))
}

enum PageEvidenceKind {
    case dom
    case axOnly
}

func classifyPageOutcome(
    evidence: PageEvidenceKind,
    action: PageAction,
    beforeDOM: PageDOMSnapshot?,
    afterDOM: PageDOMSnapshot?,
    axChanged: Bool?,
    deliveryTier: String,
    host: PageHostType,
    expectedText: String? = nil
) -> ActionOutcome {
    var verification = ActionVerification()
    verification.beforeValuePreview = beforeDOM?.value ?? beforeDOM?.text
    verification.afterValuePreview = afterDOM?.value ?? afterDOM?.text
    verification.renderedTextChanged = axChanged
    verification.notes.append("page.host=\(host.rawValue)")

    switch evidence {
    case .dom:
        guard let afterDOM else {
            return .ambiguous(.verification, "The page action ran, but DOM verification could not be read afterward.", verification)
        }
        if action == .setText, let expectedText {
            if pageSnapshot(afterDOM, matchesExpectedText: expectedText) {
                verification.notes.append("DOM readback matched the requested text.")
                return .success("DOM verification confirmed the requested page text.", verification)
            }
            return .effectNotVerified(
                .verification,
                "DOM verification did not confirm the requested text after set_text.", verification)
        }
        if afterDOM.differs(from: beforeDOM) {
            verification.notes.append("DOM readback changed after the page action.")
            return .success("DOM verification confirmed the page changed.", verification)
        }
        if isDroppableBackgroundDeliveryTier(deliveryTier) {
            return .effectNotVerified(
                .transport,
                "No DOM change was observed; the background click may have been dropped.", verification)
        }
        return .effectNotVerified(.verification, "No DOM change was observed after the page action.", verification)
    case .axOnly:
        verification.notes.append("Only AX fallback evidence was available; DOM verification was not possible.")
        if axChanged == true {
            return .effectNotVerified(
                .verification,
                "AX fallback observed a change, but DOM verification was unavailable for this host.", verification)
        }
        if isDroppableBackgroundDeliveryTier(deliveryTier) {
            return .effectNotVerified(
                .transport,
                "No confirming DOM change was observed; the fallback event may have been dropped.", verification)
        }
        return .effectNotVerified(
            .verification,
            "No confirming DOM change was observed after the AX fallback action.", verification)
    }
}

private func pageSnapshot(_ snapshot: PageDOMSnapshot, matchesExpectedText expectedText: String) -> Bool {
    if let value = snapshot.value {
        return value == expectedText
    }
    guard let text = snapshot.text else { return false }
    return expectedText.isEmpty ? text.isEmpty : text.contains(expectedText)
}

private func resolvedPageVerifier(outcome: ActionOutcome, tier: String) -> ActionVerifier {
    ActionVerifier(
        family: .click, intent: .activate, deliveryTier: tier,
        dispatchSucceeded: outcome.classification != .unsupported,
        hasTargetElement: false, snapshotElement: nil, resolved: outcome)
}

func pageProbe(
    selector: String,
    verifySelector: String,
    app: ResolvedApp,
    window: TargetWindow,
    cdpPort: Int?,
    targetURLContains: String?
) async throws -> PageProbe {
    let raw = try await pageJavaScriptExecutor.evaluate(
        pageProbeJavaScript(selector: selector, verifySelector: verifySelector),
        app: app, window: window, cdpPort: cdpPort, targetURLContains: targetURLContains)
    return try parsePageProbe(raw)
}

func pageDOMSnapshot(
    selector: String,
    app: ResolvedApp,
    window: TargetWindow,
    cdpPort: Int?,
    targetURLContains: String?
) async throws -> PageDOMSnapshot {
    let raw = try await pageJavaScriptExecutor.evaluate(
        pageSnapshotJavaScript(selector: selector),
        app: app, window: window, cdpPort: cdpPort, targetURLContains: targetURLContains)
    return try parsePageDOMSnapshot(raw)
}

func parsePageProbe(_ raw: String) throws -> PageProbe {
    let object = try parseJSONObject(raw)
    let coordinate = PageCoordinateProbe(
        viewportX: try requiredDouble(object, "vx", raw: raw),
        viewportY: try requiredDouble(object, "vy", raw: raw),
        contentScreenX: try requiredDouble(object, "sx", raw: raw),
        contentScreenY: try requiredDouble(object, "sy", raw: raw),
        devicePixelRatio: optionalPositiveDouble(object, "dpr") ?? 1.0)
    return PageProbe(coordinate: coordinate, snapshot: parseSnapshotObject(object))
}

func parsePageDOMSnapshot(_ raw: String) throws -> PageDOMSnapshot {
    parseSnapshotObject(try parseJSONObject(raw))
}

private func parseSnapshotObject(_ object: [String: Any]) -> PageDOMSnapshot {
    PageDOMSnapshot(
        value: object["value"] as? String,
        text: object["text"] as? String,
        pageSignature: object["pageSignature"] as? String)
}

private func parseJSONObject(_ raw: String) throws -> [String: Any] {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let first = try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])
    let unwrapped: Any
    if let string = first as? String,
        let data = string.data(using: .utf8),
        let nested = try? JSONSerialization.jsonObject(with: data)
    {
        unwrapped = nested
    } else {
        unwrapped = first
    }
    guard let object = unwrapped as? [String: Any] else {
        throw ToolError.failed("page: JavaScript returned non-object JSON: \(raw)")
    }
    return object
}

private func requiredDouble(_ object: [String: Any], _ key: String, raw: String) throws -> Double {
    guard let number = object[key] as? NSNumber else {
        throw ToolError.failed("page: JavaScript probe missing numeric \(key): \(raw)")
    }
    let value = number.doubleValue
    guard value.isFinite else {
        throw ToolError.failed("page: JavaScript probe returned non-finite \(key): \(raw)")
    }
    return value
}

private func optionalPositiveDouble(_ object: [String: Any], _ key: String) -> Double? {
    guard let number = object[key] as? NSNumber else { return nil }
    let value = number.doubleValue
    return value.isFinite && value > 0 ? value : nil
}

private func pageProbeJavaScript(selector: String, verifySelector: String) -> String {
    """
    (function() {
      var selector = \(jsonString(selector));
      var verifySelector = \(jsonString(verifySelector));
      var el = document.querySelector(selector);
      if (!el) { throw new Error("element_not_found:" + selector); }
      var verify = document.querySelector(verifySelector) || el;
      var r = el.getBoundingClientRect();
      var chromeX = Math.max(0, (window.outerWidth - window.innerWidth) / 2);
      var chromeY = Math.max(0, window.outerHeight - window.innerHeight - chromeX);
      return JSON.stringify({
        vx: r.left + r.width / 2,
        vy: r.top + r.height / 2,
        sx: window.screenX + chromeX,
        sy: window.screenY + chromeY,
        dpr: window.devicePixelRatio || 1,
        value: valueOf(verify),
        text: textOf(verify),
        pageSignature: signature()
      });
      function valueOf(node) { return node && "value" in node ? String(node.value) : null; }
      function textOf(node) { return node ? String(node.innerText || node.textContent || "") : null; }
      function signature() {
        return String(document.documentElement.innerText || document.documentElement.textContent || "") +
          "|" + Array.from(document.querySelectorAll("input,textarea,select")).map(valueOf).join("|");
      }
    })();
    """
}

private func pageSnapshotJavaScript(selector: String) -> String {
    """
    (function() {
      var selector = \(jsonString(selector));
      var el = document.querySelector(selector);
      if (!el) { throw new Error("element_not_found:" + selector); }
      return JSON.stringify({
        value: "value" in el ? String(el.value) : null,
        text: String(el.innerText || el.textContent || ""),
        pageSignature: String(document.documentElement.innerText || document.documentElement.textContent || "") +
          "|" + Array.from(document.querySelectorAll("input,textarea,select")).map(function(node) {
            return "value" in node ? String(node.value) : "";
          }).join("|")
      });
    })();
    """
}

private func pageSetTextJavaScript(selector: String, text: String) -> String {
    """
    (function() {
      var el = document.querySelector(\(jsonString(selector)));
      if (!el) { throw new Error("element_not_found:" + \(jsonString(selector))); }
      el.focus();
      if ("value" in el) {
        el.value = \(jsonString(text));
      } else {
        el.textContent = \(jsonString(text));
      }
      el.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: \(jsonString(text)) }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
      return JSON.stringify({ ok: true });
    })();
    """
}

func pageHostType(for app: ResolvedApp, frameworks: [String]? = nil) -> PageHostType {
    let bundle = app.bundleIdentifier.lowercased()
    if bundle == "com.apple.safari" || bundle == "com.apple.safaritechnologypreview" {
        return .safari
    }
    if chromiumBrowserBundleIDs.contains(bundle) || bundle.contains("chromium") {
        return .chromium
    }
    let frameworkNames = frameworks ?? frameworkNamesForApp(pid: app.pid)
    if frameworkNames.contains(where: { $0.lowercased().contains("electron framework") }) {
        return .electron
    }
    if frameworkNames.contains(where: { $0.lowercased().contains("webkit.framework") }) {
        return .wkWebView
    }
    if appLooksLikeWebRenderer(pid: app.pid) {
        return .electron
    }
    return .wkWebView
}

private let chromiumBrowserBundleIDs: Set<String> = [
    "com.google.chrome",
    "com.google.chrome.canary",
    "com.microsoft.edgemac",
    "com.brave.browser",
    "org.chromium.chromium",
    "com.vivaldi.vivaldi",
    "com.operasoftware.opera",
]

private func frameworkNamesForApp(pid: pid_t) -> [String] {
    guard let bundleURL = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return [] }
    let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks").path
    return (try? FileManager.default.contentsOfDirectory(atPath: frameworks)) ?? []
}

private func pageTextDeliveryTier(host: PageHostType) -> String {
    host == .electron ? "cdp-input-insert-text" : "apple-events-javascript"
}

private func runBrowserAppleScript(_ javascript: String, app: ResolvedApp, window: TargetWindow) async throws -> String {
    let script = try browserAppleScript(
        javascript, app: app, host: pageHostType(for: app),
        windowTitle: axString(window.element, kAXTitleAttribute) ?? window.title,
        windowFrame: window.frame)
    do {
        return try await runProcess("/usr/bin/osascript", arguments: ["-e", script])
    } catch {
        throw ToolError.failed(
            "JavaScript Apple Events failed for \(app.name). Enable 'Allow JavaScript from Apple Events' "
                + "in the browser, or use a host with CDP. Underlying error: \(error)")
    }
}

func browserAppleScript(
    _ javascript: String, app: ResolvedApp, host: PageHostType, windowTitle: String?, windowFrame: CGRect? = nil
) throws -> String {
    let target = browserWindowTargetAppleScript(windowTitle: windowTitle, windowFrame: windowFrame)
    switch host {
    case .safari:
        return """
        tell application id "\(app.bundleIdentifier)"
        \(target)
          do JavaScript \(appleScriptString(javascript)) in current tab of targetWindow
        end tell
        """
    case .chromium:
        return """
        tell application id "\(app.bundleIdentifier)"
        \(target)
          execute javascript \(appleScriptString(javascript)) in active tab of targetWindow
        end tell
        """
    default:
        throw ToolError.failed("Apple Events JavaScript is unsupported for \(app.bundleIdentifier).")
    }
}

private func browserWindowTargetAppleScript(windowTitle: String?, windowFrame: CGRect?) -> String {
    let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let title, !title.isEmpty {
        return """
          if not (exists window 1) then error "No browser window is open"
          set targetWindow to missing value
        \(browserWindowTitleMatchAppleScript(title, windowFrame: windowFrame))
          if targetWindow is missing value then error "No browser window matching the resolved target title."
        """
    }
    if let windowFrame {
        return """
          if not (exists window 1) then error "No browser window is open"
          set targetWindow to missing value
        \(browserWindowFrameMatchAppleScript(windowFrame))
          if targetWindow is missing value then error "No browser window matching the resolved target frame."
        """
    }
    return """
      if not (exists window 1) then error "No browser window is open"
      set targetWindow to front window
    """
}

private func browserWindowFrameMatchAppleScript(_ frame: CGRect) -> String {
    """
    \(browserWindowFramePreambleAppleScript(frame))
      set frameMatches to {}
      repeat with candidate in windows
        try
          set candidateBounds to bounds of candidate
          if \(browserWindowFrameConditionAppleScript()) then set end of frameMatches to contents of candidate
        end try
      end repeat
      if (count of frameMatches) is 1 then
        set targetWindow to item 1 of frameMatches
      else if (count of frameMatches) > 1 then
        error "Browser window frame matched multiple windows; target is ambiguous."
      end if
    """
}

private func browserWindowTitleMatchAppleScript(_ title: String, windowFrame: CGRect?) -> String {
    let quotedTitle = appleScriptString(title)
    let framePreamble = windowFrame.map(browserWindowFramePreambleAppleScript) ?? ""
    return """
      set wantedTitle to \(quotedTitle)
    \(framePreamble)
      set exactTitleMatches to {}
      repeat with candidate in windows
        try
          set candidateTitle to name of candidate as text
          if candidateTitle is wantedTitle then set end of exactTitleMatches to contents of candidate
        end try
      end repeat
      \(browserWindowChooseMatchAppleScript("exactTitleMatches", windowFrame: windowFrame))
      if targetWindow is missing value then
        set partialTitleMatches to {}
        repeat with candidate in windows
          try
            set candidateTitle to name of candidate as text
            if candidateTitle contains wantedTitle then set end of partialTitleMatches to contents of candidate
          end try
        end repeat
        \(browserWindowChooseMatchAppleScript("partialTitleMatches", windowFrame: windowFrame))
      end if
    """
}

private func browserWindowFramePreambleAppleScript(_ frame: CGRect) -> String {
    """
      set targetLeft to \(roundedIntegerDescription(frame.minX))
      set targetTop to \(roundedIntegerDescription(frame.minY))
      set targetRight to \(roundedIntegerDescription(frame.maxX))
      set targetBottom to \(roundedIntegerDescription(frame.maxY))
    """
}

private func browserWindowChooseMatchAppleScript(_ matchList: String, windowFrame: CGRect?) -> String {
    if windowFrame == nil {
        return """
          if (count of \(matchList)) is 1 then
            set targetWindow to item 1 of \(matchList)
          else if (count of \(matchList)) > 1 then
            error "Browser window title matched multiple windows; target is ambiguous."
          end if
        """
    }
    return """
      if (count of \(matchList)) is 1 then
        set targetWindow to item 1 of \(matchList)
      else if (count of \(matchList)) > 1 then
        set frameMatches to {}
        repeat with candidate in \(matchList)
          try
            set candidateBounds to bounds of candidate
            if \(browserWindowFrameConditionAppleScript()) then set end of frameMatches to contents of candidate
          end try
        end repeat
        if (count of frameMatches) is 1 then
          set targetWindow to item 1 of frameMatches
        else if (count of frameMatches) > 1 then
          error "Browser window title and frame matched multiple windows; target is ambiguous."
        else
          error "Browser window title matched multiple windows; no match had the resolved frame."
        end if
      end if
    """
}

private func browserWindowFrameConditionAppleScript() -> String {
    """
    (item 1 of candidateBounds as integer) is targetLeft and ¬
              (item 2 of candidateBounds as integer) is targetTop and ¬
              (item 3 of candidateBounds as integer) is targetRight and ¬
              (item 4 of candidateBounds as integer) is targetBottom
    """
}

private func runProcess(_ path: String, arguments: [String]) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.terminationHandler = { process in
            let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if process.terminationStatus == 0 {
                continuation.resume(returning: stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                continuation.resume(throwing: ToolError.failed(stderr.isEmpty ? stdout : stderr))
            }
        }
        do {
            try process.run()
        } catch {
            continuation.resume(throwing: error)
        }
    }
}

private func resolveCDPPort(explicit: Int?) async throws -> Int {
    if let explicit { return explicit }
    for port in [9222, 9223, 9229, 9230] {
        if (try? await CDPClient(port: port, targetURLContains: nil).hasPageTarget()) == true {
            return port
        }
    }
    throw ToolError.failed(
        "No Chrome DevTools Protocol page target found. Electron page text entry requires a running "
            + "remote-debugging port; pass cdp_port if the app exposes one.")
}

private struct CDPClient {
    let port: Int
    let targetURLContains: String?

    func hasPageTarget() async throws -> Bool {
        !(try await pageTargets()).isEmpty
    }

    func evaluate(_ javascript: String) async throws -> String {
        let socket = try await webSocketURL()
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: socket)
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
        let params: [String: Any] = ["expression": javascript, "returnByValue": true, "awaitPromise": true]
        let response = try await sendCDP("Runtime.evaluate", params: params, task: task, id: 1)
        if let exception = response["exceptionDetails"] {
            throw ToolError.failed("CDP Runtime.evaluate failed: \(exception)")
        }
        if let result = response["result"] as? [String: Any] {
            if let value = result["value"] { return "\(value)" }
            if let description = result["description"] as? String { return description }
        }
        return ""
    }

    func insertText(_ text: String) async throws {
        let socket = try await webSocketURL()
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: socket)
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
        _ = try await sendCDP("Input.insertText", params: ["text": text], task: task, id: 1)
    }

    private func sendCDP(_ method: String, params: [String: Any], task: URLSessionWebSocketTask, id: Int) async throws -> [String: Any] {
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let message = String(data: data, encoding: .utf8) ?? "{}"
        try await task.send(.string(message))
        while true {
            let response = try await task.receive()
            let text: String
            switch response {
            case .string(let value): text = value
            case .data(let data): text = String(data: data, encoding: .utf8) ?? ""
            @unknown default: continue
            }
            guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                continue
            }
            guard object["id"] as? Int == id else { continue }
            if let error = object["error"] {
                throw ToolError.failed("CDP \(method) failed: \(error)")
            }
            return object["result"] as? [String: Any] ?? [:]
        }
    }

    private func webSocketURL() async throws -> URL {
        let target = try selectCDPPageTarget(
            try await pageTargets(), targetURLContains: targetURLContains, port: port)
        guard let raw = target?["webSocketDebuggerUrl"] as? String, let url = URL(string: raw) else {
            throw ToolError.failed("No CDP page target with a websocket URL on port \(port).")
        }
        return url
    }

    private func pageTargets() async throws -> [[String: Any]] {
        let url = URL(string: "http://127.0.0.1:\(port)/json")!
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.filter { $0["type"] as? String == "page" }
    }
}

func selectCDPPageTarget(_ targets: [[String: Any]], targetURLContains: String?, port: Int) throws -> [String: Any]? {
    guard let hint = targetURLContains?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty else {
        return targets.first
    }
    guard let target = targets.first(where: { ($0["url"] as? String)?.localizedCaseInsensitiveContains(hint) == true }) else {
        throw ToolError.failed("No CDP page target URL containing \(hint) on port \(port).")
    }
    return target
}

private func findAXElement(selector: String, in root: AXUIElement) throws -> AXUIElement {
    let query = AXSelectorQuery(selector)
    var stack = axWebSearchRoots(in: root)
    var visited = 0
    while let element = stack.popLast() {
        visited += 1
        if visited > 5000 { break }
        if query.matches(element) { return element }
        stack.append(contentsOf: axElements(element, kAXChildrenAttribute).reversed())
    }
    throw ToolError.failed("No AX fallback element matched selector \(selector).")
}

private func axWebSearchRoots(in root: AXUIElement) -> [AXUIElement] {
    let webAreas = axDescendants(of: root, limit: 5000).filter { axRole($0) == "AXWebArea" }
    return webAreas.isEmpty ? [root] : Array(webAreas.reversed())
}

struct AXSelectorQuery {
    let raw: String
    let id: String?
    let text: String
    let roleHint: String?

    init(_ selector: String) {
        raw = selector
        if selector.hasPrefix("#") {
            id = String(selector.dropFirst())
        } else {
            id = nil
        }
        let base = id ?? selector
        let tokens = base.replacingOccurrences(of: #"[#.\[\]="'_:-]+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .map { String($0).lowercased() }
            .filter { !["web", "app", "field", "input", "text", "label"].contains($0) }
        text = tokens.joined(separator: " ")
        roleHint = tokens.contains("button") ? "AXButton" : nil
    }

    func matches(_ element: AXUIElement) -> Bool {
        matches(
            AXSelectorFacts(
                role: axRole(element),
                label: clickableLabel(element),
                value: axString(element, kAXValueAttribute),
                axIdentifier: axString(element, "AXIdentifier"),
                domIdentifier: axString(element, "AXDOMIdentifier")))
    }

    func matches(_ facts: AXSelectorFacts) -> Bool {
        if let id, facts.domIdentifier == id { return true }
        if let id, facts.axIdentifier == id { return true }
        if let roleHint, facts.role != roleHint { return false }
        let haystack = [
            facts.label,
            facts.value,
            facts.axIdentifier,
            facts.domIdentifier,
        ].compactMap { $0?.lowercased() }.joined(separator: " ")
        if let id, haystack.contains(id.lowercased()) { return true }
        guard !text.isEmpty else { return false }
        return text.split(separator: " ").allSatisfy { haystack.contains($0) }
    }
}

struct AXSelectorFacts {
    let role: String
    let label: String?
    let value: String?
    let axIdentifier: String?
    let domIdentifier: String?
}

private func axFallbackReadbackSignature(selector: String, in root: AXUIElement) -> String {
    guard let target = try? findAXElement(selector: selector, in: root) else {
        return axElementSignature(root)
    }
    return axElementSignature(target)
}

private func axElementSignature(_ root: AXUIElement) -> String {
    var lines: [String] = []
    for element in [root] + axDescendants(of: root, limit: 1000) {
        lines.append(
            [
                axRole(element),
                clickableLabel(element),
                axString(element, kAXValueAttribute),
                axString(element, "AXDOMIdentifier"),
            ]
                .compactMap { $0 }
                .joined(separator: ":"))
    }
    return lines.joined(separator: "\n")
}

private func axDescendants(of root: AXUIElement, limit: Int) -> [AXUIElement] {
    var descendants: [AXUIElement] = []
    var stack = Array(axElements(root, kAXChildrenAttribute).reversed())
    while let element = stack.popLast(), descendants.count < limit {
        descendants.append(element)
        stack.append(contentsOf: axElements(element, kAXChildrenAttribute).reversed())
    }
    return descendants
}

func jsonString(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [value])
    let encoded = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
    return String(encoded.dropFirst().dropLast())
}

private func appleScriptString(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}
#endif
