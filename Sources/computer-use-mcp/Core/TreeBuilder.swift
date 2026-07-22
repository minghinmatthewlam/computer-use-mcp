// Walk an app window's accessibility tree into (a) a numbered, indented text
// outline for the model and (b) snapshot elements with locator paths.
//
// The traversal core (`buildTreeCore`) is generic over a node type via
// `TreeNodeAccessors`, so the shaping rules — structural-wrapper elision,
// dense-collection viewport windowing, and skeleton depth truncation — are
// unit-testable against an in-memory tree with no live accessibility API.

import Foundation
#if os(macOS)
import ApplicationServices
#endif

struct BuiltTree {
    let text: String
    let elements: [SnapshotElement]
    let isPartial: Bool

    init(text: String, elements: [SnapshotElement], isPartial: Bool = false) {
        self.text = text
        self.elements = elements
        self.isPartial = isPartial
    }
}

let defaultMaxTreeElements = 500
private let maxDepth = 24
private let maxRawDepth = 60
private let maxChildrenPerNode = 150
private let maxValueLength = 300

/// Outline depth a skeleton (overview) build recurses to. Containers deeper
/// than this are emitted but their children are cut and summarized with a
/// `children_count`, keeping the container a drill target for a follow-up
/// scoped get_app_state.
let skeletonMaxDepth = 3

/// A container is treated as a dense virtualized collection — eligible for
/// viewport windowing — only once it has at least this many children (or
/// reports at least this many rows). Small lists are shown whole.
let denseCollectionThreshold = 80

/// Per-element AX messaging timeout (seconds), set on every node before we
/// query it. One hung element then fails its own AX calls after this bound
/// instead of stalling the whole traversal against the coarser process-wide
/// timeout (Core/AX.swift). Tunable via COMPUTER_USE_MCP_AX_ELEMENT_TIMEOUT.
let perElementAXTimeout: Float = Config.double("ax_element_timeout").map(Float.init) ?? 0.25

/// Tighter timeout for the frame-only probes used to decide which children of
/// a dense collection fall in the viewport: a stall there must not cost more
/// than a blink per off-screen row. Tunable via
/// COMPUTER_USE_MCP_VIEWPORT_PROBE_TIMEOUT.
let viewportProbeAXTimeout: Float = Config.double("viewport_probe_timeout").map(Float.init) ?? 0.05

/// Roles whose children are dense, homogeneous, and virtualized around a
/// scroll viewport (lists, tables, outlines). Above `denseCollectionThreshold`
/// children these are windowed to the on-screen slice instead of shown by a
/// blind prefix that ignores the scroll position.
func isDenseCollectionRole(_ role: String) -> Bool {
    switch role {
    case "AXList", "AXTable", "AXOutline", "AXGrid", "AXBrowser": return true
    default: return false
    }
}

/// Element budget for a tree build, clamped to a sane range. Callers that
/// need to know whether a built tree hit its budget (was truncated) must
/// compare against this same clamp.
func clampedTreeBudget(_ maxElements: Int) -> Int {
    max(1, min(maxElements, 5000))
}

/// True for pure structural wrappers: unlabeled, value-less AXGroups whose
/// only actions are universal noise (ShowMenu, ScrollToVisible). Web pages
/// nest dozens of these around every piece of content — they are omitted from
/// the outline (and the element budget) but kept in locator paths, so deep
/// web content fits within the depth and element limits.
func isStructuralWrapper(
    role: String, label: String?, value: String?, focused: Bool, actions: [String]
) -> Bool {
    guard role == "AXGroup" else { return false }
    guard label == nil || label!.isEmpty else { return false }
    guard value == nil || value!.isEmpty else { return false }
    guard !focused else { return false }
    return actions.allSatisfy { $0 == "AXShowMenu" || $0 == "AXScrollToVisible" }
}

// MARK: - Generic node model

/// Everything the outline needs to know about a single node, read once so the
/// wrapper check and the rendered line don't re-query the same attributes.
/// `frame` is in the same global-screen coordinates as `windowOrigin`.
struct NodeFacts {
    let role: String
    let label: String?
    let identifier: String?
    let value: String?
    let selectedText: String?
    let enabled: Bool?
    let focused: Bool?
    let selected: Bool?
    let actions: [String]
    let frame: CGRect?
}

/// Accessors the generic traversal needs over an opaque node type. The live
/// implementation (`axTreeAccessors`) reads the accessibility API; tests supply
/// an in-memory tree.
struct TreeNodeAccessors<Node> {
    /// Full read for a node that will be materialized (emitted).
    let facts: (Node) -> NodeFacts
    /// Cheap role-only read, used to keep locator indices absolute while
    /// scanning past children that are windowed out.
    let role: (Node) -> String
    /// Cheap frame-only read (tight timeout), used by the viewport-intersection
    /// windowing fallback.
    let frame: (Node) -> CGRect?
    let children: (Node) -> [Node]
    /// The app's own on-screen slice of a collection (AXVisibleRows /
    /// AXVisibleChildren), or nil when it exposes none.
    let visibleCollectionChildren: (Node) -> [Node]?
    /// Total item count of a collection (AXRows), independent of how many are
    /// realized in the tree; nil when the node reports none.
    let collectionTotal: (Node) -> Int?
    /// Identity, for mapping a visible child back to its index among all
    /// children.
    let equals: (Node, Node) -> Bool
}

// MARK: - Dense-collection viewport windowing

/// The materialized on-screen window of a dense collection's children.
struct CollectionWindow {
    /// Indices (into the full children array) to materialize.
    let includedIndices: Set<Int>
    /// Scan children[0..<scanLimit] to keep locator indices absolute; beyond
    /// this the collection is entirely off-window.
    let scanLimit: Int
    /// Items past the window, for the summary line.
    let offscreen: Int
    /// "rows" or "items", for the summary line.
    let itemNoun: String
}

/// Indices whose frame vertically intersects `viewport` expanded by `margin`
/// (lists scroll vertically; horizontal extent is ignored). A child with an
/// unknown frame is always included — windowing must never *silently* drop an
/// actionable element. Pure and deterministic.
func viewportVisibleIndices(childFrames: [CGRect?], viewport: CGRect, margin: CGFloat) -> Set<Int> {
    let top = viewport.minY - margin
    let bottom = viewport.maxY + margin
    var included: Set<Int> = []
    for (index, frame) in childFrames.enumerated() {
        guard let frame else { included.insert(index); continue }
        if frame.maxY >= top && frame.minY <= bottom { included.insert(index) }
    }
    return included
}

/// Decide the on-screen window for a dense virtualized collection, or nil to
/// fall back to the default prefix (not a dense collection, too few children,
/// or nothing to window with). Prefers the app's own visible-rows list; else
/// filters children by viewport-frame intersection.
private func denseCollectionWindow<Node>(
    _ node: Node, role: String, children: [Node], accessors: TreeNodeAccessors<Node>
) -> CollectionWindow? {
    guard isDenseCollectionRole(role) else { return nil }
    let total = accessors.collectionTotal(node) ?? children.count
    guard children.count >= denseCollectionThreshold || total >= denseCollectionThreshold else {
        return nil
    }

    var includedIndices = Set<Int>()

    // Preferred: the app's own on-screen slice.
    if let visible = accessors.visibleCollectionChildren(node), !visible.isEmpty {
        for element in visible {
            if let index = children.firstIndex(where: { accessors.equals($0, element) }) {
                includedIndices.insert(index)
            }
        }
    }

    // Fallback: viewport-frame intersection. Bound the probe count so a huge
    // hung collection cannot cost more than a blink each; children past the
    // bound are treated as off-window.
    if includedIndices.isEmpty {
        guard let viewport = accessors.frame(node) else { return nil }
        let probeCount = min(children.count, 600)
        let frames = children.prefix(probeCount).map { accessors.frame($0) }
        includedIndices = viewportVisibleIndices(
            childFrames: frames, viewport: viewport, margin: viewport.height * 0.5)
    }

    guard !includedIndices.isEmpty else { return nil }

    // Safety cap: never materialize more than a full node's worth of children.
    if includedIndices.count > maxChildrenPerNode {
        includedIndices = Set(includedIndices.sorted().prefix(maxChildrenPerNode))
    }

    let scanLimit = min(children.count, (includedIndices.max() ?? -1) + 1)
    let offscreen = max(0, total - includedIndices.count)
    let noun = (role == "AXOutline" || role == "AXTable") ? "rows" : "items"
    return CollectionWindow(
        includedIndices: includedIndices, scanLimit: scanLimit, offscreen: offscreen, itemNoun: noun)
}

// MARK: - Generic traversal core

func buildTreeCore<Node>(
    root: Node, accessors: TreeNodeAccessors<Node>,
    windowOrigin: CGPoint, pixelsPerPoint: Double, generation: String,
    pathPrefix: [LocatorStep], maxElements: Int,
    skeleton: Bool, windowCollections: Bool
) -> BuiltTree {
    let maxNodes = clampedTreeBudget(maxElements)
    var lines: [String] = []
    var elements: [SnapshotElement] = []

    func pixelFrame(_ frame: CGRect?) -> [Double]? {
        guard let frame = frame.flatMap(sanitizedRect), sanitizedPoint(windowOrigin) != nil,
            pixelsPerPoint.isFinite
        else { return nil }
        let pixels = [
            ((frame.origin.x - windowOrigin.x) * pixelsPerPoint).rounded(),
            ((frame.origin.y - windowOrigin.y) * pixelsPerPoint).rounded(),
            (frame.width * pixelsPerPoint).rounded(),
            (frame.height * pixelsPerPoint).rounded(),
        ]
        return pixels.allSatisfy(\.isFinite) ? pixels : nil
    }

    var depthTruncated = false
    var budgetTruncated = false
    var coveragePartial = false

    func visit(_ element: Node, depth: Int, rawDepth: Int, path: [LocatorStep]) {
        guard elements.count < maxNodes else {
            budgetTruncated = true
            return
        }
        guard depth <= maxDepth, rawDepth <= maxRawDepth else {
            depthTruncated = true
            return
        }

        let facts = accessors.facts(element)
        let role = facts.role

        // Wrappers (never the tree root) pass their outline slot straight to
        // their children; childless wrappers vanish entirely.
        let wrapper =
            !path.isEmpty
            && isStructuralWrapper(
                role: role, label: facts.label, value: facts.value,
                focused: facts.focused == true, actions: facts.actions)

        var lineIndex: Int?
        if !wrapper {
            let id = "e\(elements.count)@\(generation)"
            let frame = pixelFrame(facts.frame)
            elements.append(
                SnapshotElement(
                    id: id, role: role, label: facts.label, path: path, frame: frame ?? [0, 0, 0, 0]))
            lines.append(describeLine(facts, id: id, frame: frame, depth: depth))
            lineIndex = lines.count - 1
        }

        let children = accessors.children(element)

        // Skeleton overview: a container past the shallow depth is kept as a
        // drill target (children_count) but not expanded.
        if skeleton, depth >= skeletonMaxDepth, !children.isEmpty {
            coveragePartial = true
            if let lineIndex {
                let total = accessors.collectionTotal(element) ?? children.count
                lines[lineIndex] += " children_count=\(total)"
            }
            return
        }

        let window =
            windowCollections
            ? denseCollectionWindow(element, role: role, children: children, accessors: accessors)
            : nil
        // Windowed perception caps per-node fanout to bound tokens. Non-windowed
        // callers (find, skill-replay) asked for the deep tree and are bounded
        // only by the element budget: a collection row past maxChildrenPerNode
        // must still materialize so find can match it and a skill recorded on it
        // can re-resolve its locator (resolveSkillLocator looks the row up by
        // path in the snapshot, so an unmaterialized row is unreachable).
        let scanLimit =
            window?.scanLimit
            ?? (windowCollections ? min(children.count, maxChildrenPerNode) : children.count)
        if scanLimit < children.count {
            coveragePartial = true
        }

        var roleCounts: [String: Int] = [:]
        for childIndex in 0..<children.count {
            guard childIndex < scanLimit else { break }
            let child = children[childIndex]
            // Keep the locator index absolute even for windowed-out children:
            // walkLocator (Snapshot.swift) resolves by index among same-role
            // siblings, so a relative index would mis-resolve.
            let childRole = accessors.role(child)
            let indexOfRole = roleCounts[childRole, default: 0]
            roleCounts[childRole] = indexOfRole + 1
            if let window, !window.includedIndices.contains(childIndex) { continue }
            visit(
                child, depth: wrapper ? depth : depth + 1, rawDepth: rawDepth + 1,
                path: path + [LocatorStep(role: childRole, indexOfRole: indexOfRole)])
            if elements.count >= maxNodes {
                if childIndex + 1 < scanLimit { budgetTruncated = true }
                break
            }
        }

        // Annotate the container's own line rather than emitting a standalone
        // line, so the outline stays one-line-per-element — the invariant
        // stabilizeTree (Snapshot.swift) relies on to carry ids across a
        // re-snapshot.
        if let window, window.offscreen > 0, let lineIndex {
            coveragePartial = true
            lines[lineIndex] +=
                " …\(window.offscreen) more \(window.itemNoun) off-screen; scroll the list and "
                + "re-read to load them, or use find to jump to a specific one"
        }
    }

    visit(root, depth: 0, rawDepth: 0, path: pathPrefix)

    if budgetTruncated {
        coveragePartial = true
        lines.append(
            "… tree truncated at \(maxNodes) elements. Call get_app_state with scope_element_id "
                + "set to a container id to expand just that subtree, or raise max_elements."
        )
    }
    if depthTruncated {
        lines.append(
            "… some branches exceed the nesting limit and were cut. Call get_app_state with "
                + "scope_element_id set to the deepest visible container to expand further."
        )
    }
    return BuiltTree(text: lines.joined(separator: "\n"), elements: elements, isPartial: coveragePartial || depthTruncated)
}

// MARK: - Live accessibility-backed accessors

/// @unchecked: AXUIElement is an immutable thread-safe CF handle; the struct
/// only carries the element by value through the generic traversal.
struct AXNode: @unchecked Sendable {
    let element: AXUIElement
}

func axTreeAccessors() -> TreeNodeAccessors<AXNode> {
    TreeNodeAccessors<AXNode>(
        facts: { node in
            let element = node.element
            AXUIElementSetMessagingTimeout(element, perElementAXTimeout)
            let role = axRole(element)
            return NodeFacts(
                role: role,
                label: snapshotLabel(element, role: role),
                identifier: axString(element, "AXIdentifier"),
                value: axString(element, kAXValueAttribute),
                selectedText: axString(element, kAXSelectedTextAttribute),
                enabled: axBool(element, kAXEnabledAttribute),
                focused: axBool(element, kAXFocusedAttribute),
                selected: axBool(element, kAXSelectedAttribute),
                actions: axActionNames(element),
                frame: axFrame(element)
            )
        },
        role: { node in
            AXUIElementSetMessagingTimeout(node.element, perElementAXTimeout)
            return axRole(node.element)
        },
        frame: { node in
            AXUIElementSetMessagingTimeout(node.element, viewportProbeAXTimeout)
            return axFrame(node.element)
        },
        children: { node in
            AXUIElementSetMessagingTimeout(node.element, perElementAXTimeout)
            return axElements(node.element, kAXChildrenAttribute).map(AXNode.init)
        },
        visibleCollectionChildren: { node in
            for attribute in ["AXVisibleRows", "AXVisibleChildren"] {
                let visible = axElements(node.element, attribute)
                if !visible.isEmpty { return visible.map(AXNode.init) }
            }
            return nil
        },
        collectionTotal: { node in
            guard let value = axAttribute(node.element, "AXRows"), let array = value as? [AnyObject]
            else { return nil }
            return array.count
        },
        equals: { CFEqual($0.element, $1.element) }
    )
}

func buildTree(
    window: AXUIElement, windowOrigin: CGPoint, pixelsPerPoint: Double, generation: String,
    pathPrefix: [LocatorStep] = [], maxElements: Int = defaultMaxTreeElements,
    skeleton: Bool = false, windowCollections: Bool = true
) -> BuiltTree {
    buildTreeCore(
        root: AXNode(element: window), accessors: axTreeAccessors(),
        windowOrigin: windowOrigin, pixelsPerPoint: pixelsPerPoint, generation: generation,
        pathPrefix: pathPrefix, maxElements: maxElements,
        skeleton: skeleton, windowCollections: windowCollections)
}

// MARK: - Labels and line rendering

/// Label as the snapshot stores it: title, description, placeholder, then an
/// informative role description. The stale-element identity re-check
/// (matchesIdentity in Snapshot.swift) must derive the live label through
/// this same chain, or elements labeled by a late fallback can never match.
func snapshotLabel(_ element: AXUIElement, role: String) -> String? {
    axString(element, kAXTitleAttribute)
        ?? axString(element, kAXDescriptionAttribute)
        ?? axString(element, "AXPlaceholderValue")
        ?? informativeRoleDescription(
            role: role, description: axString(element, kAXRoleDescriptionAttribute))
}

/// Default role descriptions that don't echo their role name and never add
/// signal: window subrole flavors, WebKit's web-area description, and
/// outline/table row flavors (System Settings would repeat "outline row" on
/// every row). Compared after normalization (lowercased, alphanumerics only).
private let genericRoleDescriptions: Set<String> = [
    "standardwindow", "floatingwindow", "dialog", "systemdialog",
    "htmlcontent", "outlinerow", "tablerow",
]

/// A role description worth using as a label-of-last-resort. Apps attach
/// real context to otherwise-anonymous controls ("close button" on window
/// chrome, "switch" on SwiftUI toggles, "banner" on landmark groups).
/// Standard controls merely localize their role ("button" for AXButton,
/// "text" for AXStaticText) — dropped, along with known generic defaults,
/// so label-poor native trees don't fill up with restated roles.
func informativeRoleDescription(role: String, description: String?) -> String? {
    guard let description else { return nil }
    func normalize(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
    let normalizedDescription = normalize(description)
    guard !normalizedDescription.isEmpty else { return nil }
    guard !normalize(role).contains(normalizedDescription) else { return nil }
    guard !genericRoleDescriptions.contains(normalizedDescription) else { return nil }
    return description
}

/// AXIdentifier trimmed for display on an unlabeled element's outline line.
/// Developer-assigned identifiers ("AddAccountButton", "sidebar.search")
/// are real signal for telling icon-only controls apart; auto-generated ids
/// are noise — skipped when more than half the characters are digits or
/// hyphens (UUIDs, numeric ids). Long identifiers truncate to 40 chars.
func displayableIdentifier(_ identifier: String?) -> String? {
    guard let identifier, !identifier.isEmpty else { return nil }
    let noise = identifier.filter { $0.isNumber || $0 == "-" }.count
    guard noise * 2 <= identifier.count else { return nil }
    guard identifier.count > 40 else { return identifier }
    return String(identifier.prefix(40)) + "…"
}

func describeLine(_ facts: NodeFacts, id: String, frame: [Double]?, depth: Int) -> String {
    var parts: [String] = ["\(id) \(facts.role)"]

    if let label = facts.label, !label.isEmpty {
        parts.append("\"\(clean(label))\"")
    } else if let identifier = displayableIdentifier(facts.identifier) {
        // Display-only: the identifier never enters SnapshotElement.label —
        // locator identity (and the skills built on it) must not change.
        parts.append("id=\"\(clean(identifier))\"")
    }
    if let frame, frame.count >= 4 {
        let coordinates = frame.prefix(4).map(integerDescription).joined(separator: ",")
        parts.append("(\(coordinates))")
    }
    if let value = facts.value, !value.isEmpty {
        parts.append("value=\"\(clean(truncate(value)))\"")
    }
    if let selected = facts.selectedText, !selected.isEmpty {
        parts.append("selected=\"\(clean(truncate(selected)))\"")
    }
    if facts.enabled == false {
        parts.append("disabled")
    }
    if facts.focused == true {
        parts.append("focused")
    }
    if facts.selected == true {
        parts.append("selected")
    }
    // Keep standard AX* actions; custom app actions often embed junk
    // (selector dumps, newlines) that pollutes the tree.
    let actions = facts.actions.filter { name in
        name.hasPrefix("AX") && name.allSatisfy { $0.isLetter || $0.isNumber }
    }
    if !actions.isEmpty {
        parts.append("actions=\(actions.map { String($0.dropFirst(2)) }.joined(separator: ","))")
    }

    return String(repeating: "\t", count: depth) + parts.joined(separator: " ")
}

private func truncate(_ value: String) -> String {
    guard value.count > maxValueLength else { return value }
    return String(value.prefix(maxValueLength)) + "… [+\(value.count - maxValueLength) chars; read_text returns the full value]"
}

private func clean(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\t", with: " ")
}
