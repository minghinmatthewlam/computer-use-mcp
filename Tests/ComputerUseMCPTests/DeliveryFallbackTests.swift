#if os(macOS)
import CoreGraphics
#endif
import Foundation
import Testing

@testable import computer_use_mcp

@Suite struct DeliveryFallbackTests {
    private func context(windowNumber: CGWindowID?, windowFrame: CGRect?) -> DeliveryContext {
        DeliveryContext(pid: 1, windowNumber: windowNumber, windowFrame: windowFrame, allowGlobalCursor: false)
    }
    private let frame = CGRect(x: 0, y: 0, width: 100, height: 100)

    // MARK: FallbackReason mapping

    @Test func tier2ViableWhenWindowResolvesAndBridgeSucceeds() {
        let reasons = perWindowFallbackReasons(
            context: context(windowNumber: 42, windowFrame: frame), bridgeSucceeded: true)
        #expect(reasons.isEmpty)
    }

    @Test func missingWindowNumberIsAFallbackReason() {
        let reasons = perWindowFallbackReasons(
            context: context(windowNumber: nil, windowFrame: frame), bridgeSucceeded: false)
        #expect(reasons == [.windowNumberUnresolved])
    }

    @Test func missingWindowFrameIsAFallbackReason() {
        let reasons = perWindowFallbackReasons(
            context: context(windowNumber: 42, windowFrame: nil), bridgeSucceeded: false)
        #expect(reasons == [.windowFrameUnresolved])
    }

    @Test func bothWindowInputsMissingReportBothReasons() {
        let reasons = perWindowFallbackReasons(
            context: context(windowNumber: nil, windowFrame: nil), bridgeSucceeded: false)
        #expect(reasons == [.windowNumberUnresolved, .windowFrameUnresolved])
    }

    @Test func bridgeFailureIsReasonOnlyWhenInputsWerePresent() {
        // Inputs present, bridge failed: the bridge itself is the reason.
        let reasons = perWindowFallbackReasons(
            context: context(windowNumber: 42, windowFrame: frame), bridgeSucceeded: false)
        #expect(reasons == [.eventBridgeFailed])
    }

    @Test func missingInputsDoNotAlsoReportBridgeFailure() {
        // A missing input already explains the skip; don't pile on eventBridgeFailed.
        let reasons = perWindowFallbackReasons(
            context: context(windowNumber: nil, windowFrame: frame), bridgeSucceeded: false)
        #expect(!reasons.contains(.eventBridgeFailed))
    }

    // MARK: DeliveryOutcome

    @Test func deliveryOutcomeDefaultsToNoFallbackReasons() {
        #expect(DeliveryOutcome(tier: .perWindow).fallbackReasons.isEmpty)
    }

    // MARK: Telemetry surfacing

    @Test func focusTelemetrySurfacesFallbackReasons() {
        let app = FrontmostAppSnapshot(name: "Finder", bundleIdentifier: "com.apple.finder", pid: 42)
        let telemetry = FocusTelemetry(
            before: app, after: app,
            deliveryTier: InputTier.perPid.rawValue,
            focusChangeAllowed: false, cursorMovementAllowed: false,
            fallbackReasons: [FallbackReason.axActionUnsupported.rawValue, FallbackReason.windowNumberUnresolved.rawValue]
        )
        guard case let .object(fields)? = telemetry.deliveryValue,
            case let .array(reasons)? = fields["fallback_reasons"]
        else {
            Issue.record("expected fallback_reasons array in delivery telemetry")
            return
        }
        #expect(reasons.map(\.stringValue) == ["ax-action-unsupported", "window-number-unresolved"])
    }

    @Test func focusTelemetryOmitsFallbackReasonsWhenEmpty() {
        let app = FrontmostAppSnapshot(name: "Finder", bundleIdentifier: "com.apple.finder", pid: 42)
        let telemetry = FocusTelemetry(
            before: app, after: app,
            deliveryTier: InputTier.accessibilityAction.rawValue,
            focusChangeAllowed: false, cursorMovementAllowed: false
        )
        guard case let .object(fields)? = telemetry.deliveryValue else {
            Issue.record("expected delivery telemetry")
            return
        }
        #expect(fields["fallback_reasons"] == nil)
    }

    @Test func finishMapsReasonsToRawValues() {
        let telemetry = FocusChangeTracker.start().finish(
            deliveryTier: InputTier.perPid.rawValue, fallbackReasons: [.globalCursorRequested])
        #expect(telemetry.fallbackReasons == ["global-cursor-requested"])
    }
}
