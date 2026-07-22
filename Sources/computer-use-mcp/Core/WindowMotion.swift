// Window-motion verification. AX frame writes are applied asynchronously and
// are silently clamped or ignored by many apps, so trusting the value that
// reads back one fixed sleep later is unreliable. This file:
//
//   1. Pre-validates a target frame before writing it — finite, and on-screen
//      enough to stay reachable — rejecting an offscreen/degenerate move as a
//      recoverable error instead of stranding the window.
//   2. Settle-polls the window frame after the write (~60 Hz) until it stops
//      moving, then issues ONE corrective re-write if it settled off-target and
//      re-polls briefly. A frame the app clamps stabilizes off-target and the
//      correction does not move it — that is honest clamp evidence, not failure.
//   3. Verifies the discrete window-state actions (minimize / fullscreen /
//      raise / close) by reading the state back rather than trusting the write.
//
// The geometry and the settle/stability decisions are pure — I/O (frame reads,
// the corrective write, sleeping) is injected — so the logic is unit-tested
// without a live window. The live wiring lives in Tools/SystemTools.swift.

import Foundation
#if os(macOS)
import ApplicationServices
import CoreGraphics
#endif

enum WindowMotion {
    // MARK: - Tunables

    /// Sub-pixel + title-bar noise absorbed when comparing frames.
    static let tolerance: CGFloat = 2
    /// ~60 Hz sampling.
    static let pollInterval: Duration = .milliseconds(16)
    /// Upper bound on the initial settle wait.
    static let settleBudget: Duration = .milliseconds(900)
    /// Shorter re-poll after the single corrective re-write.
    static let correctionBudget: Duration = .milliseconds(250)
    /// A window must show at least this much (≈ a title bar) on some display to
    /// count as reachable; below it, the move is rejected as offscreen.
    static let minVisible: CGFloat = 40

    // MARK: - Pre-validation (pure geometry)

    enum Rejection: Error, Equatable {
        /// The target frame is not a finite rectangle (NaN/inf).
        case invalidTargetFrame(String)
        /// The target frame would leave the window effectively unreachable.
        case offscreenTargetFrame(String)
    }

    /// Reject a target frame that is non-finite or would leave the window
    /// unreachable — no display shows at least `minVisible` of it in both axes.
    /// Pure: the caller passes the display rects (global, top-left origin, the
    /// same space as `axFrame`). `nil` means the frame is acceptable.
    static func validate(
        target: CGRect, displays: [CGRect], minVisible: CGFloat = minVisible
    ) -> Rejection? {
        guard target.origin.x.isFinite, target.origin.y.isFinite,
            target.size.width.isFinite, target.size.height.isFinite
        else {
            return .invalidTargetFrame("The target window frame is not a finite rectangle.")
        }
        // No display info (headless / query failed): don't block the write.
        guard !displays.isEmpty else { return nil }
        if isRenderable(target, on: displays, minVisible: minVisible) { return nil }
        return .offscreenTargetFrame(
            "The target frame \(frameDescription(target)) is off-screen: no display shows at "
                + "least \(Int(minVisible))pt of the window. Choose coordinates on a visible display "
                + "(see list_windows for the current position).")
    }

    /// True when at least one display shows the window with enough overlap in
    /// both axes to remain grabbable. A window smaller than `minVisible` only
    /// needs to be fully on a display.
    static func isRenderable(_ frame: CGRect, on displays: [CGRect], minVisible: CGFloat) -> Bool {
        let needWidth = Swift.min(minVisible, frame.width)
        let needHeight = Swift.min(minVisible, frame.height)
        for display in displays {
            let overlap = frame.intersection(display)
            if !overlap.isNull, overlap.width >= needWidth - 0.001, overlap.height >= needHeight - 0.001 {
                return true
            }
        }
        return false
    }

    /// Active display bounds in global top-left coordinates. CoreGraphics, not
    /// NSScreen: NSScreen goes stale in the daemon after display changes (see
    /// displayScale in Window.swift).
    static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success, count > 0
        else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    // MARK: - Frame comparison (pure)

    /// Which part of the frame a comparison cares about: a move only requested a
    /// new position, a resize only a new size.
    enum Dimension { case position, size, both }

    static func matches(
        _ a: CGRect, _ b: CGRect, dimension: Dimension, tolerance: CGFloat = tolerance
    ) -> Bool {
        func near(_ x: CGFloat, _ y: CGFloat) -> Bool { abs(x - y) <= tolerance }
        let position = near(a.origin.x, b.origin.x) && near(a.origin.y, b.origin.y)
        let size = near(a.size.width, b.size.width) && near(a.size.height, b.size.height)
        switch dimension {
        case .position: return position
        case .size: return size
        case .both: return position && size
        }
    }

    // MARK: - Settle-poll (injected I/O for testability)

    struct SettleOutcome: Equatable {
        /// The final observed frame, or nil if the frame was never readable.
        var frame: CGRect?
        /// The settled frame is within tolerance of the requested dimension.
        var reachedTarget: Bool
        /// Two consecutive samples matched — the frame stopped moving (vs the
        /// poll timing out mid-animation).
        var stabilized: Bool
        /// A corrective re-write was issued.
        var corrected: Bool
        var samples: Int
    }

    /// Poll the window frame until it stops moving (two consecutive stable
    /// samples) or the budget elapses; if it settled off the requested
    /// dimension, issue one corrective re-write and re-poll briefly. Detecting a
    /// stable-but-off-target frame is the fast realization of "clamped / refused
    /// — waiting longer will not move it," so we go straight to the single
    /// correction rather than spinning out the full budget.
    static func settle(
        target: CGRect,
        dimension: Dimension,
        tolerance: CGFloat = tolerance,
        budget: Duration = settleBudget,
        correctionBudget: Duration = correctionBudget,
        interval: Duration = pollInterval,
        read: () async -> CGRect?,
        correct: () async -> Void,
        sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async -> SettleOutcome {
        func poll(_ budget: Duration) async -> (frame: CGRect?, stabilized: Bool, samples: Int) {
            var previous: CGRect?
            var latest: CGRect?
            var samples = 0
            var elapsed: Int64 = 0
            let step = interval.wm_nanoseconds
            let cap = budget.wm_nanoseconds
            while true {
                guard let sample = await read() else {
                    return (previous ?? latest, false, samples)
                }
                samples += 1
                latest = sample
                if let previous, matches(previous, sample, dimension: .both, tolerance: tolerance) {
                    return (sample, true, samples)
                }
                previous = sample
                if elapsed >= cap { return (sample, false, samples) }
                await sleep(interval)
                elapsed += step
            }
        }

        var (frame, stabilized, samples) = await poll(budget)
        var corrected = false
        if frame == nil || !matches(frame!, target, dimension: dimension, tolerance: tolerance) {
            await correct()
            corrected = true
            let second = await poll(correctionBudget)
            samples += second.samples
            if let f = second.frame { frame = f }
            stabilized = stabilized || second.stabilized
        }
        let reached = frame.map { matches($0, target, dimension: dimension, tolerance: tolerance) } ?? false
        return SettleOutcome(
            frame: frame, reachedTarget: reached, stabilized: stabilized,
            corrected: corrected, samples: samples)
    }

    /// Poll a boolean AX state (minimized / full-screen / main / window-present)
    /// until it reaches `desired` or the budget elapses. Returns the final
    /// observed value (nil = unreadable). Used for the discrete window-state
    /// actions, which have no frame to settle.
    static func settleBool(
        desired: Bool,
        budget: Duration = settleBudget,
        interval: Duration = pollInterval,
        read: () async -> Bool?,
        sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async -> Bool? {
        var latest = await read()
        if latest == desired { return latest }
        var elapsed: Int64 = 0
        let step = interval.wm_nanoseconds
        let cap = budget.wm_nanoseconds
        while elapsed < cap {
            await sleep(interval)
            elapsed += step
            latest = await read()
            if latest == desired { return latest }
        }
        return latest
    }

    // MARK: - Discrete window-state verdicts (pure)

    /// The observable verdict for a boolean-state action, from before/after AX
    /// reads. `alreadySatisfied` short-circuits (§4.7 step 1): the window was
    /// already in the requested state, a correct no-op.
    enum StateVerdict: Equatable {
        case alreadySatisfied
        case changed
        case notChanged
        case unobservable
    }

    static func booleanStateVerdict(desired: Bool, before: Bool?, after: Bool?) -> StateVerdict {
        if before == desired { return .alreadySatisfied }
        if after == desired { return .changed }
        if after == nil { return .unobservable }
        return .notChanged
    }

    /// Outcome for minimize/unminimize and fullscreen/exit_fullscreen. `achieved`
    /// is the state word for the requested direction ("minimized", "in full
    /// screen"); `already` is how to phrase the no-op ("already minimized").
    static func booleanStateOutcome(
        described: String, achieved: String, already: String,
        desired: Bool, before: Bool?, after: Bool?
    ) -> ActionOutcome {
        switch booleanStateVerdict(desired: desired, before: before, after: after) {
        case .alreadySatisfied:
            return .success("\(described) was \(already).")
        case .changed:
            return .success("\(described) is now \(achieved).")
        case .notChanged:
            return .effectNotVerified(
                .verification,
                "\(described) did not become \(achieved); the app reported success but the state "
                    + "did not change.")
        case .unobservable:
            return .ambiguous(
                .verification,
                "Requested to make \(described) \(achieved), but that state is not readable via "
                    + "accessibility, so the effect could not be confirmed.")
        }
    }

    /// Outcome for raise. Z-order is often not reflected in any readable AX
    /// attribute, so a window that did not become main is reported ambiguous,
    /// not failed — a negative read is not proof the raise did nothing.
    static func raiseOutcome(described: String, before: Bool?, after: Bool?) -> ActionOutcome {
        switch booleanStateVerdict(desired: true, before: before, after: after) {
        case .alreadySatisfied:
            return .success("\(described) was already the main window.")
        case .changed:
            return .success("\(described) is now the main window.")
        case .notChanged, .unobservable:
            return .ambiguous(
                .verification,
                "Raised \(described); the app exposes no readable z-order change, so the effect "
                    + "could not be confirmed.")
        }
    }

    /// Outcome for close. The window should be gone; a still-present window with
    /// a new sheet is the app asking to confirm (save dialog), which is a
    /// legitimate effect, not a failed close.
    static func closeOutcome(described: String, gone: Bool, sheetAppeared: Bool) -> ActionOutcome {
        if gone {
            return .success("\(described) was closed.")
        }
        if sheetAppeared {
            return .success(
                "\(described) is still open with a new dialog — the app is asking to confirm the "
                    + "close (likely a save prompt). Check list_windows.")
        }
        return .effectNotVerified(
            .verification, "\(described) is still open; the close had no observable effect.")
    }

    // MARK: - Formatting

    static func frameDescription(_ rect: CGRect) -> String {
        "(\(roundedIntegerDescription(rect.origin.x)),\(roundedIntegerDescription(rect.origin.y)) "
            + "\(roundedIntegerDescription(rect.size.width))x\(roundedIntegerDescription(rect.size.height)) pt)"
    }
}

extension Duration {
    /// Whole nanoseconds, for accumulating injected-sleep budgets deterministically.
    fileprivate var wm_nanoseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }
}
