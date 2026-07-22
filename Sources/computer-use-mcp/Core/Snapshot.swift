// App-state snapshots and the locator engine.
//
// Element ids ("e12") are positions in the most recent snapshot of an app.
// AX element references go stale whenever an app relayouts, so a snapshot
// stores a *locator* per element — the path of (role, index-among-same-role-
// siblings) steps from the window root — and actions re-resolve the locator
// against the live tree, retrying briefly to let the UI settle. This mirrors
// the lazily-resolved-locator pattern used by mature UI automation tools.
//
// Snapshots are persisted to disk so ids work across processes (the `serve`
// server and the `call` harness, or a restarted server).

import Foundation
#if os(macOS)
import ApplicationServices
import CryptoKit
#endif

struct LocatorStep: Codable, Equatable {
    let role: String
    /// Index among siblings that share this role.
    let indexOfRole: Int
}

struct SnapshotElement: Codable {
    let id: String
    let role: String
    let label: String?
    let path: [LocatorStep]
    /// Bounding box in screenshot pixel coordinates.
    let frame: [Double]
}

struct AppSnapshot: Codable {
    let pid: Int32
    let bundleIdentifier: String
    let windowTitle: String?
    /// Window origin in global screen coordinates (top-left origin).
    let windowOrigin: [Double]
    /// Multiplier from window points to screenshot pixels.
    let pixelsPerPoint: Double
    /// Window size in screenshot pixels, for coordinate bounds checks (the
    /// element list may be scoped to a subtree). Optional for old snapshots.
    let windowSize: [Double]?
    let createdAt: Date
    /// Generation tag baked into element ids (e.g. "e11@s3"), so an id from
    /// an older state is rejected loudly instead of silently resolving to
    /// whatever occupies that index now. Elements that survive a UI change
    /// carry their id (and so an older tag) forward — see stabilizeTree.
    let generation: String
    /// Hash of the id-normalized tree text, for unchanged-tree detection.
    /// Optional: predates some persisted snapshots.
    var treeFingerprint: String? = nil
    /// The rendered outline this snapshot was built from, kept for diffing
    /// the next capture against. Optional: predates some persisted snapshots.
    var treeText: String? = nil
    /// True when the element list covers a scoped subtree rather than the
    /// whole window; scoped snapshots are never diffed against.
    var scoped: Bool? = nil
    /// True when a whole-window capture omitted known-live elements because
    /// of truncation, skeleton depth, or collection windowing. Partial
    /// snapshots must not invalidate ids they did not observe.
    var partial: Bool? = nil
    let elements: [SnapshotElement]

    func element(withID id: String) -> SnapshotElement? {
        elements.first { $0.id == id }
    }

    /// Convert a screenshot pixel coordinate to global screen points.
    func screenPoint(fromScreenshotX x: Double, y: Double) -> CGPoint {
        CGPoint(
            x: windowOrigin[0] + x / pixelsPerPoint,
            y: windowOrigin[1] + y / pixelsPerPoint
        )
    }
}

/// Serializes snapshot capture and lookup so concurrent same-pid tool calls
/// cannot race on the generation counter. An in-memory cache is the source of
/// truth; disk is write-through so element ids survive across processes.
actor SnapshotStore {
    static let shared = SnapshotStore()

    private var cache: [pid_t: AppSnapshot] = [:]
    private var counters: [pid_t: Int] = [:]
    private var history: [pid_t: [AppSnapshot]] = [:]
    private let maxHistoryPerPid = 32

    private static var directory: URL {
        // Caches, not tmp: snapshot files must survive periodic temp cleaning
        // for cross-process id resolution (serve vs call, server restarts).
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("computer-use-mcp", isDirectory: true)
    }

    private static func url(forPid pid: pid_t) -> URL {
        directory.appendingPathComponent("snapshot-\(pid).json")
    }

    private static func historicalURL(forPid pid: pid_t, generation: String) -> URL {
        directory.appendingPathComponent("snapshot-\(pid)-\(generation).json")
    }

    /// Allocate the next generation, build the tree with it, and persist —
    /// all atomically, so a second same-pid capture cannot collide.
    ///
    /// When the rebuilt tree is identical to the previous snapshot's (same
    /// content, window placement, and scale — only the ids differ), the
    /// previous snapshot is kept and returned with `unchanged: true`. When it
    /// changed, elements that still resolve to the same place carry their
    /// previous id forward and a diff against the previous state is returned,
    /// so the caller can send only what changed while existing ids stay valid.
    func capture(
        pid: pid_t, bundleIdentifier: String, windowTitle: String?,
        windowOrigin: CGPoint, pixelsPerPoint: Double, windowSize: [Double]?, createdAt: Date,
        scoped: Bool = false,
        buildTree: (String) -> BuiltTree
    ) -> (snapshot: AppSnapshot, tree: BuiltTree, unchanged: Bool, diff: TreeDiff?) {
        // Always consult disk, not just on first touch: other server
        // processes (each MCP client spawns its own) persist to the same
        // file, and two servers must never issue the same generation tag for
        // the same pid. One decode serves both the counter and the diff base.
        let disk = loadFromDisk(pid)
        if let disk { remember(disk) }
        _ = loadHistory(forPid: pid)
        let diskGeneration = disk.map(Self.parseGeneration) ?? 0
        let next = max(counters[pid] ?? 0, diskGeneration) + 1
        counters[pid] = next
        let generation = "s\(next)"
        var tree = buildTree(generation)
        let fingerprint = treeFingerprint(tree.text)

        let previous = bestBaseline(
            forPid: pid,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            windowOrigin: windowOrigin,
            windowSize: windowSize,
            pixelsPerPoint: pixelsPerPoint,
            scoped: scoped
        )
        if let previous,
            !tree.isPartial,
            previous.partial != true,
            previous.treeFingerprint == fingerprint,
            previous.windowTitle == windowTitle,
            previous.windowOrigin == [windowOrigin.x, windowOrigin.y],
            previous.windowSize == windowSize,
            previous.bundleIdentifier == bundleIdentifier,
            previous.pixelsPerPoint == pixelsPerPoint,
            (previous.scoped == true) == scoped
        {
            let committedTree = Self.committedTree(from: previous, matching: tree)
            var committedSnapshot = previous
            if committedSnapshot.treeText == nil {
                committedSnapshot.treeText = committedTree.text
            }
            cache[pid] = committedSnapshot
            remember(committedSnapshot)
            persist(committedSnapshot)
            return (committedSnapshot, committedTree, true, nil)
        }

        var diff: TreeDiff?
        if let previous, !scoped, !tree.isPartial,
            previous.scoped != true, previous.partial != true,
            previous.bundleIdentifier == bundleIdentifier,
            previous.windowTitle == windowTitle,
            previous.windowOrigin == [windowOrigin.x, windowOrigin.y],
            previous.windowSize == windowSize,
            previous.pixelsPerPoint == pixelsPerPoint,
            let stabilized = stabilizeTree(tree, against: previous)
        {
            tree = stabilized.tree
            diff = stabilized.diff
        }

        let snapshot = AppSnapshot(
            pid: pid, bundleIdentifier: bundleIdentifier, windowTitle: windowTitle,
            windowOrigin: [windowOrigin.x, windowOrigin.y], pixelsPerPoint: pixelsPerPoint,
            windowSize: windowSize, createdAt: createdAt, generation: generation,
            treeFingerprint: fingerprint, treeText: tree.text, scoped: scoped,
            partial: tree.isPartial, elements: tree.elements
        )
        cache[pid] = snapshot
        remember(snapshot)
        persist(snapshot)
        return (snapshot, tree, false, diff)
    }

    func load(forPid pid: pid_t) -> AppSnapshot? {
        if let cached = cache[pid] { return cached }
        guard let disk = loadFromDisk(pid) else { return nil }
        cache[pid] = disk
        counters[pid] = max(counters[pid] ?? 0, Self.parseGeneration(disk))
        remember(disk)
        return disk
    }

    func resolveElementSnapshot(forPid pid: pid_t, elementID: String) -> (snapshot: AppSnapshot, element: SnapshotElement, isLatest: Bool)? {
        let latest = load(forPid: pid)
        if let latest, let element = latest.element(withID: elementID) {
            return (latest, element, true)
        }
        let snapshots = loadHistory(forPid: pid)
        for snapshot in snapshots.reversed() {
            if snapshot.generation == latest?.generation { continue }
            if let latest, snapshot.bundleIdentifier != latest.bundleIdentifier { continue }
            if let element = snapshot.element(withID: elementID),
                let current = Self.currentEquivalentSnapshotElement(
                    to: element, from: snapshot, among: snapshots)
            {
                return (current.snapshot, current.element, false)
            }
        }
        return nil
    }

    func resetForTesting(pid: pid_t) {
        clearMemoryForTesting(pid: pid)
        try? FileManager.default.removeItem(at: Self.url(forPid: pid))
        for url in historicalSnapshotURLs(forPid: pid) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func clearMemoryForTesting(pid: pid_t) {
        cache.removeValue(forKey: pid)
        counters.removeValue(forKey: pid)
        history.removeValue(forKey: pid)
    }

    private func remember(_ snapshot: AppSnapshot) {
        var snapshots = history[snapshot.pid] ?? []
        if let existingIndex = snapshots.firstIndex(where: { $0.generation == snapshot.generation }) {
            var merged = snapshot
            let existing = snapshots[existingIndex]
            if merged.treeFingerprint == nil { merged.treeFingerprint = existing.treeFingerprint }
            if merged.treeText == nil { merged.treeText = existing.treeText }
            if merged.scoped == nil { merged.scoped = existing.scoped }
            if merged.partial == nil { merged.partial = existing.partial }
            snapshots[existingIndex] = merged
        } else {
            snapshots.append(snapshot)
        }
        if snapshots.count > maxHistoryPerPid {
            snapshots.removeFirst(snapshots.count - maxHistoryPerPid)
        }
        history[snapshot.pid] = snapshots
    }

    private func bestBaseline(
        forPid pid: pid_t,
        bundleIdentifier: String,
        windowTitle: String?,
        windowOrigin: CGPoint,
        windowSize: [Double]?,
        pixelsPerPoint: Double,
        scoped: Bool
    ) -> AppSnapshot? {
        let candidates = history[pid] ?? []
        return candidates
            .filter {
                $0.bundleIdentifier == bundleIdentifier
                    && $0.windowTitle == windowTitle
                    && $0.windowOrigin == [windowOrigin.x, windowOrigin.y]
                    && $0.windowSize == windowSize
                    && $0.pixelsPerPoint == pixelsPerPoint
                    && ($0.scoped == true) == scoped
                    && $0.partial != true
            }
            .max { Self.parseGeneration($0) < Self.parseGeneration($1) }
    }

    private func loadFromDisk(_ pid: pid_t) -> AppSnapshot? {
        guard let data = try? Data(contentsOf: Self.url(forPid: pid)) else { return nil }
        return try? JSONDecoder().decode(AppSnapshot.self, from: data)
    }

    private func loadHistory(forPid pid: pid_t) -> [AppSnapshot] {
        let diskSnapshots = historicalSnapshotURLs(forPid: pid).compactMap { url -> AppSnapshot? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(AppSnapshot.self, from: data)
        }
        for snapshot in diskSnapshots {
            remember(snapshot)
            counters[pid] = max(counters[pid] ?? 0, Self.parseGeneration(snapshot))
        }
        return history[pid] ?? []
    }

    private func historicalSnapshotURLs(forPid pid: pid_t) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: nil
        ) else { return [] }
        let prefix = "snapshot-\(pid)-s"
        return entries.filter { url in
            url.lastPathComponent.hasPrefix(prefix) && url.pathExtension == "json"
        }.sorted { lhs, rhs in
            Self.generation(fromHistoricalFilename: lhs.lastPathComponent, pid: pid)
                < Self.generation(fromHistoricalFilename: rhs.lastPathComponent, pid: pid)
        }
    }

    private func persist(_ snapshot: AppSnapshot) {
        // The in-memory cache is the source of truth; disk only matters for
        // cross-process id resolution (serve vs call, restarts). Still, a
        // persist failure should leave a trace, not vanish.
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: Self.url(forPid: snapshot.pid), options: .atomic)
            try persistHistoricalData(for: snapshot)
        } catch {
            FileHandle.standardError.write(
                Data("[computer-use-mcp] snapshot persist failed for pid \(snapshot.pid): \(error)\n".utf8)
            )
        }
        pruneSnapshotHistory(forPid: snapshot.pid)
        pruneStaleFiles()
    }

    private func persistHistoricalData(for snapshot: AppSnapshot) throws {
        var historical = snapshot
        // Historical files only exist so ids returned by a peer process can
        // resolve after another session advances the canonical snapshot. Keep
        // the locator metadata, but do not retain rendered outline text with
        // AX values/selected text for every prior generation.
        historical.treeText = nil
        let historicalData = try JSONEncoder().encode(historical)
        try historicalData.write(
            to: Self.historicalURL(forPid: snapshot.pid, generation: snapshot.generation),
            options: .atomic
        )
    }

    /// Best-effort: drop snapshot files older than an hour so the temp dir
    /// doesn't accumulate files for exited apps / recycled pids.
    private func pruneStaleFiles() {
        let cutoff = Date(timeIntervalSinceNow: -3600)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for url in entries where url.lastPathComponent.hasPrefix("snapshot-") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func pruneSnapshotHistory(forPid pid: pid_t) {
        let urls = historicalSnapshotURLs(forPid: pid)
        guard urls.count > maxHistoryPerPid else { return }
        for url in urls.prefix(urls.count - maxHistoryPerPid) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func parseGeneration(_ snapshot: AppSnapshot) -> Int {
        Int(snapshot.generation.dropFirst()) ?? 0
    }

    private static func generation(fromHistoricalFilename filename: String, pid: pid_t) -> Int {
        let prefix = "snapshot-\(pid)-s"
        guard filename.hasPrefix(prefix), filename.hasSuffix(".json") else { return 0 }
        let start = filename.index(filename.startIndex, offsetBy: prefix.count)
        let end = filename.index(filename.endIndex, offsetBy: -".json".count)
        return Int(filename[start..<end]) ?? 0
    }

    private static func currentEquivalentSnapshotElement(
        to element: SnapshotElement, from candidate: AppSnapshot, among snapshots: [AppSnapshot]
    ) -> (snapshot: AppSnapshot, element: SnapshotElement)? {
        let candidateGeneration = parseGeneration(candidate)
        var current = (snapshot: candidate, element: element)
        for newer in snapshots where parseGeneration(newer) > candidateGeneration {
            guard sameWindowLineage(candidate, newer) else { continue }
            if let sameID = newer.element(withID: element.id) {
                current = (newer, sameID)
                continue
            }
            if let samePath = snapshotElement(atPath: element.path, in: newer) {
                guard snapshotElement(samePath, matchesIdentityOf: element) else { return nil }
                let stableIDElement = SnapshotElement(
                    id: element.id, role: samePath.role, label: samePath.label,
                    path: samePath.path, frame: samePath.frame)
                current = (newer, stableIDElement)
                continue
            }
            guard newer.scoped != true, newer.partial != true else { continue }
            guard let candidateFingerprint = candidate.treeFingerprint,
                let newerFingerprint = newer.treeFingerprint,
                candidateFingerprint == newerFingerprint
            else { return nil }
        }
        return current
    }

    private static func sameWindowLineage(_ lhs: AppSnapshot, _ rhs: AppSnapshot) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.windowTitle == rhs.windowTitle
            && lhs.windowOrigin == rhs.windowOrigin
            && lhs.windowSize == rhs.windowSize
            && lhs.pixelsPerPoint == rhs.pixelsPerPoint
            && (lhs.scoped == true || rhs.scoped != true)
    }

    private static func snapshotElement(atPath path: [LocatorStep], in snapshot: AppSnapshot) -> SnapshotElement? {
        snapshot.elements.first { $0.path == path }
    }

    private static func snapshotElement(_ lhs: SnapshotElement, matchesIdentityOf rhs: SnapshotElement) -> Bool {
        lhs.role == rhs.role && lhs.label == rhs.label
    }

    private static func committedTree(from snapshot: AppSnapshot, matching freshTree: BuiltTree) -> BuiltTree {
        guard let text = snapshot.treeText else {
            var lines = freshTree.text.components(separatedBy: "\n")
            for index in freshTree.elements.indices where index < snapshot.elements.count && index < lines.count {
                lines[index] = lines[index].replacingOccurrences(
                    of: freshTree.elements[index].id, with: snapshot.elements[index].id)
            }
            return BuiltTree(
                text: lines.joined(separator: "\n"), elements: snapshot.elements,
                isPartial: snapshot.partial == true)
        }
        return BuiltTree(text: text, elements: snapshot.elements, isPartial: snapshot.partial == true)
    }
}

/// Hash of the tree text with element ids normalized away, so two builds of
/// an identical UI fingerprint the same even though ids carry fresh
/// generation tags.
func treeFingerprint(_ treeText: String) -> String {
    let normalized = treeText.replacing(/e\d+@s\d+/, with: "e@")
    #if os(macOS)
    let digest = SHA256.hash(data: Data(normalized.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
    #else
    var hash: UInt64 = 14695981039346656037
    for byte in normalized.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1099511628211
    }
    return String(format: "%016llx", hash)
    #endif
}

/// What changed between the previous snapshot and a fresh capture, after id
/// stabilization. Entries are outline lines with a `~` (content changed),
/// `+` (new element), or `-` (element gone) prefix.
struct TreeDiff {
    let changed: [String]
    let added: [String]
    let removed: [String]
    let totalElements: Int

    var entryCount: Int { changed.count + added.count + removed.count }
    var text: String { (changed + added + removed).joined(separator: "\n") }
    /// Worth sending instead of the full tree: non-empty, and smaller than
    /// half the outline (a rewrite-everything diff is not a diff).
    var isCompact: Bool { entryCount > 0 && entryCount * 2 <= totalElements }

    /// True when the post-state diff contains any changed/added/removed line
    /// other than the acted target's own line. Without a target line,
    /// independence cannot be proven.
    func hasChangeIndependent(of target: SnapshotElement?) -> Bool {
        hasChangeIndependent(in: changed + added + removed, of: target) { _ in true }
    }

    /// Text-entry web corroboration is stricter than "some sibling changed":
    /// the independent line must carry the requested text in post-action
    /// changed/added content, or unrelated timers/deletions could be mistaken
    /// for proof that the write landed.
    func hasChangeIndependent(of target: SnapshotElement?, matching text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return hasChangeIndependent(in: changed + added, of: target) { line in
            String(line).localizedCaseInsensitiveContains(text)
        }
    }

    private func hasChangeIndependent(
        in entries: [String], of target: SnapshotElement?, where lineMatches: (String.SubSequence) -> Bool
    ) -> Bool {
        guard let target else { return false }
        let targetPrefix = target.id + " "
        return entries.contains { entry in
            let body = entry.dropFirst(2)
            return !body.hasPrefix(targetPrefix) && lineMatches(body)
        }
    }
}

/// Scroll-specific evidence from a post-action tree diff. A scroll verifier must
/// not treat arbitrary whole-window churn as success: movement is corroborated
/// only when the diff shows rows/children/text entering/leaving the viewport or
/// a surviving element's frame moving within the tree.
func scrollRelevantChange(in diff: TreeDiff?) -> Bool? {
    guard let diff else { return nil }
    let entries = diff.changed + diff.added + diff.removed
    guard !entries.isEmpty else { return false }
    return entries.contains(where: isScrollRelevantDiffEntry)
}

private func isScrollRelevantDiffEntry(_ entry: String) -> Bool {
    let line = String(entry.dropFirst(2))
    if line.contains("AXRow") || line.contains("AXCell") || line.contains("AXList")
        || line.contains("AXTable") || line.contains("AXOutline") || line.contains("AXWebArea")
    {
        return true
    }
    if line.contains("AXStaticText") || line.contains("AXTextField") || line.contains("AXTextArea") {
        return entry.hasPrefix("+ ") || entry.hasPrefix("- ")
    }
    return false
}

/// Carry element ids forward across a UI change and compute the diff.
///
/// An element that still resolves to the same locator path with the same role
/// and label is the same control, so it keeps its previous id — the agent's
/// references survive the change — and appears in the diff only if its
/// rendered line (value, frame, flags) differs. Elements at new paths are
/// added under fresh ids; previous paths with no counterpart are removed.
/// Returns nil when the previous snapshot cannot be diffed against (no stored
/// text, or line/element misalignment).
func stabilizeTree(_ tree: BuiltTree, against previous: AppSnapshot) -> (tree: BuiltTree, diff: TreeDiff)? {
    guard let previousText = previous.treeText else { return nil }
    let previousLines = previousText.components(separatedBy: "\n")
    guard previous.elements.count <= previousLines.count else { return nil }
    var newLines = tree.text.components(separatedBy: "\n")
    guard tree.elements.count <= newLines.count else { return nil }

    func pathKey(_ path: [LocatorStep]) -> String {
        path.map { "\($0.role)#\($0.indexOfRole)" }.joined(separator: "/")
    }
    func stripIndent(_ line: String) -> String {
        String(line.drop(while: { $0 == "\t" }))
    }

    // Matched entries are claimed (removed) as the new tree consumes them;
    // the leftovers are the removed elements, ordered by their old position.
    var previousByPath: [String: (element: SnapshotElement, line: String, index: Int)] = [:]
    for (index, element) in previous.elements.enumerated() {
        previousByPath[pathKey(element.path)] = (element, previousLines[index], index)
    }

    var elements = tree.elements
    var changed: [String] = []
    var added: [String] = []

    for index in elements.indices {
        let element = elements[index]
        let key = pathKey(element.path)
        if let prior = previousByPath[key],
            prior.element.role == element.role, prior.element.label == element.label
        {
            previousByPath.removeValue(forKey: key)
            // Carry the previous id so the agent's references stay valid. A
            // fresh build always mints current-generation ids, so after this
            // rewrite a plain line comparison means a content comparison.
            newLines[index] = newLines[index].replacingOccurrences(of: element.id, with: prior.element.id)
            elements[index] = SnapshotElement(
                id: prior.element.id, role: element.role, label: element.label,
                path: element.path, frame: element.frame
            )
            if prior.line != newLines[index] {
                changed.append("~ " + stripIndent(newLines[index]))
            }
        } else {
            added.append("+ " + stripIndent(newLines[index]))
        }
    }

    let removed = previousByPath.values.sorted { $0.index < $1.index }.map { leftover in
        let label = leftover.element.label.map { " \"\($0)\"" } ?? ""
        return "- \(leftover.element.id) \(leftover.element.role)\(label) is gone"
    }

    let stabilized = BuiltTree(text: newLines.joined(separator: "\n"), elements: elements, isPartial: tree.isPartial)
    return (stabilized, TreeDiff(changed: changed, added: added, removed: removed, totalElements: elements.count))
}

/// Re-resolve a snapshot element against the live accessibility tree.
/// Retries briefly so a UI that is mid-update can settle, and verifies the
/// resolved element still matches the snapshot's identity (role + label) so a
/// relayout turns into a clear stale-id error instead of a silent mis-click.
func resolveElement(_ element: SnapshotElement, in window: AXUIElement) async throws -> AXUIElement {
    let deadline = Date().addingTimeInterval(1.0)
    var lastFailure = "locator path did not resolve"

    repeat {
        if let resolved = walkLocator(element.path, from: window) {
            if matchesIdentity(resolved, of: element) {
                return resolved
            }
            let liveLabel = snapshotLabel(resolved, role: axRole(resolved)) ?? "no label"
            lastFailure =
                "the element at path \(describePath(element.path)) is now "
                + "\(axRole(resolved)) \"\(liveLabel)\", not what \(element.id) referred to"
        } else {
            lastFailure = "no element at path \(describePath(element.path))"
        }
        // Task.sleep, not Thread.sleep: this runs on the cooperative pool and
        // must suspend rather than block a shared executor thread.
        try? await Task.sleep(for: .milliseconds(150))
    } while Date() < deadline

    throw ToolError.failed(
        "Element \(element.id) (\(element.role)\(element.label.map { " \"\($0)\"" } ?? "")) "
            + "is stale: \(lastFailure). The UI has changed since that state was captured — "
            + "call get_app_state and use a fresh element id."
    )
}

/// Fail fast with a clear message when the target app has quit or crashed,
/// instead of surfacing a confusing stale-element or no-window error.
func requireAppAlive(_ app: ResolvedApp) throws {
    if appIsGone(pid: app.pid) {
        throw ToolError.failed(
            "\(app.name) (pid \(app.pid)) has quit or crashed since it was resolved. "
                + "Call list_apps to see what is running, then get_app_state on the new instance."
        )
    }
}

private func matchesIdentity(_ live: AXUIElement, of element: SnapshotElement) -> Bool {
    let role = axRole(live)
    return elementIdentityMatches(
        liveRole: role, liveLabel: snapshotLabel(live, role: role),
        expectedRole: element.role, expectedLabel: element.label
    )
}

/// Pure identity rule behind the stale-element re-check. Label identity is
/// only enforced when the snapshot had one (unlabeled containers are
/// identified by structure alone) and the role is not text entry — a text
/// field's label tracks its contents, so a mismatch there is churn, not a
/// different control.
func elementIdentityMatches(
    liveRole: String, liveLabel: String?, expectedRole: String, expectedLabel: String?
) -> Bool {
    guard liveRole == expectedRole else { return false }
    guard let expected = expectedLabel, !expected.isEmpty else { return true }
    if isTextEntryRole(expectedRole) { return true }
    return liveLabel == expected
}

private func walkLocator(_ path: [LocatorStep], from root: AXUIElement) -> AXUIElement? {
    var current = root
    for step in path {
        let children = axElements(current, kAXChildrenAttribute)
        let matching = children.filter { axRole($0) == step.role }
        guard step.indexOfRole < matching.count else { return nil }
        current = matching[step.indexOfRole]
    }
    return current
}

private func describePath(_ path: [LocatorStep]) -> String {
    path.map { "\($0.role)[\($0.indexOfRole)]" }.joined(separator: "/")
}
