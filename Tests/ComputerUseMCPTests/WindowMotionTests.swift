#if os(macOS)
import CoreGraphics
#endif
import Foundation
import Testing

@testable import computer_use_mcp

/// Deterministic tests for the window-motion verifier (task #6): pre-validation
/// geometry, the settle/stability/correction poll (with injected I/O so no live
/// window is needed), and the discrete window-state verdicts.
@Suite struct WindowMotionTests {
    private let mainDisplay = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // MARK: - Pre-validation

    @Test func onScreenTargetIsAccepted() {
        let target = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(WindowMotion.validate(target: target, displays: [mainDisplay]) == nil)
    }

    @Test func nonFiniteTargetIsInvalid() {
        let target = CGRect(x: CGFloat.nan, y: 0, width: 800, height: 600)
        #expect(WindowMotion.validate(target: target, displays: [mainDisplay]) == .invalidTargetFrame(
            "The target window frame is not a finite rectangle."))
    }

    @Test func fullyOffscreenTargetIsRejected() {
        let target = CGRect(x: 50_000, y: 50_000, width: 800, height: 600)
        guard case .offscreenTargetFrame = WindowMotion.validate(target: target, displays: [mainDisplay]) else {
            Issue.record("expected offscreenTargetFrame")
            return
        }
    }

    @Test func partiallyOnScreenAboveThresholdIsAccepted() {
        // 200pt of the window still shows on the right edge — well over minVisible.
        let target = CGRect(x: 1240, y: 100, width: 800, height: 600)
        #expect(WindowMotion.validate(target: target, displays: [mainDisplay]) == nil)
    }

    @Test func sliverOnScreenBelowThresholdIsRejected() {
        // Only ~10pt shows on the right edge — under the 40pt reachability floor.
        let target = CGRect(x: 1430, y: 100, width: 800, height: 600)
        guard case .offscreenTargetFrame = WindowMotion.validate(target: target, displays: [mainDisplay]) else {
            Issue.record("expected offscreenTargetFrame")
            return
        }
    }

    @Test func tinyWindowMustBeFullyOnScreen() {
        // Smaller than minVisible: it only needs to fit, not show 40pt.
        let onScreen = CGRect(x: 100, y: 100, width: 20, height: 20)
        #expect(WindowMotion.validate(target: onScreen, displays: [mainDisplay]) == nil)
        let halfOff = CGRect(x: 1435, y: 100, width: 20, height: 20)
        guard case .offscreenTargetFrame = WindowMotion.validate(target: halfOff, displays: [mainDisplay]) else {
            Issue.record("expected offscreenTargetFrame")
            return
        }
    }

    @Test func noDisplayInfoDoesNotBlock() {
        let target = CGRect(x: 50_000, y: 50_000, width: 800, height: 600)
        #expect(WindowMotion.validate(target: target, displays: []) == nil)
    }

    @Test func targetOnSecondDisplayIsAccepted() {
        let second = CGRect(x: 1440, y: 0, width: 1440, height: 900)
        let target = CGRect(x: 1600, y: 100, width: 800, height: 600)
        #expect(WindowMotion.validate(target: target, displays: [mainDisplay, second]) == nil)
    }

    // MARK: - Frame comparison

    @Test func matchesRespectsDimensionAndTolerance() {
        let a = CGRect(x: 100, y: 100, width: 800, height: 600)
        let movedWithinTolerance = CGRect(x: 101, y: 99, width: 800, height: 600)
        let resized = CGRect(x: 100, y: 100, width: 900, height: 600)
        #expect(WindowMotion.matches(a, movedWithinTolerance, dimension: .position))
        #expect(WindowMotion.matches(a, resized, dimension: .position))       // position unchanged
        #expect(!WindowMotion.matches(a, resized, dimension: .size))
        #expect(!WindowMotion.matches(a, resized, dimension: .both))
        let farMove = CGRect(x: 110, y: 100, width: 800, height: 600)
        #expect(!WindowMotion.matches(a, farMove, dimension: .position))
    }

    // MARK: - Settle poll

    private let noSleep: (Duration) async -> Void = { _ in }

    @Test func settleStableAtTargetNeedsNoCorrection() async {
        let target = CGRect(x: 0, y: 0, width: 800, height: 600)
        let outcome = await WindowMotion.settle(
            target: target, dimension: .size,
            read: { target }, correct: { Issue.record("should not correct") }, sleep: noSleep)
        #expect(outcome.reachedTarget)
        #expect(outcome.stabilized)
        #expect(!outcome.corrected)
        #expect(outcome.frame == target)
    }

    @Test func settleClampedFrameReportsHonestlyAfterCorrection() async {
        // The app clamps to 1200 wide no matter what; the correction cannot move
        // it, so we report the clamped frame — not a false reach.
        let target = CGRect(x: 0, y: 0, width: 2000, height: 2000)
        let clamped = CGRect(x: 0, y: 0, width: 1200, height: 760)
        var corrections = 0
        let outcome = await WindowMotion.settle(
            target: target, dimension: .size,
            read: { clamped }, correct: { corrections += 1 }, sleep: noSleep)
        #expect(!outcome.reachedTarget)
        #expect(outcome.corrected)
        #expect(corrections == 1)  // exactly one corrective re-write
        #expect(outcome.frame == clamped)
    }

    @Test func settleCorrectionRecoversOffTargetFrame() async {
        // First write lands short; the single correction lands it on target.
        let target = CGRect(x: 0, y: 0, width: 800, height: 600)
        let short = CGRect(x: 0, y: 0, width: 500, height: 600)
        var corrected = false
        let outcome = await WindowMotion.settle(
            target: target, dimension: .size,
            read: { corrected ? target : short }, correct: { corrected = true }, sleep: noSleep)
        #expect(outcome.reachedTarget)
        #expect(outcome.corrected)
        #expect(outcome.frame == target)
    }

    @Test func settleWaitsOutAnimationThenReachesTarget() async {
        let target = CGRect(x: 0, y: 0, width: 800, height: 600)
        let frames = [
            CGRect(x: 0, y: 0, width: 400, height: 600),
            CGRect(x: 0, y: 0, width: 650, height: 600),
            target, target,
        ]
        var index = 0
        let outcome = await WindowMotion.settle(
            target: target, dimension: .size,
            read: {
                defer { index += 1 }
                return frames[Swift.min(index, frames.count - 1)]
            },
            correct: { Issue.record("should not correct") }, sleep: noSleep)
        #expect(outcome.reachedTarget)
        #expect(outcome.stabilized)
        #expect(!outcome.corrected)
    }

    @Test func settleUnreadableFrameIsHonestNil() async {
        let target = CGRect(x: 0, y: 0, width: 800, height: 600)
        let outcome = await WindowMotion.settle(
            target: target, dimension: .size,
            read: { nil }, correct: {}, sleep: noSleep)
        #expect(outcome.frame == nil)
        #expect(!outcome.reachedTarget)
    }

    // MARK: - Boolean-state settle

    @Test func settleBoolReachesDesired() async {
        var reads = 0
        let value = await WindowMotion.settleBool(
            desired: true,
            read: { defer { reads += 1 }; return reads < 2 ? false : true },
            sleep: noSleep)
        #expect(value == true)
    }

    @Test func settleBoolAlreadyDesiredReturnsImmediately() async {
        var reads = 0
        let value = await WindowMotion.settleBool(
            desired: true, read: { reads += 1; return true }, sleep: noSleep)
        #expect(value == true)
        #expect(reads == 1)
    }

    @Test func settleBoolNeverReachesReturnsLastObserved() async {
        let value = await WindowMotion.settleBool(
            desired: true, budget: .milliseconds(32), read: { false }, sleep: noSleep)
        #expect(value == false)
    }

    @Test func settleBoolUnreadableIsNil() async {
        let value = await WindowMotion.settleBool(
            desired: false, budget: .milliseconds(32), read: { nil }, sleep: noSleep)
        #expect(value == nil)
    }

    // MARK: - Discrete state verdicts

    @Test func booleanStateVerdictClassifies() {
        #expect(WindowMotion.booleanStateVerdict(desired: true, before: true, after: true) == .alreadySatisfied)
        #expect(WindowMotion.booleanStateVerdict(desired: true, before: false, after: true) == .changed)
        #expect(WindowMotion.booleanStateVerdict(desired: true, before: false, after: false) == .notChanged)
        #expect(WindowMotion.booleanStateVerdict(desired: true, before: false, after: nil) == .unobservable)
    }

    @Test func minimizeAlreadyMinimizedIsSuccess() {
        let outcome = WindowMotion.booleanStateOutcome(
            described: "window", achieved: "minimized", already: "already minimized",
            desired: true, before: true, after: true)
        #expect(outcome.classification == .success)
        #expect(outcome.failureDomain == nil)
    }

    @Test func minimizeFlippedIsSuccess() {
        let outcome = WindowMotion.booleanStateOutcome(
            described: "window", achieved: "minimized", already: "already minimized",
            desired: true, before: false, after: true)
        #expect(outcome.classification == .success)
    }

    @Test func minimizeNoChangeIsEffectNotVerified() {
        let outcome = WindowMotion.booleanStateOutcome(
            described: "window", achieved: "minimized", already: "already minimized",
            desired: true, before: false, after: false)
        #expect(outcome.classification == .effectNotVerified)
        #expect(outcome.failureDomain == .verification)
    }

    @Test func fullscreenUnobservableIsAmbiguous() {
        let outcome = WindowMotion.booleanStateOutcome(
            described: "window", achieved: "in full screen", already: "already in full screen",
            desired: true, before: false, after: nil)
        #expect(outcome.classification == .verifierAmbiguous)
    }

    @Test func raiseBecameMainIsSuccess() {
        let outcome = WindowMotion.raiseOutcome(described: "window", before: false, after: true)
        #expect(outcome.classification == .success)
    }

    @Test func raiseUnobservableIsAmbiguousNotFailure() {
        // Z-order is not always readable; a negative read must not become a failure.
        let outcome = WindowMotion.raiseOutcome(described: "window", before: false, after: false)
        #expect(outcome.classification == .verifierAmbiguous)
    }

    @Test func closeGoneIsSuccess() {
        let outcome = WindowMotion.closeOutcome(described: "window", gone: true, sheetAppeared: false)
        #expect(outcome.classification == .success)
    }

    @Test func closeBlockedBySheetIsSuccess() {
        let outcome = WindowMotion.closeOutcome(described: "window", gone: false, sheetAppeared: true)
        #expect(outcome.classification == .success)
    }

    @Test func closeNoEffectIsEffectNotVerified() {
        let outcome = WindowMotion.closeOutcome(described: "window", gone: false, sheetAppeared: false)
        #expect(outcome.classification == .effectNotVerified)
        #expect(outcome.failureDomain == .verification)
    }
}
