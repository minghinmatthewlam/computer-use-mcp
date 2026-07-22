 #if os(macOS)
import CoreGraphics
#endif
import Foundation
import Testing

@testable import computer_use_mcp

private func lifecycleTree(
    generation: String,
    suffix: String = "",
    paths: [[LocatorStep]] = [[], [LocatorStep(role: "AXTextField", indexOfRole: 0)]],
    isPartial: Bool = false
) -> BuiltTree {
    var elements: [SnapshotElement] = []
    var lines: [String] = []
    for (index, path) in paths.enumerated() {
        let id = "e\(index)@\(generation)"
        let role = path.last?.role ?? "AXWindow"
        let label = index == 0 ? "Settings\(suffix)" : "Name\(suffix)"
        let frame = index == 0 ? [0.0, 0.0, 400.0, 300.0] : [20.0, 20.0, 120.0, 24.0]
        elements.append(SnapshotElement(id: id, role: role, label: label, path: path, frame: frame))
        let indent = index == 0 ? "" : "\t"
        lines.append("\(indent)\(id) \(role) \"\(label)\" (\(Int(frame[0])),\(Int(frame[1])),\(Int(frame[2])),\(Int(frame[3])))")
    }
    return BuiltTree(text: lines.joined(separator: "\n"), elements: elements, isPartial: isPartial)
}

private func captureLifecycleSnapshot(
    pid: pid_t,
    windowTitle: String? = "Settings",
    windowOrigin: CGPoint = .zero,
    scoped: Bool = false,
    buildTree: @Sendable (String) -> BuiltTree
) async -> (snapshot: AppSnapshot, tree: BuiltTree, unchanged: Bool, diff: TreeDiff?) {
    await SnapshotStore.shared.capture(
        pid: pid,
        bundleIdentifier: "com.example.lifecycle",
        windowTitle: windowTitle,
        windowOrigin: windowOrigin,
        pixelsPerPoint: 2,
        windowSize: [400, 300],
        createdAt: Date(timeIntervalSince1970: 0),
        scoped: scoped,
        buildTree: buildTree
    )
}

private func ids(in tree: BuiltTree) -> [String] {
    tree.elements.map(\.id)
}

@Suite struct GenerationLifecycleTests {
    @Test func unchangedFullCaptureReturnsOnlyCommittedResolvableIDs() async throws {
        let pid: pid_t = -10_001
        await SnapshotStore.shared.resetForTesting(pid: pid)
        defer { Task { await SnapshotStore.shared.resetForTesting(pid: pid) } }

        let first = await captureLifecycleSnapshot(pid: pid) { lifecycleTree(generation: $0) }
        #expect(first.unchanged == false)
        #expect(ids(in: first.tree) == ["e0@s1", "e1@s1"])

        let second = await captureLifecycleSnapshot(pid: pid) { lifecycleTree(generation: $0) }
        #expect(second.unchanged == true)
        #expect(second.snapshot.generation == "s1")
        #expect(ids(in: second.tree) == ["e0@s1", "e1@s1"])
        #expect(second.tree.text.contains("e1@s1 AXTextField"))
        #expect(!second.tree.text.contains("e1@s2"))

        for id in ids(in: second.tree) {
            let resolved = await SnapshotStore.shared.resolveElementSnapshot(forPid: pid, elementID: id)
            #expect(resolved?.element.id == id)
            #expect(resolved?.isLatest == true)
        }
    }

    @Test func unchangedStubGenerationClaimUsesSnapshotNumberingNotFreshBuildNumbering() async throws {
        let pid: pid_t = -10_002
        await SnapshotStore.shared.resetForTesting(pid: pid)
        defer { Task { await SnapshotStore.shared.resetForTesting(pid: pid) } }

        for suffix in 1...6 {
            _ = await captureLifecycleSnapshot(pid: pid) { generation in
                lifecycleTree(generation: generation, suffix: " \(suffix)")
            }
        }

        let carriedIDs = ["e42@s7", "e69@s7"]
        _ = await captureLifecycleSnapshot(pid: pid) { generation in
            var tree = lifecycleTree(generation: generation)
            let rewritten = zip(tree.elements, carriedIDs).map { element, id in
                SnapshotElement(id: id, role: element.role, label: element.label, path: element.path, frame: element.frame)
            }
            for (oldID, newID) in zip(tree.elements.map(\.id), carriedIDs) {
                tree = BuiltTree(
                    text: tree.text.replacingOccurrences(of: oldID, with: newID),
                    elements: rewritten
                )
            }
            return tree
        }

        let unchanged = await captureLifecycleSnapshot(pid: pid) { lifecycleTree(generation: $0) }
        #expect(unchanged.unchanged == true)
        #expect(unchanged.snapshot.generation == "s7")
        #expect(ids(in: unchanged.tree) == carriedIDs)
        #expect(unchanged.tree.text.contains("e69@s7 AXTextField"))
        #expect(!unchanged.tree.text.contains("e1@s8"))

        let idFromClaimedGeneration = "e69@s7"
        let resolved = await SnapshotStore.shared.resolveElementSnapshot(forPid: pid, elementID: idFromClaimedGeneration)
        #expect(resolved?.element.id == idFromClaimedGeneration)
        #expect(resolved?.snapshot.generation == "s7")
    }

    @Test func changedCaptureAfterMemoryClearKeepsDiffableCanonicalBaseline() async throws {
        let pid: pid_t = -10_012
        await SnapshotStore.shared.resetForTesting(pid: pid)
        defer { Task { await SnapshotStore.shared.resetForTesting(pid: pid) } }

        let original = await captureLifecycleSnapshot(pid: pid) { lifecycleTree(generation: $0) }
        #expect(ids(in: original.tree) == ["e0@s1", "e1@s1"])

        await SnapshotStore.shared.clearMemoryForTesting(pid: pid)
        let buttonPath = [LocatorStep(role: "AXButton", indexOfRole: 0)]
        let changed = await captureLifecycleSnapshot(pid: pid) { generation in
            lifecycleTree(
                generation: generation,
                paths: [[], [LocatorStep(role: "AXTextField", indexOfRole: 0)], buttonPath]
            )
        }

        #expect(changed.unchanged == false)
        #expect(changed.diff?.added.isEmpty == false)
        #expect(Array(ids(in: changed.tree).prefix(2)) == ["e0@s1", "e1@s1"])
    }

    @Test func newerChangedFullCaptureInvalidatesHistoricalIDs() async throws {
        let pid: pid_t = -10_004
        await SnapshotStore.shared.resetForTesting(pid: pid)
        defer { Task { await SnapshotStore.shared.resetForTesting(pid: pid) } }

        let before = await captureLifecycleSnapshot(pid: pid) { lifecycleTree(generation: $0) }
        let oldID = try #require(before.tree.elements.last?.id)
        #expect(oldID == "e1@s1")

        let after = await captureLifecycleSnapshot(pid: pid) { lifecycleTree(generation: $0, suffix: " changed") }
        #expect(after.unchanged == false)
        #expect(after.snapshot.generation == "s2")
        #expect(after.snapshot.element(withID: oldID) == nil)

        await SnapshotStore.shared.clearMemoryForTesting(pid: pid)
        let resolved = await SnapshotStore.shared.resolveElementSnapshot(forPid: pid, elementID: oldID)
        #expect(resolved == nil)
    }

    @Test func newerPartialCaptureDoesNotInvalidateHistoricalIDsItDidNotObserve() async throws {
        let pid: pid_t = -10_005
        await SnapshotStore.shared.resetForTesting(pid: pid)
        defer { Task { await SnapshotStore.shared.resetForTesting(pid: pid) } }

        let before = await captureLifecycleSnapshot(pid: pid) { lifecycleTree(generation: $0) }
        let oldID = try #require(before.tree.elements.last?.id)
        #expect(oldID == "e1@s1")

        let partial = await captureLifecycleSnapshot(pid: pid) { generation in
            lifecycleTree(generation: generation, suffix: " partial", paths: [[]], isPartial: true)
        }
        #expect(partial.unchanged == false)
        #expect(partial.snapshot.generation == "s2")
        #expect(partial.snapshot.element(withID: oldID) == nil)
        #expect(partial.diff == nil)

        await SnapshotStore.shared.clearMemoryForTesting(pid: pid)
        let resolved = await SnapshotStore.shared.resolveElementSnapshot(forPid: pid, elementID: oldID)
        #expect(resolved?.element.id == oldID)
        #expect(resolved?.snapshot.generation == "s1")
    }

    @Test func newerSameFrameTitleChangeDoesNotRemapHistoricalIDs() async throws {
        let pid: pid_t = -10_006
        await SnapshotStore.shared.resetForTesting(pid: pid)
        defer { Task { await SnapshotStore.shared.resetForTesting(pid: pid) } }

        let before = await captureLifecycleSnapshot(pid: pid, windowTitle: "Settings") { lifecycleTree(generation: $0) }
        let oldID = try #require(before.tree.elements.last?.id)
        #expect(oldID == "e1@s1")

        let renamed = await captureLifecycleSnapshot(pid: pid, windowTitle: "Renamed Settings") {
            lifecycleTree(generation: $0)
        }
        #expect(renamed.unchanged == false)
        #expect(renamed.snapshot.generation == "s2")
        #expect(renamed.snapshot.element(withID: oldID) == nil)

        await SnapshotStore.shared.clearMemoryForTesting(pid: pid)
        let resolved = await SnapshotStore.shared.resolveElementSnapshot(forPid: pid, elementID: oldID)
        #expect(resolved?.element.id == oldID)
        #expect(resolved?.snapshot.windowTitle == "Settings")
    }

    @Test func unrelatedWindowCaptureDoesNotRemapHistoricalIDs() async throws {
        let pid: pid_t = -10_007
        await SnapshotStore.shared.resetForTesting(pid: pid)
        defer { Task { await SnapshotStore.shared.resetForTesting(pid: pid) } }

        let firstWindow = await captureLifecycleSnapshot(pid: pid, windowTitle: "Settings") {
            lifecycleTree(generation: $0)
        }
        let idFromFirstWindow = try #require(firstWindow.tree.elements.last?.id)
        #expect(idFromFirstWindow == "e1@s1")

        let secondWindow = await captureLifecycleSnapshot(
            pid: pid, windowTitle: "Other", windowOrigin: CGPoint(x: 100, y: 100)
        ) { lifecycleTree(generation: $0) }
        #expect(secondWindow.snapshot.generation == "s2")
        #expect(secondWindow.snapshot.element(withID: idFromFirstWindow) == nil)

        await SnapshotStore.shared.clearMemoryForTesting(pid: pid)
        let resolved = await SnapshotStore.shared.resolveElementSnapshot(forPid: pid, elementID: idFromFirstWindow)
        #expect(resolved?.element.id == idFromFirstWindow)
        #expect(resolved?.snapshot.windowTitle == "Settings")
    }

    @Test func unchangedHistoricalWindowReusesPersistedBaselineAfterProcessMemoryClears() async throws {
        let pid: pid_t = -10_010
        await SnapshotStore.shared.resetForTesting(pid: pid)
        defer { Task { await SnapshotStore.shared.resetForTesting(pid: pid) } }

        let firstWindow = await captureLifecycleSnapshot(pid: pid, windowTitle: "Window A") {
            lifecycleTree(generation: $0)
        }
        #expect(ids(in: firstWindow.tree) == ["e0@s1", "e1@s1"])

        let secondWindow = await captureLifecycleSnapshot(
            pid: pid, windowTitle: "Window B", windowOrigin: CGPoint(x: 50, y: 50)
        ) { lifecycleTree(generation: $0) }
        #expect(secondWindow.snapshot.generation == "s2")

        await SnapshotStore.shared.clearMemoryForTesting(pid: pid)
        let unchangedFirstWindow = await captureLifecycleSnapshot(pid: pid, windowTitle: "Window A") {
            lifecycleTree(generation: $0)
        }
        #expect(unchangedFirstWindow.unchanged == true)
        #expect(unchangedFirstWindow.snapshot.generation == "s1")
        #expect(ids(in: unchangedFirstWindow.tree) == ["e0@s1", "e1@s1"])

        await SnapshotStore.shared.clearMemoryForTesting(pid: pid)
        let canonical = await SnapshotStore.shared.load(forPid: pid)
        #expect(canonical?.generation == "s1")
        #expect(canonical?.windowTitle == "Window A")
    }

    @Test func fullCaptureReusesCompleteBaselineAfterInterveningPartialSnapshot() async throws {
        let pid: pid_t = -10_011
        await SnapshotStore.shared.resetForTesting(pid: pid)
        defer { Task { await SnapshotStore.shared.resetForTesting(pid: pid) } }

        let full = await captureLifecycleSnapshot(pid: pid) { lifecycleTree(generation: $0) }
        #expect(ids(in: full.tree) == ["e0@s1", "e1@s1"])

        let partial = await captureLifecycleSnapshot(pid: pid) { generation in
            lifecycleTree(generation: generation, paths: [[]], isPartial: true)
        }
        #expect(partial.unchanged == false)
        #expect(partial.snapshot.generation == "s2")

        let unchangedFull = await captureLifecycleSnapshot(pid: pid) { lifecycleTree(generation: $0) }
        #expect(unchangedFull.unchanged == true)
        #expect(unchangedFull.snapshot.generation == "s1")
        #expect(ids(in: unchangedFull.tree) == ["e0@s1", "e1@s1"])
    }

    @Test func unchangedPartialCaptureDoesNotReusePotentiallyWindowedIDs() async throws {
        let pid: pid_t = -10_008
        await SnapshotStore.shared.resetForTesting(pid: pid)
        defer { Task { await SnapshotStore.shared.resetForTesting(pid: pid) } }

        let first = await captureLifecycleSnapshot(pid: pid) { generation in
            lifecycleTree(generation: generation, paths: [[]], isPartial: true)
        }
        #expect(first.unchanged == false)
        #expect(ids(in: first.tree) == ["e0@s1"])

        let second = await captureLifecycleSnapshot(pid: pid) { generation in
            lifecycleTree(generation: generation, paths: [[]], isPartial: true)
        }
        #expect(second.unchanged == false)
        #expect(second.snapshot.generation == "s2")
        #expect(ids(in: second.tree) == ["e0@s2"])
    }

    @Test func historicalResolutionKeepsCallerIDWhenRemappedThroughPartialSamePath() async throws {
        let pid: pid_t = -10_013
        await SnapshotStore.shared.resetForTesting(pid: pid)
        defer { Task { await SnapshotStore.shared.resetForTesting(pid: pid) } }

        let scopedPath = [LocatorStep(role: "AXTextField", indexOfRole: 0)]
        let scoped = await captureLifecycleSnapshot(pid: pid, scoped: true) { generation in
            lifecycleTree(generation: generation, paths: [scopedPath])
        }
        let oldID = try #require(scoped.tree.elements.first?.id)
        #expect(oldID == "e0@s1")

        let partialScoped = await captureLifecycleSnapshot(pid: pid, scoped: true) { generation in
            lifecycleTree(generation: generation, paths: [scopedPath], isPartial: true)
        }
        #expect(partialScoped.snapshot.generation == "s2")
        #expect(partialScoped.snapshot.element(withID: oldID) == nil)

        await SnapshotStore.shared.clearMemoryForTesting(pid: pid)
        let resolved = await SnapshotStore.shared.resolveElementSnapshot(forPid: pid, elementID: oldID)
        #expect(resolved?.snapshot.generation == "s2")
        #expect(resolved?.element.id == oldID)
    }

    @Test func newerFullCaptureInvalidatesHistoricalScopedIDsItObservesChanged() async throws {
        let pid: pid_t = -10_009
        await SnapshotStore.shared.resetForTesting(pid: pid)
        defer { Task { await SnapshotStore.shared.resetForTesting(pid: pid) } }

        let scopedPath = [LocatorStep(role: "AXTextField", indexOfRole: 0)]
        let scoped = await captureLifecycleSnapshot(pid: pid, scoped: true) { generation in
            lifecycleTree(generation: generation, paths: [scopedPath])
        }
        let scopedID = try #require(scoped.tree.elements.first?.id)
        #expect(scopedID == "e0@s1")

        let full = await captureLifecycleSnapshot(pid: pid) { lifecycleTree(generation: $0, suffix: " changed") }
        #expect(full.snapshot.generation == "s2")
        #expect(full.snapshot.element(withID: scopedID) == nil)

        await SnapshotStore.shared.clearMemoryForTesting(pid: pid)
        let resolved = await SnapshotStore.shared.resolveElementSnapshot(forPid: pid, elementID: scopedID)
        #expect(resolved == nil)
    }

    @Test func interleavedScopedCaptureDoesNotInvalidateIDsReturnedToAnotherSession() async throws {
        let pid: pid_t = -10_003
        await SnapshotStore.shared.resetForTesting(pid: pid)
        defer { Task { await SnapshotStore.shared.resetForTesting(pid: pid) } }

        let sessionA = await captureLifecycleSnapshot(pid: pid) { lifecycleTree(generation: $0) }
        let idReturnedToSessionA = try #require(sessionA.tree.elements.last?.id)
        #expect(idReturnedToSessionA == "e1@s1")

        let scopedPath = [LocatorStep(role: "AXTextField", indexOfRole: 0)]
        let sessionB = await captureLifecycleSnapshot(pid: pid, scoped: true) { generation in
            lifecycleTree(generation: generation, paths: [scopedPath])
        }
        #expect(sessionB.unchanged == false)
        #expect(sessionB.snapshot.generation == "s2")
        #expect(sessionB.snapshot.element(withID: idReturnedToSessionA) == nil)

        let resolved = await SnapshotStore.shared.resolveElementSnapshot(forPid: pid, elementID: idReturnedToSessionA)
        #expect(resolved?.element.id == idReturnedToSessionA)
        #expect(resolved?.snapshot.generation == "s1")
        #expect(resolved?.isLatest == false)

        await SnapshotStore.shared.clearMemoryForTesting(pid: pid)
        let crossProcessResolved = await SnapshotStore.shared.resolveElementSnapshot(forPid: pid, elementID: idReturnedToSessionA)
        #expect(crossProcessResolved?.element.id == idReturnedToSessionA)
        #expect(crossProcessResolved?.snapshot.generation == "s1")
        #expect(crossProcessResolved?.isLatest == false)
    }
}
