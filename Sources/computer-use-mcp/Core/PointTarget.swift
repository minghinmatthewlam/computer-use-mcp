// Shared resolution for pointer tools (click, scroll): turn the tool args into
// a concrete (AXUIElement, global point, delivery context).

import Foundation
import MCP
#if os(macOS)
import ApplicationServices
import CoreGraphics
#endif

struct PointTarget {
    /// The element under the point (hit-tested or resolved from an id), if any.
    let element: AXUIElement?
    /// The snapshot element (locator) when the target came from an element id,
    /// so the outcome verifier can re-resolve and re-read it after the action.
    /// nil for coordinate clicks — there is no locator to re-read.
    let snapshotElement: SnapshotElement?
    /// Global screen point (top-left origin). Nil when the element exposes no
    /// frame — such targets can only be driven by accessibility actions, and
    /// point-based delivery must fail loudly rather than act at (0,0).
    let point: CGPoint?
    /// Snapshot the ids/coordinates came from.
    let snapshot: AppSnapshot
    /// Human description for result notes.
    let description: String
    let deliveryContext: DeliveryContext

    /// The point, or a clear error for tools that cannot act without one.
    func requirePoint() throws -> CGPoint {
        guard let point else {
            throw ToolError.failed(
                "\(description) has no screen position (the element exposes no frame), "
                    + "so this action cannot be delivered. Call get_app_state and target "
                    + "a different element or use screenshot coordinates."
            )
        }
        return point
    }
}

func resolvePointTarget(_ args: [String: Value], app: ResolvedApp, allowGlobalCursor: Bool = false) async throws -> PointTarget {
    if let elementID = args.string("element_id") {
        let target = try await resolveTarget(app: app, elementID: elementID)
        let window = try? targetWindow(for: app, title: target.snapshot.windowTitle)
        let context = pointDeliveryContext(app: app, window: window, allowGlobalCursor: allowGlobalCursor)
        let point = axFrame(target.element).map { CGPoint(x: $0.midX, y: $0.midY) }
        return PointTarget(
            element: target.element, snapshotElement: target.snapshotElement, point: point,
            snapshot: target.snapshot, description: describeTarget(target), deliveryContext: context
        )
    }

    if let x = args.number("x"), let y = args.number("y") {
        let snapshot = await SnapshotStore.shared.load(forPid: app.pid)
        let window = try? targetWindow(for: app, title: snapshot?.windowTitle)
        let context = pointDeliveryContext(app: app, window: window, allowGlobalCursor: allowGlobalCursor)
        guard let snapshot else {
            throw ToolError.failed("Call get_app_state for \(app.name) before using coordinates.")
        }
        let point = try screenPoint(x: x, y: y, snapshot: snapshot)
        let element = accessibilityElement(at: point, pid: app.pid)
        return PointTarget(
            element: element, snapshotElement: nil, point: point, snapshot: snapshot,
            description: "(\(Int(x)),\(Int(y)))", deliveryContext: context
        )
    }

    throw ToolError.invalidArguments("Provide element_id, or x and y screenshot coordinates.")
}

private func pointDeliveryContext(
    app: ResolvedApp, window: TargetWindow?, allowGlobalCursor: Bool
) -> DeliveryContext {
    DeliveryContext(
        pid: app.pid, windowNumber: window.flatMap { windowID(for: $0.element) },
        windowFrame: window?.frame, allowGlobalCursor: allowGlobalCursor
    )
}
