import MCP
import Testing

@testable import computer_use_mcp

@Suite struct BatchToolTests {
    @Test func batchNeverContainsItselfAndAllowsWaitFor() {
        #expect(!batchableToolNames.contains("batch"))
        #expect(batchableToolNames.contains("wait_for"))
        #expect(batchableToolNames.contains("click"))
        #expect(batchableToolNames.contains("type_text"))
        // Not app-scoped: must not be batchable.
        #expect(!batchableToolNames.contains("open_url"))
        #expect(!batchableToolNames.contains("write_clipboard"))
    }

    @Test func batchIsGatedLikeOtherAppScopedMutatingTools() {
        #expect(isMutatingTool("batch"))
        #expect(appScopedToolNames.contains("batch"))
    }

    @Test func stoppedBatchOnlyClaimsPartialCommitAfterCompletedMutation() {
        let firstStepFailure = batchStoppedResult(
            step: 1, stepCount: 2, tool: "click", error: "failed",
            summary: [], definitePriorCommit: false, ambiguousCommit: false)
        let laterFailure = batchStoppedResult(
            step: 2, stepCount: 2, tool: "click", error: "failed",
            summary: ["✓ step 1 click"], definitePriorCommit: true, ambiguousCommit: false)

        #expect(commitStatus(for: firstStepFailure, tool: "batch") == .unknown)
        #expect(commitStatus(for: laterFailure, tool: "batch") == .partiallyCommitted)
    }

    @Test func rejectsMissingEmptyAndOversizedActions() async {
        await #expect(throws: ToolError.self) {
            _ = try await batchImpl(["app": .string("Finder")])
        }
        await #expect(throws: ToolError.self) {
            _ = try await batchImpl(["app": .string("Finder"), "actions": .array([])])
        }
        let tooMany = Value.array(
            Array(repeating: .object(["tool": .string("click")]), count: maxBatchActions + 1))
        await #expect(throws: ToolError.self) {
            _ = try await batchImpl(["app": .string("Finder"), "actions": tooMany])
        }
    }

    @Test func rejectsUnknownStepToolBeforeRunningAnything() async {
        let actions = Value.array([
            .object(["tool": .string("type_text"), "element_id": .string("e1@s1")]),
            .object(["tool": .string("open_url"), "url": .string("https://example.com")]),
        ])
        let message = await errorMessage {
            _ = try await batchImpl(["app": .string("Finder"), "actions": actions])
        }
        #expect(message.contains("open_url"))
        #expect(message.contains("cannot run in a batch"))
    }

    @Test func rejectsStepWithoutTool() async {
        let actions = Value.array([.object(["element_id": .string("e1@s1")])])
        let message = await errorMessage {
            _ = try await batchImpl(["app": .string("Finder"), "actions": actions])
        }
        #expect(message.contains("missing \"tool\""))
    }

    @Test func structuredFailureStopsDependentStepsAndUsesLeafCommitEvidence() async throws {
        let unsupported = leafResult(
            outcome: .unsupported(.unsupported, "disabled"),
            dispatched: false,
            commit: .notCommitted)
        let firstFailureProbe = BatchDispatchProbe(results: [unsupported])
        let firstFailure = try await batchImpl(
            batchArguments(stepCount: 3),
            dispatcher: { name, arguments in
                await firstFailureProbe.dispatch(name: name, arguments: arguments)
            })
        #expect(firstFailure.isError == true)
        #expect(await firstFailureProbe.callCount == 1)
        #expect(commitStatus(for: firstFailure, tool: "batch") != .partiallyCommitted)

        let committed = leafResult(
            outcome: .success("verified"),
            dispatched: true,
            commit: .committed)
        let laterFailureProbe = BatchDispatchProbe(results: [committed, unsupported])
        let laterFailure = try await batchImpl(
            batchArguments(stepCount: 3),
            dispatcher: { name, arguments in
                await laterFailureProbe.dispatch(name: name, arguments: arguments)
            })
        #expect(laterFailure.isError == true)
        #expect(await laterFailureProbe.callCount == 2)
        #expect(commitStatus(for: laterFailure, tool: "batch") == .partiallyCommitted)
    }

    @Test func verifiedIntermediateMutationsAdvanceWithoutScreenshots() async throws {
        let committed = leafResult(
            outcome: .success("verified"),
            dispatched: true,
            commit: .committed)
        let probe = BatchDispatchProbe(results: [committed, committed, committed])
        let result = try await batchImpl(
            batchArguments(stepCount: 3),
            dispatcher: { name, arguments in
                await probe.dispatch(name: name, arguments: arguments)
            })

        #expect(result.isError != true)
        #expect(await probe.callCount == 3)
        let calls = await probe.recordedArguments
        #expect(calls[0].bool("include_state") == true)
        #expect(calls[0].bool("include_screenshot") == false)
        #expect(calls[1].bool("include_state") == true)
        #expect(calls[1].bool("include_screenshot") == false)
    }

    @Test func responseModeIsForwardedOnlyToFinalModeAwareStep() async throws {
        let committed = leafResult(
            outcome: .success("verified"), dispatched: true, commit: .committed)
        let probe = BatchDispatchProbe(results: [committed, committed])
        var arguments = batchArguments(tools: ["type_text", "click"])
        arguments["state_response_mode"] = .string("full")

        _ = try await batchImpl(
            arguments,
            dispatcher: { name, arguments in
                await probe.dispatch(name: name, arguments: arguments)
            })

        let calls = await probe.recordedArguments
        #expect(calls[0]["state_response_mode"] == nil)
        #expect(calls[1].string("state_response_mode") == "full")
    }

    @Test func invalidFinalResponseModeCombinationFailsBeforeAnyStepRuns() async {
        let probe = BatchDispatchProbe(results: [.text("must not run")])
        var arguments = batchArguments(tools: ["type_text", "click"])
        arguments["state_response_mode"] = .string("full")
        guard case .array(var actions)? = arguments["actions"],
            case .object(var final)? = actions.last
        else {
            Issue.record("Expected batch actions")
            return
        }
        final["include_state"] = .bool(false)
        actions[actions.count - 1] = .object(final)
        arguments["actions"] = .array(actions)

        await #expect(throws: ToolError.self) {
            _ = try await batchImpl(
                arguments,
                dispatcher: { name, arguments in
                    await probe.dispatch(name: name, arguments: arguments)
                })
        }
        #expect(await probe.callCount == 0)
    }

    @Test func conflictingExplicitResponseModesFailBeforeAnyStepRuns() async {
        let probe = BatchDispatchProbe(results: [.text("must not run")])
        var arguments = batchArguments(tools: ["type_text", "click"])
        arguments["state_response_mode"] = .string("full")
        guard case .array(var actions)? = arguments["actions"],
            case .object(var final)? = actions.last
        else {
            Issue.record("Expected batch actions")
            return
        }
        final["state_response_mode"] = .string("auto")
        actions[actions.count - 1] = .object(final)
        arguments["actions"] = .array(actions)

        await #expect(throws: ToolError.self) {
            _ = try await batchImpl(
                arguments,
                dispatcher: { name, arguments in
                    await probe.dispatch(name: name, arguments: arguments)
                })
        }
        #expect(await probe.callCount == 0)
    }

    @Test func completedBatchAdjustsFinalPerceptionPayloadBytes() async throws {
        let metric = batchPerceptionMetric(encoding: .full, screenshotPNGBytes: 100)
        let leaf = leafResult(
            outcome: .success("done"), dispatched: true, commit: .committed)
            .withPerceptionMetric(metric)
        let probe = BatchDispatchProbe(results: [leaf])

        let result = try await batchImpl(
            batchArguments(tools: ["click"]),
            dispatcher: { name, arguments in
                await probe.dispatch(name: name, arguments: arguments)
            })

        guard let adjusted = perceptionMetric(in: result) else {
            Issue.record("Expected adjusted perception metric")
            return
        }
        let actualTextBytes = batchResultText(result).utf8.count
        #expect(adjusted.textBytes == actualTextBytes)
        #expect(adjusted.screenshotPNGBytes == 100)
        #expect(adjusted.responseEncoding == .full)
        #expect(adjusted.responseConstructionMs >= metric.responseConstructionMs)
        #expect(adjusted.perceptionMs - metric.perceptionMs
            == adjusted.responseConstructionMs - metric.responseConstructionMs)
    }

    @Test func stoppedBatchReplacesDeferredMetricWithActualErrorResponseShape() async throws {
        let metric = batchPerceptionMetric(encoding: .full, screenshotPNGBytes: 100)
        let leaf = leafResult(
            outcome: .effectNotVerified(.verification, "failed"),
            dispatched: true,
            commit: .unknown)
            .withPerceptionMetric(metric)
        let probe = BatchDispatchProbe(results: [leaf])

        let result = try await batchImpl(
            batchArguments(tools: ["click"]),
            dispatcher: { name, arguments in
                await probe.dispatch(name: name, arguments: arguments)
            })

        #expect(result.isError == true)
        guard let adjusted = perceptionMetric(in: result) else {
            Issue.record("Expected adjusted perception metric")
            return
        }
        #expect(adjusted.responseEncoding == .full)
        #expect(adjusted.textBytes == batchResultText(result).utf8.count)
        #expect(adjusted.screenshotPNGBytes == 0)
        #expect(adjusted.elementsReturned == 8)
    }

    @Test func failingIntermediateReplacesDeferredMetricWithActualStoppedResponse() async throws {
        let metric = batchPerceptionMetric(encoding: .diff, screenshotPNGBytes: 0)
        let failed = leafResult(
            outcome: .effectNotVerified(.verification, "failed"),
            dispatched: true,
            commit: .unknown)
            .withPerceptionMetric(metric)
        let probe = BatchDispatchProbe(results: [failed, .text("must not run")])

        let result = try await batchImpl(
            batchArguments(tools: ["type_text", "click"]),
            dispatcher: { name, arguments in
                await probe.dispatch(name: name, arguments: arguments)
            })

        #expect(await probe.callCount == 1)
        guard let adjusted = perceptionMetric(in: result) else {
            Issue.record("Expected adjusted perception metric")
            return
        }
        #expect(adjusted.responseEncoding == .diff)
        #expect(adjusted.textBytes == batchResultText(result).utf8.count)
        #expect(adjusted.elementsReturned == 8)
    }

    @Test func batchUsesAutoForIntermediateStateAndFullForAnyFinalStateTool() async throws {
        let probe = BatchDispatchProbe(results: [.text("ready"), .text("managed")])
        var arguments = batchArguments(tools: ["wait_for", "manage_window"])
        arguments["state_response_mode"] = .string("full")

        _ = try await batchImpl(
            arguments,
            dispatcher: { name, arguments in
                await probe.dispatch(name: name, arguments: arguments)
            })

        #expect(await probe.recordedModes == [.auto, .full])
    }

    @Test func intermediateStepCannotRequestResponseMode() async {
        let probe = BatchDispatchProbe(results: [.text("must not run")])
        var arguments = batchArguments(tools: ["wait_for", "click"])
        guard case .array(var actions)? = arguments["actions"],
            case .object(var first)? = actions.first
        else {
            Issue.record("Expected batch actions")
            return
        }
        first["state_response_mode"] = .string("full")
        actions[0] = .object(first)
        arguments["actions"] = .array(actions)

        await #expect(throws: ToolError.self) {
            _ = try await batchImpl(
                arguments,
                dispatcher: { name, arguments in
                    await probe.dispatch(name: name, arguments: arguments)
                })
        }
        #expect(await probe.callCount == 0)
    }

    @Test func mutationWithoutSuccessEvidenceStopsButLegacyReadOnlyAdvances() async throws {
        let unknownMutation = CallTool.Result.text("key posted")
            .mergingMetaField(
                actionTransactionMetaKey,
                .object(["commit_status": .string(ActionCommitStatus.unknown.rawValue)]))
        let committed = leafResult(
            outcome: .success("verified"),
            dispatched: true,
            commit: .committed)

        #expect(!leafResultSucceeded(unknownMutation, isMutating: true))

        let readOnlyProbe = BatchDispatchProbe(results: [.text("ready"), committed])
        let completed = try await batchImpl(
            batchArguments(tools: ["wait_for", "click"]),
            dispatcher: { name, arguments in
                await readOnlyProbe.dispatch(name: name, arguments: arguments)
            })
        #expect(completed.isError != true)
        #expect(await readOnlyProbe.callCount == 2)

        #expect(leafResultSucceeded(.text("legacy read"), isMutating: false))
        #expect(leafResultSucceeded(committed, isMutating: true))
    }

    @Test func noVerifierMutationIsFinalOnlyBeforeAnyStepRuns() async {
        let probe = BatchDispatchProbe(results: [.text("should not run")])
        await #expect(throws: ToolError.self) {
            _ = try await batchImpl(
                batchArguments(tools: ["press_key", "click"]),
                dispatcher: { name, arguments in
                    await probe.dispatch(name: name, arguments: arguments)
                })
        }
        #expect(await probe.callCount == 0)
        #expect(!batchIntermediateToolNames.contains("press_key"))
        #expect(!batchIntermediateToolNames.contains("select_text"))
        #expect(!batchIntermediateToolNames.contains("click"))
        #expect(!batchIntermediateToolNames.contains("drag"))
        #expect(batchIntermediateToolNames.contains("type_text"))
        #expect(batchIntermediateToolNames.contains("wait_for"))
    }

    @Test func unknownLeafEvidenceDoesNotBecomePartialCommit() {
        let failed = batchStoppedResult(
            step: 1, stepCount: 1, tool: "press_key", error: "unverified",
            summary: [], definitePriorCommit: false, ambiguousCommit: true)
        #expect(commitStatus(for: failed, tool: "batch") == .unknown)
    }

    @Test func successfulReadOnlyTailPreservesPriorCompositeEvidence() async throws {
        let committed = leafResult(
            outcome: .success("verified"), dispatched: true, commit: .committed)
        let probe = BatchDispatchProbe(results: [committed, .text("ready")])
        let result = try await batchImpl(
            batchArguments(tools: ["type_text", "wait_for"]),
            dispatcher: { name, arguments in
                await probe.dispatch(name: name, arguments: arguments)
            })
        #expect(result.isError != true)
        #expect(commitStatus(for: result, tool: "batch") == .committed)
    }

    @Test func legacyMutationIsAcceptedAsFinalOnly() async throws {
        let unknown = CallTool.Result.text("key posted")
            .mergingMetaField(
                actionTransactionMetaKey,
                .object(["commit_status": .string(ActionCommitStatus.unknown.rawValue)]))
        let probe = BatchDispatchProbe(results: [unknown])
        let result = try await batchImpl(
            batchArguments(tools: ["press_key"]),
            dispatcher: { name, arguments in
                await probe.dispatch(name: name, arguments: arguments)
            })
        #expect(result.isError != true)
        #expect(commitStatus(for: result, tool: "batch") == .unknown)
    }

    @Test func successfulMutatingTailMergesPriorCompositeEvidence() async throws {
        let committed = leafResult(
            outcome: .success("verified"), dispatched: true, commit: .committed)
        let noOp = leafResult(
            outcome: .success("already satisfied"), dispatched: false, commit: .notCommitted)
        let definiteProbe = BatchDispatchProbe(results: [committed, noOp])
        let definite = try await batchImpl(
            batchArguments(tools: ["type_text", "select_text"]),
            dispatcher: { name, arguments in
                await definiteProbe.dispatch(name: name, arguments: arguments)
            })
        #expect(definite.isError != true)
        #expect(commitStatus(for: definite, tool: "batch") == .committed)

        let unknown = CallTool.Result.text("delivery uncertain")
            .mergingMetaField(
                actionTransactionMetaKey,
                .object(["commit_status": .string(ActionCommitStatus.unknown.rawValue)]))
            .withActionOutcome(
                ActionOutcome.success("accepted").withDispatchSucceeded(true))
        let unknownProbe = BatchDispatchProbe(results: [unknown, noOp])
        let ambiguous = try await batchImpl(
            batchArguments(tools: ["type_text", "select_text"]),
            dispatcher: { name, arguments in
                await unknownProbe.dispatch(name: name, arguments: arguments)
            })
        #expect(ambiguous.isError != true)
        #expect(commitStatus(for: ambiguous, tool: "batch") == .unknown)
    }

    @Test func successfulReadOnlyOnlyBatchIsNotCommitted() async throws {
        let probe = BatchDispatchProbe(results: [.text("ready")])
        let result = try await batchImpl(
            batchArguments(tools: ["wait_for"]),
            dispatcher: { name, arguments in
                await probe.dispatch(name: name, arguments: arguments)
            })
        #expect(result.isError != true)
        #expect(commitStatus(for: result, tool: "batch") == .notCommitted)
    }
}

private actor BatchDispatchProbe {
    private var results: [CallTool.Result]
    private(set) var callCount = 0
    private(set) var recordedArguments: [[String: Value]] = []
    private(set) var recordedModes: [StateResponseMode] = []

    init(results: [CallTool.Result]) {
        self.results = results
    }

    func dispatch(name _: String, arguments: [String: Value]) -> CallTool.Result {
        recordedArguments.append(arguments)
        recordedModes.append(StateResponseContext.mode)
        defer { callCount += 1 }
        return results[min(callCount, results.count - 1)]
    }
}

private func batchArguments(stepCount: Int) -> [String: Value] {
    batchArguments(tools: Array(repeating: "type_text", count: stepCount))
}

private func batchArguments(tools: [String]) -> [String: Value] {
    [
        "app": .string("Fixture"),
        "actions": .array(
            tools.map { tool in
                .object(["tool": .string(tool), "element_id": .string("e1@s1")])
            }),
    ]
}

private func leafResult(
    outcome: ActionOutcome,
    dispatched: Bool,
    commit: ActionCommitStatus
) -> CallTool.Result {
    CallTool.Result.text(outcome.summary)
        .withActionOutcome(outcome.withDispatchSucceeded(dispatched))
        .mergingMetaField(
            actionTransactionMetaKey,
            .object(["commit_status": .string(commit.rawValue)]))
}

private func batchPerceptionMetric(
    encoding: StateResponseEncoding,
    screenshotPNGBytes: Int
) -> PerceptionMetric {
    PerceptionMetric(
        operation: "operation-1",
        tool: "state_result",
        appBundleIdentifier: "com.example.fixture",
        perceptionMs: 20,
        settleMs: 4,
        screenshotMs: screenshotPNGBytes == 0 ? 0 : 3,
        snapshotMs: 5,
        verificationMs: 2,
        responseConstructionMs: 1,
        otherMs: screenshotPNGBytes == 0 ? 8 : 5,
        elementsVisited: 10,
        elementsReturned: 8,
        partial: false,
        responseEncoding: encoding,
        textBytes: 4,
        screenshotPNGBytes: screenshotPNGBytes)
}

private func errorMessage(_ body: () async throws -> Void) async -> String {
    do {
        try await body()
        return ""
    } catch {
        return "\(error)"
    }
}
