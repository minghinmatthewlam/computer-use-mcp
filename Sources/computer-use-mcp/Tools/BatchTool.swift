// batch — run a short sequence of actions against one app in a single call.
//
// Each step goes through the normal dispatch funnel, so every per-step
// guarantee holds: safety confirmation, interference yield, URL policy,
// element re-resolution. Intermediate steps skip state for speed; the final
// step returns fresh state (a compact diff when little changed). The batch
// stops at the first failing step — a stale element id is the built-in
// "the UI didn't do what I expected" brake — and reports what already ran.

import Foundation
import MCP

let maxBatchActions = 10

/// Tools a batch may contain: the app-scoped action set plus wait_for (for
/// sequences that trigger loading). Never batch itself, and nothing that
/// targets a different app — one app per batch keeps lease arbitration and
/// the URL/interference gates coherent.
let batchableToolNames: Set<String> = appScopedToolNames.subtracting(["batch", "run_skill"]).union(["wait_for"])
let batchIntermediateToolNames: Set<String> = [
    "type_text", "scroll", "set_value", "perform_secondary_action",
    "click_menu_item", "page", "manage_window", "wait_for",
]

func batchImpl(
    _ args: [String: Value],
    dispatcher: LocalToolDispatcher = dispatchTool
) async throws -> CallTool.Result {
    let appName = try args.requireString("app")
    guard case .array(let rawActions)? = args["actions"] else {
        throw ToolError.invalidArguments("\"actions\" (array of {\"tool\": …, …} objects) is required.")
    }
    guard !rawActions.isEmpty else {
        throw ToolError.invalidArguments("\"actions\" must contain at least one step.")
    }
    guard rawActions.count <= maxBatchActions else {
        throw ToolError.invalidArguments(
            "\"actions\" is limited to \(maxBatchActions) steps; split longer sequences.")
    }

    // Validate every step before running any: a typo in step 4 must not
    // leave steps 1-3 already performed.
    var steps: [(tool: String, arguments: [String: Value])] = []
    for (index, raw) in rawActions.enumerated() {
        guard case .object(let fields) = raw else {
            throw ToolError.invalidArguments("actions[\(index)] must be an object with a \"tool\" key.")
        }
        guard let tool = fields["tool"]?.stringValue else {
            throw ToolError.invalidArguments("actions[\(index)] is missing \"tool\".")
        }
        guard batchableToolNames.contains(tool) else {
            throw ToolError.invalidArguments(
                "actions[\(index)]: \"\(tool)\" cannot run in a batch. Allowed steps: "
                    + batchableToolNames.sorted().joined(separator: ", ") + ".")
        }
        if index < rawActions.count - 1, !batchIntermediateToolNames.contains(tool) {
            throw ToolError.invalidArguments(
                "actions[\(index)]: \"\(tool)\" cannot be an intermediate batch step because it "
                    + "does not emit structured success evidence. Put it last, or run the next "
                    + "dependent action in a separate call.")
        }
        if index < rawActions.count - 1, fields["state_response_mode"] != nil {
            throw ToolError.invalidArguments(
                "actions[\(index)]: state_response_mode is only valid on the final batch step.")
        }
        var arguments = fields
        arguments["tool"] = nil
        arguments["app"] = .string(appName)
        try validateStateResponseArguments(toolName: tool, arguments: arguments)
        steps.append((tool, arguments))
    }

    let last = steps[steps.count - 1]
    var finalArguments = last.arguments
    if let includeScreenshot = args["include_screenshot"] {
        finalArguments["include_screenshot"] = includeScreenshot
    }
    if let batchMode = args.string("state_response_mode"),
        let stepMode = finalArguments.string("state_response_mode"),
        batchMode != stepMode
    {
        throw ToolError.invalidArguments(
            "Batch state_response_mode \"\(batchMode)\" conflicts with final step state_response_mode \"\(stepMode)\".")
    }
    if stateResponseModeToolNames.contains(last.tool),
        let responseMode = args["state_response_mode"]
    {
        finalArguments["state_response_mode"] = responseMode
    }
    try validateStateResponseArguments(toolName: last.tool, arguments: finalArguments)

    var summary: [String] = []
    var definitePriorCommit = false
    var ambiguousCommit = false
    func stopped(atStep step: Int, tool: String, error: String) -> CallTool.Result {
        batchStoppedResult(
            step: step, stepCount: steps.count, tool: tool, error: error,
            summary: summary, definitePriorCommit: definitePriorCommit,
            ambiguousCommit: ambiguousCommit
        )
    }

    for (index, step) in steps.dropLast().enumerated() {
        var arguments = step.arguments
        if isMutatingTool(step.tool) {
            // A dependent mutation may only advance after a structured
            // verifier success. Keep state recapture, but suppress the
            // intermediate screenshot to avoid needless payload cost.
            arguments["include_state"] = .bool(true)
            arguments["include_screenshot"] = .bool(false)
        } else {
            arguments["include_state"] = .bool(false)
        }
        let result = await StateResponseContext.$mode.withValue(.auto) {
            await PerceptionMetricRecordingContext.$deferred.withValue(true) {
                await dispatcher(step.tool, arguments)
            }
        }
        let text = batchResultText(result)
        if !leafResultSucceeded(result, isMutating: isMutatingTool(step.tool)) {
            if isMutatingTool(step.tool) {
                updateCompositeEvidence(
                    leafCommitEvidence(result),
                    definite: &definitePriorCommit,
                    ambiguous: &ambiguousCommit)
            }
            let responseConstructionStart = ContinuousClock.now
            let stoppedResult = stopped(atStep: index + 1, tool: step.tool, error: text)
            let leafEncoding = perceptionMetric(in: result)?.responseEncoding ?? .none
            let addedResponseConstructionMs = perceptionDurationMilliseconds(
                responseConstructionStart.duration(to: .now))
            return await recordingDeferredPerceptionMetric(
                from: result,
                attachingTo: stoppedResult,
                addedResponseConstructionMs: addedResponseConstructionMs,
                replacingEncoding: leafEncoding,
                replacingTextBytes: batchResultText(stoppedResult).utf8.count,
                replacingScreenshotPNGBytes: 0)
        }
        _ = await recordingDeferredPerceptionMetric(from: result)
        if isMutatingTool(step.tool) {
            updateCompositeEvidence(
                leafCommitEvidence(result),
                definite: &definitePriorCommit,
                ambiguous: &ambiguousCommit)
        }
        summary.append("✓ step \(index + 1) \(step.tool): \(firstLine(text))")
    }

    let finalMode = args.string("state_response_mode")
        .flatMap(StateResponseMode.init(rawValue:))
        ?? finalArguments.string("state_response_mode").flatMap(StateResponseMode.init(rawValue:))
        ?? .auto
    let result = await StateResponseContext.$mode.withValue(finalMode) {
        await PerceptionMetricRecordingContext.$deferred.withValue(true) {
            await dispatcher(last.tool, finalArguments)
        }
    }
    if !finalLeafResultAccepted(result) {
        if isMutatingTool(last.tool) {
            updateCompositeEvidence(
                leafCommitEvidence(result),
                definite: &definitePriorCommit,
                ambiguous: &ambiguousCommit)
        }
        let responseConstructionStart = ContinuousClock.now
        let stoppedResult = stopped(
            atStep: steps.count, tool: last.tool, error: batchResultText(result))
        let leafEncoding = perceptionMetric(in: result)?.responseEncoding ?? .none
        let addedResponseConstructionMs = perceptionDurationMilliseconds(
            responseConstructionStart.duration(to: .now))
        return await recordingDeferredPerceptionMetric(
            from: result,
            attachingTo: stoppedResult,
            addedResponseConstructionMs: addedResponseConstructionMs,
            replacingEncoding: leafEncoding,
            replacingTextBytes: batchResultText(stoppedResult).utf8.count,
            replacingScreenshotPNGBytes: 0)
    }
    if isMutatingTool(last.tool) {
        updateCompositeEvidence(
            leafCommitEvidence(result),
            definite: &definitePriorCommit,
            ambiguous: &ambiguousCommit)
    }

    let responseConstructionStart = ContinuousClock.now
    var header = "Batch completed \(steps.count) step(s):\n"
    header += summary.isEmpty ? "" : summary.joined(separator: "\n") + "\n"
    header += "✓ step \(steps.count) \(last.tool) — final state below.\n\n"
    var content = result.content
    if case .text(let existing, let annotations, let meta)? = content.first {
        content[0] = .text(text: header + existing, annotations: annotations, _meta: meta)
    } else {
        content.insert(.text(text: header, annotations: nil, _meta: nil), at: 0)
    }
    let completed = CallTool.Result(content: content, isError: result.isError, _meta: result._meta)
    // The final leaf's metadata describes only that leaf. Always merge prior
    // composite evidence so a successful no-op/unknown tail cannot erase an
    // earlier committed or ambiguous mutation.
    let composite = applyingSuccessfulCompositeCommitEvidence(
        to: completed,
        definiteCommit: definitePriorCommit,
        ambiguousCommit: ambiguousCommit)
    let addedResponseConstructionMs = perceptionDurationMilliseconds(
        responseConstructionStart.duration(to: .now))
    return await recordingDeferredPerceptionMetric(
        from: composite,
        addedTextBytes: header.utf8.count,
        addedResponseConstructionMs: addedResponseConstructionMs)
}

func batchStoppedResult(
    step: Int,
    stepCount: Int,
    tool: String,
    error: String,
    summary: [String],
    definitePriorCommit: Bool,
    ambiguousCommit: Bool
) -> CallTool.Result {
    let result = CallTool.Result.text(
        "Batch stopped at step \(step) of \(stepCount) — earlier steps already ran:\n"
            + (summary + ["✗ step \(step) \(tool): \(error)"]).joined(separator: "\n"),
        isError: true
    )
    return applyingCompositeCommitEvidence(
        to: result,
        definitePriorCommit: definitePriorCommit,
        ambiguousCommit: ambiguousCommit)
}

private func updateCompositeEvidence(
    _ evidence: LeafCommitEvidence,
    definite: inout Bool,
    ambiguous: inout Bool
) {
    switch evidence {
    case .definite: definite = true
    case .unknown: ambiguous = true
    case .none: break
    }
}

func batchResultText(_ result: CallTool.Result) -> String {
    result.content.compactMap { content in
        if case .text(let text, _, _) = content { return text }
        return nil
    }.joined(separator: "\n")
}

private func firstLine(_ text: String) -> String {
    text.components(separatedBy: "\n").first ?? text
}
