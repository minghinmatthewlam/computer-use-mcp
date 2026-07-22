#if os(macOS)
import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import computer_use_mcp

private struct MockPageJavaScriptExecutor: PageJavaScriptExecuting {
    let response: String

    func evaluate(
        _ javascript: String, app: ResolvedApp, window: TargetWindow, cdpPort: Int?, targetURLContains: String?
    ) async throws -> String {
        response
    }

    func insertText(
        _ text: String, selector: String, app: ResolvedApp, window: TargetWindow, cdpPort: Int?, targetURLContains: String?
    ) async throws {}
}

@Suite struct PageToolTests {
    private let app = ResolvedApp(pid: 123, name: "TestApp", bundleIdentifier: "com.example.TestApp")

    @Test func selectorProbeConvertsViewportToScreenCoordinates() throws {
        let raw = """
        {"vx":15,"vy":25,"sx":100,"sy":200,"dpr":2,"value":"before","text":"Before","pageSignature":"Before|"}
        """
        let probe = try parsePageProbe(raw)
        #expect(probe.coordinate.screenPoint == CGPoint(x: 115, y: 225))
        #expect(probe.snapshot.value == "before")
        #expect(probe.snapshot.text == "Before")
    }

    @Test func selectorProbeAcceptsAppleScriptStringWrappedJSON() throws {
        let raw = #""{\"vx\":1,\"vy\":2,\"sx\":3,\"sy\":4,\"dpr\":1,\"text\":\"ok\",\"pageSignature\":\"ok|\"}""#
        let probe = try parsePageProbe(raw)
        #expect(probe.coordinate.screenPoint == CGPoint(x: 4, y: 6))
        #expect(probe.snapshot.text == "ok")
    }

    @Test func selectorProbeUsesMockedJavaScriptBoundary() async throws {
        let previous = pageJavaScriptExecutor
        pageJavaScriptExecutor = MockPageJavaScriptExecutor(
            response: #"{"vx":5,"vy":6,"sx":7,"sy":8,"dpr":1,"text":"mocked","pageSignature":"mocked|"}"#)
        defer { pageJavaScriptExecutor = previous }

        let window = TargetWindow(
            element: AXUIElementCreateApplication(0), title: "Test",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let probe = try await pageProbe(
            selector: "#thing", verifySelector: "#thing", app: app, window: window,
            cdpPort: nil, targetURLContains: nil)
        #expect(probe.snapshot.text == "mocked")
        #expect(probe.coordinate.screenPoint == CGPoint(x: 12, y: 14))
    }

    @Test func hostRoutingDetectsSafariChromiumElectronAndWK() {
        #expect(pageHostType(for: appWithBundle("com.apple.Safari"), frameworks: []) == .safari)
        #expect(pageHostType(for: appWithBundle("com.google.Chrome"), frameworks: []) == .chromium)
        #expect(pageHostType(for: app, frameworks: ["Electron Framework.framework"]) == .electron)
        #expect(pageHostType(for: app, frameworks: ["WebKit.framework"]) == .wkWebView)
    }

    @Test func axSelectorMatchesWebKitDOMIdentifierForIDSelector() {
        let query = AXSelectorQuery("#web-mutate-button")
        let facts = AXSelectorFacts(
            role: "AXButton", label: "Mutate DOM", value: nil,
            axIdentifier: nil, domIdentifier: "web-mutate-button")
        #expect(query.matches(facts))
    }

    @Test func axSelectorMatchesVerifySelectorDOMIdentifier() {
        let query = AXSelectorQuery("#mutable")
        let facts = AXSelectorFacts(
            role: "AXStaticText", label: nil, value: "unmutated",
            axIdentifier: nil, domIdentifier: "mutable")
        #expect(query.matches(facts))
    }

    @Test func axSelectorKeepsAXIdentifierAndLabelHeuristicsAsFallbacks() {
        let idQuery = AXSelectorQuery("#native-button")
        let idFacts = AXSelectorFacts(
            role: "AXButton", label: nil, value: nil,
            axIdentifier: "native-button", domIdentifier: nil)
        #expect(idQuery.matches(idFacts))

        let labelQuery = AXSelectorQuery("#mutate-dom")
        let labelFacts = AXSelectorFacts(
            role: "AXButton", label: "Mutate DOM", value: nil,
            axIdentifier: nil, domIdentifier: nil)
        #expect(labelQuery.matches(labelFacts))
    }

    @Test func domVerifiedMutationIsSuccess() {
        let before = PageDOMSnapshot(value: nil, text: "unmutated", pageSignature: "unmutated|")
        let after = PageDOMSnapshot(value: nil, text: "mutated", pageSignature: "mutated|")
        let outcome = classifyPageOutcome(
            evidence: .dom, action: .click, beforeDOM: before, afterDOM: after,
            axChanged: nil, deliveryTier: InputTier.perWindow.rawValue, host: .chromium)
        #expect(outcome.classification == .success)
        #expect(outcome.failureDomain == nil)
    }

    @Test func domUnchangedAfterDroppableClickIsTransportFailure() {
        let before = PageDOMSnapshot(value: nil, text: "same", pageSignature: "same|")
        let outcome = classifyPageOutcome(
            evidence: .dom, action: .click, beforeDOM: before, afterDOM: before,
            axChanged: nil, deliveryTier: InputTier.perPid.rawValue, host: .chromium)
        #expect(outcome.classification == .effectNotVerified)
        #expect(outcome.failureDomain == .transport)
    }

    @Test func axOnlyChangedEvidenceDowngradesToEffectNotVerified() {
        let outcome = classifyPageOutcome(
            evidence: .axOnly, action: .click, beforeDOM: nil, afterDOM: nil,
            axChanged: true, deliveryTier: InputTier.accessibilityAction.rawValue, host: .wkWebView)
        #expect(outcome.classification == .effectNotVerified)
        #expect(outcome.failureDomain == .verification)
        #expect(outcome.verification?.notes.contains("Only AX fallback evidence was available; DOM verification was not possible.") == true)
    }

    @Test func setTextRequiresExpectedDOMReadback() {
        let before = PageDOMSnapshot(value: "", text: nil, pageSignature: "|")
        let after = PageDOMSnapshot(value: "hello", text: nil, pageSignature: "|hello")
        let outcome = classifyPageOutcome(
            evidence: .dom, action: .setText, beforeDOM: before, afterDOM: after,
            axChanged: nil, deliveryTier: "apple-events-javascript", host: .safari,
            expectedText: "hello")
        #expect(outcome.classification == .success)
    }

    @Test func setTextRejectsDOMChangeWithoutExpectedReadback() {
        let before = PageDOMSnapshot(value: "old", text: nil, pageSignature: "|old")
        let after = PageDOMSnapshot(value: "sanitized", text: nil, pageSignature: "|sanitized")
        let outcome = classifyPageOutcome(
            evidence: .dom, action: .setText, beforeDOM: before, afterDOM: after,
            axChanged: nil, deliveryTier: "apple-events-javascript", host: .safari,
            expectedText: "hello")
        #expect(outcome.classification == .effectNotVerified)
        #expect(outcome.failureDomain == .verification)
    }

    @Test func setTextClearingNonValueElementRequiresEmptyTextReadback() {
        let before = PageDOMSnapshot(value: nil, text: "old", pageSignature: "old|")
        let after = PageDOMSnapshot(value: nil, text: "old", pageSignature: "old|")
        let outcome = classifyPageOutcome(
            evidence: .dom, action: .setText, beforeDOM: before, afterDOM: after,
            axChanged: nil, deliveryTier: "apple-events-javascript", host: .safari,
            expectedText: "")
        #expect(outcome.classification == .effectNotVerified)
        #expect(outcome.failureDomain == .verification)
    }

    @Test func cdpTargetHintMustMatch() throws {
        let targets: [[String: Any]] = [
            ["url": "https://example.test/page", "webSocketDebuggerUrl": "ws://127.0.0.1/devtools/page/1"]
        ]
        #expect(try selectCDPPageTarget(targets, targetURLContains: "example", port: 9222)?["url"] as? String == "https://example.test/page")
        #expect(throws: (any Error).self) {
            _ = try selectCDPPageTarget(targets, targetURLContains: "missing", port: 9222)
        }
    }

    @Test func browserAppleScriptTargetsResolvedWindowTitle() throws {
        let script = try browserAppleScript(
            "1 + 1", app: appWithBundle("com.apple.Safari"), host: .safari, windowTitle: "Target Page")
        #expect(script.contains("set wantedTitle to \"Target Page\""))
        #expect(script.contains("current tab of targetWindow"))
        #expect(!script.contains("current tab of front window"))
    }

    @Test func browserAppleScriptCanTargetResolvedWindowFrame() throws {
        let script = try browserAppleScript(
            "1 + 1", app: appWithBundle("com.google.Chrome"), host: .chromium,
            windowTitle: nil, windowFrame: CGRect(x: 10, y: 20, width: 300, height: 400))
        #expect(script.contains("set targetLeft to 10"))
        #expect(script.contains("set targetBottom to 420"))
        #expect(script.contains("active tab of targetWindow"))
    }

    private func appWithBundle(_ bundleIdentifier: String) -> ResolvedApp {
        ResolvedApp(pid: 123, name: "TestApp", bundleIdentifier: bundleIdentifier)
    }
}
#endif
