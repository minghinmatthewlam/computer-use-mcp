#if os(macOS)
import CoreGraphics
#endif
import Foundation
import Testing

@testable import computer_use_mcp

@Suite struct TreeBuilderTests {
    @Test func nonFiniteFramesAreTreatedAsAbsentInTreeBuild() {
        let invalidFrames = [
            CGRect(x: CGFloat.nan, y: 10, width: 100, height: 50),
            CGRect(x: 10, y: CGFloat.infinity, width: 100, height: 50),
            CGRect(x: 10, y: 10, width: -CGFloat.infinity, height: 50),
        ]

        for (index, frame) in invalidFrames.enumerated() {
            let node = MinimalTreeNode(role: "AXButton", label: "Invalid \(index)", frame: frame)
            let built = buildMinimalTree(node)

            #expect(built.elements.count == 1)
            #expect(built.elements[0].frame == [0, 0, 0, 0])
            #expect(!built.text.contains("("))
            #expect(built.text.contains("Invalid \(index)"))
        }
    }

    @Test func describeLineSafelyFormatsNonFiniteFrameValues() {
        let facts = NodeFacts(
            role: "AXButton", label: "Bad frame", identifier: nil, value: nil,
            selectedText: nil, enabled: nil, focused: nil, selected: nil,
            actions: [], frame: nil)

        let line = describeLine(facts, id: "e0@s1", frame: [.nan, .infinity, -.infinity, 42], depth: 0)

        #expect(line.contains("(?,?,?,42)"))
        #expect(line.contains("Bad frame"))
    }

    @Test func nonFiniteWindowOriginOrScaleDropsFrame() {
        let node = MinimalTreeNode(role: "AXButton", label: "Scaled", frame: CGRect(x: 10, y: 20, width: 30, height: 40))

        let badOrigin = buildMinimalTree(node, windowOrigin: CGPoint(x: CGFloat.nan, y: 0))
        let badScale = buildMinimalTree(node, pixelsPerPoint: Double.infinity)

        #expect(badOrigin.elements[0].frame == [0, 0, 0, 0])
        #expect(badScale.elements[0].frame == [0, 0, 0, 0])
    }

    @Test func exactBudgetCompleteTreeIsNotPartial() {
        let node = MinimalTreeNode(
            role: "AXWindow", label: "Window",
            children: [MinimalTreeNode(role: "AXButton", label: "Done")]
        )

        let built = buildMinimalTree(node, maxElements: 2)

        #expect(built.elements.count == 2)
        #expect(built.isPartial == false)
        #expect(!built.text.contains("tree truncated"))
    }

    @Test func unlabeledActionlessGroupIsWrapper() {
        #expect(isStructuralWrapper(role: "AXGroup", label: nil, value: nil, focused: false, actions: []))
        // ShowMenu and ScrollToVisible are universal web-element noise, not signal.
        #expect(
            isStructuralWrapper(
                role: "AXGroup", label: "", value: nil, focused: false,
                actions: ["AXShowMenu", "AXScrollToVisible"]
            ))
    }

    @Test func labeledGroupIsKept() {
        #expect(!isStructuralWrapper(role: "AXGroup", label: "Sidebar", value: nil, focused: false, actions: []))
    }

    @Test func actionableGroupIsKept() {
        #expect(
            !isStructuralWrapper(
                role: "AXGroup", label: nil, value: nil, focused: false,
                actions: ["AXPress", "AXShowMenu"]
            ))
    }

    @Test func valuedOrFocusedGroupIsKept() {
        #expect(!isStructuralWrapper(role: "AXGroup", label: nil, value: "3", focused: false, actions: []))
        #expect(!isStructuralWrapper(role: "AXGroup", label: nil, value: nil, focused: true, actions: []))
    }

    @Test func nonGroupRolesAreNeverWrappers() {
        for role in ["AXButton", "AXStaticText", "AXWebArea", "AXWindow", "AXList"] {
            #expect(!isStructuralWrapper(role: role, label: nil, value: nil, focused: false, actions: []))
        }
    }
}

private final class MinimalTreeNode {
    let role: String
    let label: String?
    let frame: CGRect?
    let children: [MinimalTreeNode]

    init(role: String, label: String? = nil, frame: CGRect? = nil, children: [MinimalTreeNode] = []) {
        self.role = role
        self.label = label
        self.frame = frame
        self.children = children
    }
}

private func buildMinimalTree(
    _ node: MinimalTreeNode,
    windowOrigin: CGPoint = .zero,
    pixelsPerPoint: Double = 1,
    maxElements: Int = defaultMaxTreeElements
) -> BuiltTree {
    buildTreeCore(
        root: node,
        accessors: TreeNodeAccessors<MinimalTreeNode>(
            facts: { node in
                NodeFacts(
                    role: node.role, label: node.label, identifier: nil, value: nil,
                    selectedText: nil, enabled: nil, focused: nil, selected: nil,
                    actions: [], frame: node.frame)
            },
            role: { $0.role },
            frame: { $0.frame },
            children: { $0.children },
            visibleCollectionChildren: { _ in nil },
            collectionTotal: { _ in nil },
            equals: { $0 === $1 }
        ),
        windowOrigin: windowOrigin, pixelsPerPoint: pixelsPerPoint, generation: "s1",
        pathPrefix: [], maxElements: maxElements,
        skeleton: false, windowCollections: true)
}

@Suite struct RoleDescriptionFallbackTests {
    @Test func descriptionEchoingTheRoleIsDropped() {
        #expect(informativeRoleDescription(role: "AXButton", description: "button") == nil)
        #expect(informativeRoleDescription(role: "AXStaticText", description: "text") == nil)
        #expect(informativeRoleDescription(role: "AXPopUpButton", description: "pop up button") == nil)
        #expect(informativeRoleDescription(role: "AXCheckBox", description: "Check Box") == nil)
    }

    @Test func contextBeyondTheRoleIsKept() {
        #expect(informativeRoleDescription(role: "AXButton", description: "close button") == "close button")
        #expect(informativeRoleDescription(role: "AXCheckBox", description: "switch") == "switch")
        #expect(informativeRoleDescription(role: "AXGroup", description: "banner") == "banner")
    }

    @Test func genericDefaultsAreDropped() {
        #expect(informativeRoleDescription(role: "AXWindow", description: "standard window") == nil)
        #expect(informativeRoleDescription(role: "AXWebArea", description: "HTML content") == nil)
        #expect(informativeRoleDescription(role: "AXRow", description: "outline row") == nil)
    }

    @Test func missingOrEmptyDescriptionIsDropped() {
        #expect(informativeRoleDescription(role: "AXButton", description: nil) == nil)
        #expect(informativeRoleDescription(role: "AXButton", description: "") == nil)
        #expect(informativeRoleDescription(role: "AXButton", description: " ") == nil)
    }
}

@Suite struct DisplayableIdentifierTests {
    @Test func developerIdentifiersPassThrough() {
        #expect(displayableIdentifier("AddAccountButton") == "AddAccountButton")
        #expect(displayableIdentifier("sidebar.search") == "sidebar.search")
    }

    @Test func uuidAndNumericNoiseIsSkipped() {
        // More than half the characters are digits/hyphens: auto-generated.
        #expect(displayableIdentifier("12345678-1234-1234-1234-123456789012") == nil)
        #expect(displayableIdentifier("4211") == nil)
        #expect(displayableIdentifier("row-12-34-56") == nil)
    }

    @Test func halfNoiseIsStillShown() {
        // Exactly half digits is not "more than half".
        #expect(displayableIdentifier("ab12") == "ab12")
    }

    @Test func longIdentifiersTruncateTo40Chars() {
        let long = String(repeating: "a", count: 50)
        let shown = displayableIdentifier(long)
        #expect(shown == String(repeating: "a", count: 40) + "…")
    }

    @Test func missingOrEmptyIdentifierIsSkipped() {
        #expect(displayableIdentifier(nil) == nil)
        #expect(displayableIdentifier("") == nil)
    }
}
