// Window screenshots via ScreenCaptureKit. Captures a single app window
// without bringing it to the foreground.

import Foundation
#if os(macOS)
import CoreGraphics
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers
#endif

struct WindowCapture {
    let pngData: Data
    let pixelWidth: Int
    let pixelHeight: Int
}

/// How much screenshot a state result carries. Action results default to
/// .reduced: the agent usually verifies effects from the tree and only needs
/// full pixels when it explicitly re-perceives.
enum ScreenshotDetail: Sendable {
    /// Retina-scale capture capped at 1600px — get_app_state ground truth.
    case full
    /// 1x capture capped at 1000px — cheap post-action verification.
    case reduced
    /// Tree only, no capture.
    case none
    /// No state at all: the action returns just its confirmation note.
    case noState

    /// Longest screenshot side sent to the model, in pixels.
    var maxDimension: Double { self == .full ? 1600 : 1000 }

    /// Capture scale. Full follows the display (with a 2x floor — the
    /// pointPixelScale can misreport 1 in headless CLI contexts); reduced is
    /// always 1x, quartering the payload on Retina displays.
    func scale(forDisplayScale displayScale: CGFloat) -> CGFloat {
        self == .full ? max(displayScale, 2) : 1
    }
}

#if os(macOS)
func captureWindow(pid: pid_t, title: String?, frame: CGRect, detail: ScreenshotDetail) async throws -> WindowCapture {
    guard CGPreflightScreenCaptureAccess() else {
        throw ToolError.failed(
            """
            Screen Recording permission is not granted, so screenshots are unavailable. \
            Run `computer-use-mcp doctor --prompt` and enable the host app under \
            System Settings → Privacy & Security → Screen Recording.
            """
        )
    }
    // ScreenCaptureKit calls go through the replayd daemon, whose XPC
    // connection can wedge (observed: a dead replayd port left awaits hanging
    // for hours while ReplayKit spun on reconnect). Concurrent captures from
    // multiple server processes are a known trigger, so captures are
    // serialized across processes, and the whole capture is bounded so a
    // wedged daemon degrades to a no-screenshot result, not a hung server.
    return try await withCrossProcessLock(named: "screencapture") {
        try await withTimeout(seconds: 8, label: "Window screenshot") {
            try await captureWindowUnbounded(pid: pid, title: title, frame: frame, detail: detail)
        }
    }
}
/// SCShareableContent enumerates every shareable window in the system through
/// replayd — the most expensive part of a capture. Within a burst of actions
/// the window list barely changes, so it is cached briefly; a request the
/// cache cannot satisfy (new window, new dialog, new title) refetches.
/// @unchecked: SCWindow is an immutable snapshot of window state.
private struct WindowList: @unchecked Sendable {
    let windows: [SCWindow]
}

private actor ShareableContentCache {
    static let shared = ShareableContentCache()
    private var windows: [SCWindow] = []
    private var fetchedAt = Date.distantPast

    func appWindows(pid: pid_t, title: String?) async throws -> WindowList {
        if Date().timeIntervalSince(fetchedAt) < 1.5 {
            let cached = filter(pid: pid)
            if !cached.isEmpty, title == nil || cached.contains(where: { $0.title == title }) {
                return WindowList(windows: cached)
            }
        }
        // Off-screen windows included: with "Displays have separate Spaces" a
        // window on an inactive Space is not "on screen", yet SCK can still
        // capture it (docs/research/multi-display-audit.md, Finding 2). The
        // wider list also contains minimized and zero-sized bookkeeping
        // windows, which filter(pid:) screens out.
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        windows = content.windows
        fetchedAt = Date()
        return WindowList(windows: filter(pid: pid))
    }

    private func filter(pid: pid_t) -> [SCWindow] {
        // Degenerate bounds mark bookkeeping windows (event taps, IME hosts)
        // that off-screen enumeration surfaces; they capture as blank images.
        windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0
                && $0.frame.width >= 1 && $0.frame.height >= 1
        }
    }
}

private func captureWindowUnbounded(
    pid: pid_t, title: String?, frame: CGRect, detail: ScreenshotDetail
) async throws -> WindowCapture {
    let appWindows = try await ShareableContentCache.shared.appWindows(pid: pid, title: title).windows
    guard !appWindows.isEmpty else {
        throw ToolError.failed("No capturable window found for pid \(pid).")
    }

    // Prefer title matches; off-screen enumeration can list several same-pid
    // windows with the same title (other Spaces, minimized copies), so the AX
    // window frame disambiguates. With no title match, fall back to the
    // window whose frame best matches the AX window frame.
    let titleMatches = title.map { title in appWindows.filter { $0.title == title } } ?? []
    let candidates = titleMatches.isEmpty ? appWindows : titleMatches
    let window = candidates.min { lhs, rhs in
        distance(lhs.frame, frame) < distance(rhs.frame, frame)
    }!

    let filter = SCContentFilter(desktopIndependentWindow: window)

    // Full detail captures at display scale; reduced detail captures at 1x.
    // Both are downscaled to the detail's payload cap if needed.
    let scale = detail.scale(forDisplayScale: CGFloat(filter.pointPixelScale))
    let nativeWidth = filter.contentRect.width * scale
    let nativeHeight = filter.contentRect.height * scale
    let downscale = min(1.0, detail.maxDimension / max(nativeWidth, nativeHeight))

    guard let captureWidth = safeInt(nativeWidth * downscale), let captureHeight = safeInt(nativeHeight * downscale),
        captureWidth > 0, captureHeight > 0
    else {
        throw ToolError.failed("Window screenshot dimensions are not finite.")
    }

    let configuration = SCStreamConfiguration()
    configuration.width = captureWidth
    configuration.height = captureHeight
    configuration.scalesToFit = true
    configuration.showsCursor = false
    configuration.captureResolution = .best
    let image = try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: configuration
    )

    guard let pngData = encodePNG(image) else {
        throw ToolError.failed("Failed to encode the window screenshot.")
    }
    return WindowCapture(pngData: pngData, pixelWidth: image.width, pixelHeight: image.height)
}

/// Race an operation against a deadline. On timeout the operation's task is
/// cancelled and abandoned (a cold ScreenCaptureKit/replayd capture has been
/// seen to ignore cancellation and never return) and a recoverable tool error
/// is thrown instead.
///
/// This deliberately does NOT use a task group: a group implicitly awaits every
/// child before it returns, so one un-cancellable child would pin the group
/// past the deadline and defeat the timeout. Instead two unstructured tasks
/// race through a resume-once continuation, and the loser is abandoned rather
/// than awaited.
func withTimeout<T: Sendable>(
    seconds: Double, label: String, operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = TimeoutRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            let work = Task {
                let result: Result<T, any Error>
                do { result = .success(try await operation()) } catch { result = .failure(error) }
                await race.finish(result, resuming: continuation)
            }
            let timer = Task {
                try? await Task.sleep(for: .seconds(seconds))
                await race.finish(
                    .failure(ToolError.failed(
                        "\(label) timed out after \(Int(seconds))s. The macOS screen-capture "
                            + "service (replayd) may be wedged; if this persists, run "
                            + "`killall -9 replayd` (launchd restarts it clean) or restart the MCP server."
                    )),
                    resuming: continuation
                )
            }
            Task { await race.track(work: work, timer: timer) }
        }
    } onCancel: {
        Task { await race.cancel() }
    }
}

/// Guards a `withTimeout` race so its continuation resumes exactly once and the
/// losing task is cancelled (never awaited).
private actor TimeoutRace<T: Sendable> {
    private var settled = false
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func track(work: Task<Void, Never>, timer: Task<Void, Never>) {
        self.work = work
        self.timer = timer
        // Only ever stop the timer; the work task is abandoned, not cancelled.
        if settled { timer.cancel() }
    }

    func finish(_ result: Result<T, any Error>, resuming continuation: CheckedContinuation<T, any Error>) {
        guard !settled else { return }
        settled = true
        // Stop the timer's sleep, but do NOT cancel the work task: a wedged
        // ScreenCaptureKit call ignores cancellation, and cancelling it tears
        // down its suspended continuation mid-flight (the "leaked continuation"
        // warning). Left alone, the abandoned capture resumes and discards its
        // result cleanly once replayd finally answers.
        timer?.cancel()
        continuation.resume(with: result)
    }

    func cancel() {
        work?.cancel()
        timer?.cancel()
    }
}

private func distance(_ a: CGRect, _ b: CGRect) -> Double {
    abs(a.midX - b.midX) + abs(a.midY - b.midY) + abs(a.width - b.width) + abs(a.height - b.height)
}

private func encodePNG(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        )
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}
#else
func captureWindow(pid: pid_t, title: String?, frame: CGRect, detail: ScreenshotDetail) async throws -> WindowCapture {
    throw ToolError.notImplemented("Screenshots are unsupported on Linux.")
}
#endif
