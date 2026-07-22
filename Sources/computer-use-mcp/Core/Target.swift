// Shared target resolution for interaction tools: app + element_id (from the
// latest snapshot) → live AXUIElement, re-resolved via its locator path.

import Foundation
import MCP
#if os(macOS)
import ApplicationServices
#endif

struct ResolvedTarget {
    let app: ResolvedApp
    let snapshot: AppSnapshot
    let snapshotElement: SnapshotElement
    let element: AXUIElement
}

func resolveTarget(app: ResolvedApp, elementID: String) async throws -> ResolvedTarget {
    guard let resolved = await SnapshotStore.shared.resolveElementSnapshot(forPid: app.pid, elementID: elementID) else {
        guard let latest = await SnapshotStore.shared.load(forPid: app.pid) else {
            throw ToolError.failed(
                "No app state captured for \(app.name) yet. Call get_app_state first, "
                    + "then use the element ids it returns."
            )
        }
        if let atIndex = elementID.firstIndex(of: "@"),
            String(elementID[elementID.index(after: atIndex)...]) != latest.generation
        {
            throw ToolError.invalidArguments(
                "\"\(elementID)\" is from an older app state and did not survive the UI "
                    + "change (the current state is \(latest.generation)). Use element ids "
                    + "from the most recent result, or call get_app_state."
            )
        }
        throw ToolError.invalidArguments(
            "\"\(elementID)\" is not an element id from the latest \(app.name) state. "
                + "Call get_app_state and use a fresh id (e.g. \"e12@\(latest.generation)\")."
        )
    }
    let snapshot = resolved.snapshot
    let snapshotElement = resolved.element
    let window = try targetWindow(for: app, title: snapshot.windowTitle)
    let element = try await resolveElement(snapshotElement, in: window.element)
    return ResolvedTarget(app: app, snapshot: snapshot, snapshotElement: snapshotElement, element: element)
}

func performAXAction(_ action: String, on target: ResolvedTarget) throws {
    let error = AXUIElementPerformAction(target.element, action as CFString)
    guard error == .success else {
        throw ToolError.failed(
            "\(action) failed on \(describeTarget(target)) (\(axErrorDescription(error)))."
        )
    }
}

func describeTarget(_ target: ResolvedTarget) -> String {
    let label = target.snapshotElement.label.map { " \"\($0)\"" } ?? ""
    return "\(target.snapshotElement.id) (\(target.snapshotElement.role)\(label))"
}
