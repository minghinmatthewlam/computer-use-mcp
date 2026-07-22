// In-service URL policy for browser computer use.
//
// The server, not the calling agent, decides whether a browser page may be
// acted on: before delivering any app-scoped mutating action to a known
// browser, the current URL is read from the accessibility tree (AXWebArea's
// AXURL) and checked against the policy. url_deny patterns block the action
// outright — confirm does not override them. url_confirm patterns (plus a
// small built-in list for payment pages) require confirm:true per action.
// Substring match, case-insensitive. open_url applies the same patterns to
// its URL argument directly.

import Foundation
import MCP
#if os(macOS)
import ApplicationServices
#endif

let browserBundleIdentifiers: Set<String> = [
    "com.apple.safari", "com.apple.safaritechnologypreview",
    "com.google.chrome", "com.google.chrome.canary", "com.google.chrome.beta",
    "com.google.chrome.dev", "org.mozilla.firefox", "com.microsoft.edgemac",
    "com.brave.browser", "com.vivaldi.vivaldi", "com.operasoftware.opera",
    "company.thebrowser.browser", "company.thebrowser.dia",
]

func isBrowserApp(bundleIdentifier: String) -> Bool {
    browserBundleIdentifiers.contains(bundleIdentifier.lowercased())
}

enum URLPolicyDecision: Equatable {
    case allow
    case requireConfirm(String)
    case deny(String)
}

/// Pure policy decision, separated from AX/config state for tests.
/// A nil URL fails closed (confirm) whenever any deny/confirm pattern
/// exists — including the built-in payment-page list — so protection does
/// not evaporate when the URL cannot be read. `hasExplicitPolicy` remains
/// a caller override that also forces the fail-closed path.
func urlPolicyDecision(
    url: String?,
    denyPatterns: [String],
    confirmPatterns: [String],
    hasExplicitPolicy: Bool
) -> URLPolicyDecision {
    guard let url = url?.lowercased() else {
        let hasAnyPolicy = hasExplicitPolicy
            || denyPatterns.contains(where: { !$0.isEmpty })
            || confirmPatterns.contains(where: { !$0.isEmpty })
        return hasAnyPolicy
            ? .requireConfirm(
                "the browser's current URL could not be read, so the configured URL policy cannot be checked")
            : .allow
    }
    if let hit = denyPatterns.first(where: { !$0.isEmpty && url.contains($0) }) {
        return .deny("the URL matches the deny pattern \"\(hit)\"")
    }
    if let hit = confirmPatterns.first(where: { !$0.isEmpty && url.contains($0) }) {
        return .requireConfirm("the URL matches the sensitive pattern \"\(hit)\"")
    }
    return .allow
}

/// One authoring point for the hard-block wording, shared by the browser
/// action gate and open_url.
func urlDenyMessage(_ reason: String) -> String {
    "Denied by URL policy: \(reason). This stays blocked regardless of confirm; "
        + "adjust the url_deny configuration if it should be allowed."
}

enum URLPolicy {
    /// Built-in sensitive patterns (payment surfaces). Extend with
    /// url_confirm; disable with no_safety.
    static let defaultConfirmPatterns = ["checkout", "payment", "paypal.com", "banking"]

    // Config cannot change mid-process; read once.
    static let denyPatterns: [String] = Config.list("url_deny")
    static let confirmPatterns: [String] = defaultConfirmPatterns + Config.list("url_confirm")
    /// True when any deny/confirm pattern exists (built-ins count). An
    /// unreadable URL must fail closed against this, not silently allow.
    static let hasExplicitPolicy: Bool =
        !denyPatterns.isEmpty || !confirmPatterns.isEmpty

    /// Gate an app-scoped mutating tool call. Returns nil when clear to act,
    /// or the error message to send back.
    static func check(toolName: String, arguments: [String: Value]) -> String? {
        guard SafetyPolicy.isEnabled, appScopedToolNames.contains(toolName) else { return nil }
        guard let appName = arguments.string("app"),
            let app = try? resolveApp(appName),
            isBrowserApp(bundleIdentifier: app.bundleIdentifier)
        else { return nil }

        switch urlPolicyDecision(
            url: currentBrowserURL(app: app),
            denyPatterns: denyPatterns,
            confirmPatterns: confirmPatterns,
            hasExplicitPolicy: hasExplicitPolicy
        ) {
        case .allow:
            return nil
        case .deny(let reason):
            return urlDenyMessage(reason)
        case .requireConfirm(let reason):
            guard !SafetyPolicy.confirmed(arguments) else { return nil }
            return SafetyError(reason: reason + ".").description
        }
    }
}

/// URL of the page in the app's front window, from the first AXWebArea's
/// AXURL. Depth-bounded DFS: browser web areas sit a few levels below the
/// window, above the page content.
func currentBrowserURL(app: ResolvedApp) -> String? {
    guard let window = try? targetWindow(for: app, title: nil) else { return nil }
    return webAreaURL(under: window.element)
}

private func webAreaURL(under element: AXUIElement, depth: Int = 0) -> String? {
    guard depth < 12 else { return nil }
    if axRole(element) == "AXWebArea" {
        return axString(element, "AXURL")
    }
    for child in axElements(element, kAXChildrenAttribute) {
        if let url = webAreaURL(under: child, depth: depth + 1) {
            return url
        }
    }
    return nil
}
