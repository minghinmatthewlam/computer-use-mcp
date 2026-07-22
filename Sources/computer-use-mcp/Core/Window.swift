// Target-window selection for an app: front window by default, or by title.

import Foundation
#if os(macOS)
import ApplicationServices
import CoreGraphics
#endif

/// Backing scale of the display containing a global top-left point — the
/// fallback pixels-per-point when a window cannot be captured and no prior
/// snapshot exists (defaulting to 1 on a Retina display would skew element
/// boxes ~2x against a later real capture). CoreGraphics, not NSScreen:
/// NSScreen.screens needs a serviced run loop to refresh and goes stale in
/// the daemon after display changes; CG queries the window server directly,
/// in the same global top-left coordinates as window frames.
func displayScale(atGlobalTopLeft point: CGPoint) -> Double {
    var displayCount: UInt32 = 0
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &displayCount) == .success,
        displayCount > 0
    else { return 1 }
    let active = displays.prefix(Int(displayCount))
    let display = active.first { CGDisplayBounds($0).contains(point) } ?? active[0]
    let bounds = CGDisplayBounds(display)
    guard bounds.width > 0, let mode = CGDisplayCopyDisplayMode(display) else { return 1 }
    return Double(mode.pixelWidth) / bounds.width
}

/// @unchecked: AXUIElement is an immutable thread-safe CF handle.
struct TargetWindow: @unchecked Sendable {
    let element: AXUIElement
    let title: String?
    /// Global screen frame in points (top-left origin).
    let frame: CGRect
}

func targetWindow(for app: ResolvedApp, title requestedTitle: String?) throws -> TargetWindow {
    try requireAppAlive(app)
    let axApp = app.axApplication
    // Some apps (observed with windows on inactive Spaces) return degenerate
    // entries — even the application element itself — in AXWindows; keep only
    // real windows so the failure reads "no windows", not a frame error.
    var windows = axElements(axApp, kAXWindowsAttribute).filter { axRole($0) == "AXWindow" }
    if windows.isEmpty, let focused = axElement(axApp, kAXFocusedWindowAttribute),
        axRole(focused) == "AXWindow"
    {
        windows = [focused]
    }
    guard !windows.isEmpty else {
        throw ToolError.failed(
            "\(app.name) has no windows in the current Space. If it is launching or its "
                + "windows are closed, open one first (e.g. press_key cmd+n); if its window "
                + "is on another Space, switch to it or move the window. See list_apps for "
                + "alternatives."
        )
    }

    func describe(_ window: AXUIElement) -> String? {
        axString(window, kAXTitleAttribute)
    }

    let chosen: AXUIElement
    if let requestedTitle {
        let query = requestedTitle.lowercased()
        guard
            let match = windows.first(where: { describe($0)?.lowercased() == query })
                ?? windows.first(where: { describe($0)?.lowercased().contains(query) ?? false })
        else {
            let titles = windows.compactMap(describe).joined(separator: "\", \"")
            throw ToolError.failed(
                "No \(app.name) window titled \"\(requestedTitle)\". Open windows: \"\(titles)\"."
            )
        }
        chosen = match
    } else {
        chosen = axElement(axApp, kAXFocusedWindowAttribute)
            ?? axElement(axApp, kAXMainWindowAttribute)
            ?? windows[0]
    }

    guard let frame = axFrame(chosen) else {
        throw ToolError.failed("Could not read the window frame for \(app.name).")
    }
    return TargetWindow(element: chosen, title: describe(chosen), frame: frame)
}
