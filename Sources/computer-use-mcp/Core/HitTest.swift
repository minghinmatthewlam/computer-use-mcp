// Coordinate → element hit-testing, the fallback when a target is not (or is
// wrongly) represented in the accessibility tree.

import Foundation
#if os(macOS)
import ApplicationServices
#endif

/// The accessibility element at a global screen point, restricted to the
/// target app. Returns nil when nothing (or another app's window) is there.
func accessibilityElement(at point: CGPoint, pid: pid_t) -> AXUIElement? {
    var raw: AXUIElement?
    let error = AXUIElementCopyElementAtPosition(
        AXUIElementCreateApplication(pid), Float(point.x), Float(point.y), &raw
    )
    guard error == .success, let element = raw else { return nil }
    return element
}

/// Walk up from an element to the nearest ancestor (or itself) supporting
/// the given action — a coordinate often lands on a label inside a button.
func selfOrAncestor(of element: AXUIElement, supporting action: String, maxHops: Int = 5) -> AXUIElement? {
    var current = element
    for _ in 0...maxHops {
        if axActionNames(current).contains(action) {
            return current
        }
        guard let parent = axElement(current, kAXParentAttribute) else { return nil }
        current = parent
    }
    return nil
}

/// Convert screenshot-pixel coordinates from the latest snapshot into a
/// global screen point, validating bounds.
func screenPoint(x: Double, y: Double, snapshot: AppSnapshot) throws -> CGPoint {
    // Prefer the stored window size (the element list may be scoped to a
    // subtree); fall back to the first element's box for old snapshots.
    guard let size = snapshot.windowSize ?? snapshot.elements.first.map({ [$0.frame[2], $0.frame[3]] })
    else {
        throw ToolError.failed("The latest snapshot has no window element. Call get_app_state again.")
    }
    let width = size.count > 0 ? size[0] : Double.nan
    let height = size.count > 1 ? size[1] : Double.nan
    // Pixel coordinates are zero-indexed: width/height themselves are outside.
    guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
        x >= 0, y >= 0, x < width, y < height
    else {
        throw ToolError.invalidArguments(
            "Coordinate (\(integerDescription(x)), \(integerDescription(y))) is outside the "
                + "\(integerDescription(width))x\(integerDescription(height)) "
                + "screenshot. Coordinates are pixels in the latest get_app_state screenshot."
        )
    }
    guard snapshot.windowOrigin.count >= 2, snapshot.windowOrigin[0].isFinite, snapshot.windowOrigin[1].isFinite,
        snapshot.pixelsPerPoint.isFinite, snapshot.pixelsPerPoint > 0
    else {
        throw ToolError.failed("The latest snapshot has invalid window geometry. Call get_app_state again.")
    }
    return snapshot.screenPoint(fromScreenshotX: x, y: y)
}
