import MCP
import Testing

@testable import computer_use_mcp

@Suite struct StateResponseModeTests {
    @Test func modeDefaultsToAuto() {
        #expect(stateResponseMode([:]) == .auto)
        #expect(stateResponseMode(["state_response_mode": .string("auto")]) == .auto)
        #expect(stateResponseMode(["state_response_mode": .string("full")]) == .full)
    }

    @Test(arguments: ["auto", "full"])
    func explicitModeIsRejectedWhenStateIsDisabled(_ mode: String) {
        #expect(throws: ToolError.self) {
            try validateStateResponseArguments(
                toolName: "click",
                arguments: [
                    "include_state": .bool(false),
                    "state_response_mode": .string(mode),
                ])
        }
    }

    @Test func invalidModeIsRejected() {
        #expect(throws: ToolError.self) {
            try validateStateResponseArguments(
                toolName: "click",
                arguments: ["state_response_mode": .string("diff")])
        }
    }

    @Test func dispatcherRejectsModeBeforeMutationResolution() async {
        let result = await dispatchTool(
            name: "click",
            arguments: [
                "app": .string("app-that-must-not-be-resolved"),
                "include_state": .bool(false),
                "state_response_mode": .string("full"),
            ])

        #expect(result.isError == true)
        guard case .text(let text, _, _)? = result.content.first else {
            Issue.record("Expected text error result")
            return
        }
        #expect(text.contains("state_response_mode"))
        #expect(text.contains("include_state"))
    }

    @Test func autoPreservesExistingEncodingSelection() {
        #expect(selectedStateResponseEncoding(
            unchanged: true, hasCompactDiff: false, detail: .reduced, mode: .auto) == .unchanged)
        #expect(selectedStateResponseEncoding(
            unchanged: false, hasCompactDiff: true, detail: .reduced, mode: .auto) == .diff)
        #expect(selectedStateResponseEncoding(
            unchanged: false, hasCompactDiff: false, detail: .reduced, mode: .auto) == .full)
        #expect(selectedStateResponseEncoding(
            unchanged: true, hasCompactDiff: true, detail: .full, mode: .auto) == .full)
        #expect(selectedStateResponseEncoding(
            unchanged: true, hasCompactDiff: true, detail: .noState, mode: .auto) == .none)
    }

    @Test func fullOverridesOnlyEncodingSelection() {
        for detail in [ScreenshotDetail.reduced, .none] {
            #expect(selectedStateResponseEncoding(
                unchanged: true, hasCompactDiff: true, detail: detail, mode: .full) == .full)
            #expect(selectedStateResponseEncoding(
                unchanged: false, hasCompactDiff: true, detail: detail, mode: .full) == .full)
        }
        #expect(selectedStateResponseEncoding(
            unchanged: false, hasCompactDiff: true, detail: .noState, mode: .full) == .none)
    }

    @Test func exclusiveTimingResidualIsNonnegative() {
        #expect(exclusiveOtherMilliseconds(
            total: 20, settle: 4, screenshot: 3, snapshot: 5,
            verification: 2, responseConstruction: 1) == 5)
        #expect(exclusiveOtherMilliseconds(
            total: 2, settle: 4, screenshot: 3, snapshot: 5,
            verification: 2, responseConstruction: 1) == 0)
    }
}
