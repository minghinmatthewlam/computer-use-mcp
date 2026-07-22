// Perception: list_apps and get_app_state, plus the shared fresh-state
// result that every interaction tool returns after acting.

import Foundation
import MCP
#if os(macOS)
import ApplicationServices
#endif

func listAppsImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    .text(runningAppsDescription())
}

func getAppStateImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))

    // Scoped query: rebuild the tree from one element down, with full budget —
    // the recourse when the whole-window tree is truncated.
    var scope: TreeScope?
    if let scopeID = args.string("scope_element_id") {
        let target = try await resolveTarget(app: app, elementID: scopeID)
        scope = TreeScope(root: target.element, pathPrefix: target.snapshotElement.path)
    }
    return try await stateResult(
        app: app, windowTitle: args.string("window_title"),
        screenshot: appStateScreenshotDetail(args),
        scope: scope, maxElements: args.integer("max_elements") ?? defaultMaxTreeElements,
        ocr: args.bool("ocr") == true,
        // Skeleton and scoped drill-down are complementary: skeleton gives the
        // shallow overview, scope_element_id expands one container from it.
        skeleton: scope == nil && args.bool("skeleton") == true
    )
}

/// Below this element count a window tree is considered sparse: likely a
/// custom-drawn UI or an embedded web view whose accessibility is off.
let sparseTreeThreshold = 10

/// Bounded cold-web retry schedule. Total budget is 2400ms, deliberately below
/// the ~2.5s ceiling and far below the observed ~20s WKWebView lag.
let webMaterializationRetryBackoffMilliseconds = [150, 300, 600, 900, 450]

func webMaterializationRetryBackoff(coldStartShape: Bool) -> [Int] {
    coldStartShape ? webMaterializationRetryBackoffMilliseconds : []
}

func webContentNotMaterializedNote() -> String {
    "Web content has not materialized in the accessibility tree yet. The returned tree is current, "
        + "but the embedded web view is still exposing only its placeholder; retry get_app_state shortly "
        + "or use ocr:true/coordinates if you need to act immediately."
}

/// Guidance appended to a sparse get_app_state tree. When the app provably
/// rejected the web-accessibility opt-in, say so — the agent should go
/// straight to OCR + coordinate clicks instead of re-fetching the tree.
func sparseTreeHint(webAXUnsupported: Bool) -> String {
    if webAXUnsupported {
        return
            "The accessibility tree is sparse and this app's embedded web view rejects the "
            + "accessibility opt-in, so its UI cannot be exposed as elements. Call get_app_state "
            + "with ocr:true to read on-screen text, then act by screenshot coordinates — both "
            + "work in the background."
    }
    return
        "The accessibility tree is sparse — this app may draw its own UI. "
        + "Call get_app_state with ocr:true to read on-screen text with clickable coordinates."
}

/// Fraction of the window a childless element must cover to be flagged as an
/// opaque canvas. 0.6 keeps toolbars, sidebars, and split panes (well under
/// half the window) out while catching the content surface of rich-shell
/// apps — terminal grids, meeting video, editor canvases — which dominates
/// the window.
let opaqueCanvasCoverageThreshold = 0.6

/// Detects the rich-shell/opaque-canvas window shape: enough chrome elements
/// to dodge the sparse-tree hint, but one huge childless element where the
/// actual content is custom-drawn (Zoom meeting view, terminal grids, canvas
/// editors). Elements are emitted in DFS order, so an element has emitted
/// children iff the next element's path extends its own (the hasEmptyWebArea
/// trick). Trees with an AXWebArea are excluded — invisible web content has
/// its own opt-in-and-rebuild path — and so is the window root, whose
/// childlessness is the sparse-tree case. Frames are clipped to the window
/// so oversized frames cannot inflate coverage. Returns a hint naming the
/// largest qualifying element, or nil.
func opaqueCanvasHint(elements: [SnapshotElement], windowSize: [Double]?) -> String? {
    guard let windowSize, windowSize.count == 2 else { return nil }
    let windowArea = windowSize[0] * windowSize[1]
    guard windowArea > 0 else { return nil }
    guard !elements.contains(where: { $0.role == "AXWebArea" }) else { return nil }

    var best: SnapshotElement?
    var bestCoverage = 0.0
    for (index, element) in elements.enumerated() where !element.path.isEmpty {
        let next = index + 1 < elements.count ? elements[index + 1] : nil
        let hasChildren =
            next.map {
                $0.path.count > element.path.count
                    && Array($0.path.prefix(element.path.count)) == element.path
            } ?? false
        if hasChildren { continue }
        let visibleWidth =
            min(element.frame[0] + element.frame[2], windowSize[0]) - max(element.frame[0], 0)
        let visibleHeight =
            min(element.frame[1] + element.frame[3], windowSize[1]) - max(element.frame[1], 0)
        let coverage = max(0, visibleWidth) * max(0, visibleHeight) / windowArea
        if coverage >= opaqueCanvasCoverageThreshold && coverage > bestCoverage {
            best = element
            bestCoverage = coverage
        }
    }

    guard let best else { return nil }
    return
        "Element \(best.id) (\(best.role)) covers most of the window but exposes no children "
        + "— likely a custom-drawn canvas. Call get_app_state with ocr:true to read it."
}

/// A subtree root to build the element tree from, with its locator path from
/// the window root so resolved paths stay anchored at the window.
/// @unchecked: AXUIElement is an immutable thread-safe CF handle.
struct TreeScope: @unchecked Sendable {
    let root: AXUIElement
    let pathPrefix: [LocatorStep]
}

/// Result detail for get_app_state: full screenshot by default,
/// include_screenshot=false is a tree-only read.
func appStateScreenshotDetail(_ args: [String: Value]) -> ScreenshotDetail {
    args.bool("include_screenshot") == false ? .none : .full
}

/// Result detail for an action: reduced screenshot by default,
/// include_screenshot=false drops the image, include_state=false drops
/// everything but the confirmation note (fastest chained-action mode).
func screenshotDetail(_ args: [String: Value]) -> ScreenshotDetail {
    if args.bool("include_state") == false { return .noState }
    return args.bool("include_screenshot") == false ? .none : .reduced
}

/// Build the canonical app-state result: accessibility tree (with element ids
/// and screenshot-pixel bounding boxes) plus a screenshot of the target
/// window. Persists the snapshot so element ids resolve in later calls.
func stateResult(
    app: ResolvedApp,
    windowTitle: String?,
    note: String? = nil,
    screenshot detail: ScreenshotDetail = .reduced,
    scope: TreeScope? = nil,
    maxElements: Int = defaultMaxTreeElements,
    ocr: Bool = false,
    skeleton: Bool = false,
    focusTelemetry: FocusTelemetry? = nil,
    verifier: ActionVerifier? = nil
) async throws -> CallTool.Result {
    try requireAccessibilityTrusted()

    // Every tool call lands here; let the cursor overlay know the agent is
    // still mid-task so it stays visible across the whole operation.
    await AgentCursor.shared.keepAlive()

    if detail == .noState {
        let confirmation = note ?? "Action completed."
        var result = CallTool.Result.text(confirmation + " Call get_app_state when you need the updated UI state.")
            .withFocusTelemetry(focusTelemetry)
        // No recapture on the fast path: honor the skip honestly rather than
        // paying for a reread — a pre-resolved verdict still rides along, but
        // an unresolved one becomes verifier_ambiguous, never a false success.
        if let verifier {
            result = result.withActionOutcome(verifier.skippedStateOutcome())
        }
        return result
    }

    // Give the UI a brief beat to settle after whatever just happened.
    try? await Task.sleep(for: .milliseconds(40))

    // Actions can close or replace the window they acted in (dialogs,
    // sheets); fall back to the front window rather than failing.
    let window: TargetWindow
    var windowNote: String?
    do {
        window = try targetWindow(for: app, title: windowTitle)
    } catch where windowTitle != nil {
        window = try targetWindow(for: app, title: nil)
        windowNote = "Window \"\(windowTitle!)\" is gone; showing the front window instead."
    }

    var capture: WindowCapture?
    var captureNote: String?
    if detail != .none {
        do {
            capture = try await captureWindow(pid: app.pid, title: window.title, frame: window.frame, detail: detail)
        } catch {
            captureNote = "Screenshot unavailable: \(error)"
        }
    }

    // Guard both terms: a degenerate capture or zero-width window must not
    // produce a 0 (or infinite) scale that breaks pixel→point conversion.
    let pixelsPerPoint: Double
    if let capture, capture.pixelWidth > 0, window.frame.width > 0 {
        pixelsPerPoint = Double(capture.pixelWidth) / window.frame.width
    } else if let prior = await SnapshotStore.shared.load(forPid: app.pid), prior.pixelsPerPoint > 0 {
        // No new screenshot: keep coordinates in the pixel space of the last
        // one the agent saw, so its ids and coordinates stay comparable.
        pixelsPerPoint = prior.pixelsPerPoint
    } else {
        // First contact without a capture (window on an inactive Space, or
        // Screen Recording missing): use the window's display scale so boxes
        // match a later real capture instead of being ~2x off on Retina.
        pixelsPerPoint = displayScale(
            atGlobalTopLeft: CGPoint(x: window.frame.midX, y: window.frame.midY))
    }

    // Chromium/Electron apps need an assistive client on record before they
    // render web content into the accessibility tree.
    await AssistiveAccess.shared.enable(pid: app.pid)

    func captureSnapshot() async -> (snapshot: AppSnapshot, tree: BuiltTree, unchanged: Bool, diff: TreeDiff?) {
        await SnapshotStore.shared.capture(
            pid: app.pid,
            bundleIdentifier: app.bundleIdentifier,
            windowTitle: window.title,
            windowOrigin: window.frame.origin,
            pixelsPerPoint: pixelsPerPoint,
            windowSize: [window.frame.width * pixelsPerPoint, window.frame.height * pixelsPerPoint],
            createdAt: Date(),
            scoped: scope != nil
        ) { generation in
            buildTree(
                window: scope?.root ?? window.element,
                windowOrigin: window.frame.origin,
                pixelsPerPoint: pixelsPerPoint,
                generation: generation,
                pathPrefix: scope?.pathPrefix ?? [],
                maxElements: maxElements,
                skeleton: skeleton
            )
        }
    }

    var (snapshot, tree, unchanged, diff) = await captureSnapshot()
    var webAXUnsupported = false
    var webContentNotMaterialized = false
    let emptyWebArea = hasEmptyWebArea(tree.elements)
    let coldStartWebContent = hasColdStartWebContentShape(tree.elements)
    var needsWebAX = emptyWebArea || coldStartWebContent
    if !needsWebAX && tree.elements.count < sparseTreeThreshold {
        needsWebAX = await AssistiveAccess.shared.looksLikeWebRenderer(pid: app.pid)
    }
    if needsWebAX {
        // Web accessibility was off or mid-build: force the flags on, give
        // the renderer a beat to populate the tree, and rebuild once. Some
        // embedded-web apps (CEF builds without accessibility wiring) reject
        // the opt-in — skip the settle-and-rebuild and say so in the hint.
        // A sparse tree that stayed sparse after an earlier forced enable is
        // just a small window: don't re-pay the settle on every call.
        let outcome = await AssistiveAccess.shared.enable(pid: app.pid, force: true)
        if outcome == .applied || (outcome == .alreadyApplied && (emptyWebArea || coldStartWebContent)) {
            let delays = webMaterializationRetryBackoff(coldStartShape: coldStartWebContent || emptyWebArea)
            if delays.isEmpty {
                try? await Task.sleep(for: .milliseconds(500))
                (snapshot, tree, unchanged, diff) = await captureSnapshot()
            } else {
                for milliseconds in delays {
                    guard hasColdStartWebContentShape(tree.elements) else { break }
                    try? await Task.sleep(for: .milliseconds(milliseconds))
                    (snapshot, tree, unchanged, diff) = await captureSnapshot()
                }
                webContentNotMaterialized = hasColdStartWebContentShape(tree.elements)
            }
        } else if outcome == .unsupported {
            webAXUnsupported = true
        }
    }

    var text = ""
    if let note {
        text += note + "\n\n"
    }
    if let windowNote {
        text += windowNote + "\n\n"
    }
    text += "App: \(app.name) (\(app.bundleIdentifier), pid \(app.pid))\n"
    text += "Window: \"\(window.title ?? "untitled")\""
    if let capture {
        text += " — screenshot \(capture.pixelWidth)x\(capture.pixelHeight) px"
        text += " (element boxes and x/y coordinates are in these pixels)"
    } else if detail == .none {
        text += " — screenshot omitted (element boxes stay in the previous screenshot's pixel scale)"
    }
    text += "\n"
    if let captureNote {
        text += captureNote + "\n"
    }
    if webContentNotMaterialized {
        text += webContentNotMaterializedNote() + "\n"
    }
    // Action results skip resending a tree the agent already has; explicit
    // perception (get_app_state, .full) always returns it. A changed tree
    // whose diff is compact is sent as the diff — surviving elements carried
    // their ids over, so everything the agent holds stays valid.
    if unchanged && detail != .full {
        text +=
            "UI tree unchanged by this action: element ids from generation "
            + "\(snapshot.generation) remain valid, reuse them."
    } else if detail != .full, let diff, diff.isCompact {
        text +=
            "Changed since the last state (~ changed, + added, - removed; "
            + "all other element ids remain valid):\n"
        text += diff.text
    } else {
        text += "Elements: id role \"label\" (x,y,w,h) …\n"
        text += tree.text
    }

    if ocr {
        if let capture {
            let lines = (try? await recognizeText(
                inPNG: capture.pngData, pixelWidth: capture.pixelWidth, pixelHeight: capture.pixelHeight
            )) ?? []
            text += "\n\nOCR text (x,y,w,h in screenshot pixels; click by coordinates):\n"
            text += lines.isEmpty
                ? "(no text recognized)"
                : lines.map { "\"\($0.text)\" (\($0.box[0]),\($0.box[1]),\($0.box[2]),\($0.box[3]))" }
                    .joined(separator: "\n")
        } else {
            text += "\n\nOCR unavailable: no screenshot was captured."
        }
    } else if detail == .full && tree.elements.count < sparseTreeThreshold {
        text += "\n\n" + sparseTreeHint(webAXUnsupported: webAXUnsupported)
    } else if detail == .full, scope == nil,
        tree.elements.count < clampedTreeBudget(maxElements),
        let canvasHint = opaqueCanvasHint(elements: tree.elements, windowSize: snapshot.windowSize)
    {
        // Full-window trees only: a truncated tree can make a container look
        // childless, and a scoped subtree's coverage says nothing about the
        // window.
        text += "\n\n" + canvasHint
    }

    var enrichedTelemetry = focusTelemetry
    enrichedTelemetry?.uiChanged = !unchanged

    // Re-read the acted-on element and reduce to an outcome. The reread never
    // throws — a failure degrades the classification, never the tool call.
    var actionOutcome: ActionOutcome?
    if let verifier {
        actionOutcome = await verifier.finalize(
            windowElement: window.element, treeChanged: !unchanged, diff: diff, afterWindowTitle: window.title)
    }
    if let sentence = actionOutcome?.humanSentence {
        // A verified non-success verdict, in plain language for the transcript.
        text += "\n\n" + sentence
    } else if actionOutcome == nil, unchanged,
        let hint = droppedEventHint(deliveryTier: focusTelemetry?.deliveryTier)
    {
        // Unverified tools keep the legacy dropped-event hint.
        text += "\n\n" + hint
    }

    var content: [Tool.Content] = [.text(text: text, annotations: nil, _meta: nil)]
    if let capture {
        content.append(
            .image(
                data: capture.pngData.base64EncodedString(),
                mimeType: "image/png",
                annotations: nil,
                _meta: nil
            )
        )
    }
    return .init(content: content, isError: false)
        .withFocusTelemetry(enrichedTelemetry)
        .withActionOutcome(actionOutcome)
}

/// Guidance when a synthetic background-event delivery produced no visible
/// UI change — the one observable hint that the app may have dropped the
/// event. AX-tier actions either succeed or throw, so they get no hint.
func droppedEventHint(deliveryTier: String?) -> String? {
    guard let deliveryTier, isDroppableBackgroundDeliveryTier(deliveryTier) else { return nil }
    return
        "No visible UI change followed this action. It was delivered via background events, "
        + "which some apps drop. If the intended effect did not happen, retry with "
        + "allow_global_cursor:true and allow_focus_change:true."
}
