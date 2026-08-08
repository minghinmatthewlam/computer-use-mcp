// Shared tool dispatch — the one funnel every entry point (MCP serve, the
// daemon, the call harness) routes through: catalog lookup, optional rate
// limit, error capture, per-call logging.

import Foundation
import MCP

typealias DaemonToolCaller = @Sendable (String, [String: Value]) async throws -> CallTool.Result
typealias LocalToolDispatcher = @Sendable (String, [String: Value]) async -> CallTool.Result

func dispatchToolWithDaemonPolicy(
    name: String,
    arguments: [String: Value],
    useDaemon: Bool,
    daemonCall: DaemonToolCaller = { name, arguments in
        try await DaemonClient.shared.call(tool: name, arguments: arguments)
    },
    localDispatch: LocalToolDispatcher = dispatchTool
) async -> CallTool.Result {
    if useDaemon {
        do {
            return try await daemonCall(name, arguments)
        } catch {
            if isMutatingTool(name) {
                return .text(
                    "Engine daemon unavailable (\(error)); refusing to run mutating tool "
                        + "\"\(name)\" in-process. Set no_daemon / "
                        + "COMPUTER_USE_MCP_NO_DAEMON=1 to explicitly accept in-process dispatch.",
                    isError: true
                )
            }
            FileHandle.standardError.write(
                Data("[computer-use-mcp] daemon unavailable (\(error)); running read-only tool in-process\n".utf8)
            )
        }
    }
    return await localDispatch(name, arguments)
}

func dispatchTool(name: String, arguments: [String: Value]) async -> CallTool.Result {
    guard let spec = toolCatalog.first(where: { $0.name == name }) else {
        return .text("Unknown tool: \(name)", isError: true)
    }
    do {
        try validateStateResponseArguments(toolName: name, arguments: arguments)
    } catch {
        return codedErrorResult("\(error)", code: toolErrorCode(for: error))
    }
    await RateLimiter.shared.acquire()
    let start = ContinuousClock.now
    await SleepAssertion.shared.noteActivity()
    let mutation = isMutatingTool(name)
    let metricAppBundleIdentifier =
        arguments.string("app").flatMap { try? resolveApp($0).bundleIdentifier }
    var transaction: ActionTransaction?
    if mutation {
        transaction = makeActionTransactionForDispatch()
        try? transaction?.advance(to: .gate)
    }
    if let refusal = await preflightRefusal(name: name, arguments: arguments) {
        logToolCall(name, isError: true, since: start)
        var result = codedErrorResult(refusal, code: toolErrorCode(forMessage: refusal))
        if var transaction {
            (transaction, result) = abortedTransaction(
                transaction: transaction, result: result, cancellationRequested: false)
            result = await recordingOperationMetric(
                transaction: transaction, tool: name, result: result,
                appBundleIdentifier: metricAppBundleIdentifier, since: start)
        }
        return result
    }
    if Task.isCancelled, var transaction {
        let cancelled = codedErrorResult(
            "Operation cancelled before delivery.", code: toolErrorCode(forMessage: "cancelled"))
        let result: CallTool.Result
        (transaction, result) = abortedTransaction(
            transaction: transaction, result: cancelled, cancellationRequested: true)
        let measuredResult = await recordingOperationMetric(
            transaction: transaction, tool: name, result: result,
            appBundleIdentifier: metricAppBundleIdentifier, since: start)
        return measuredResult
    }
    let result: CallTool.Result
    var cancelledBeforeDelivery = false
    let deliveryBoundary = mutation ? DeliveryBoundaryTracker() : nil
    if var active = transaction {
        try? active.advance(to: .before)
        transaction = active
        let mode =
            arguments["state_response_mode"] == nil
            ? StateResponseContext.mode
            : stateResponseMode(arguments)
        result = await StateResponseContext.$mode.withValue(mode) {
            await DeliveryBoundaryContext.$tracker.withValue(deliveryBoundary) {
                await ActionTransactionContext.withCurrentOperation(active) {
                    do {
                        return try await spec.handler(arguments)
                    } catch {
                        let classified = handlerErrorResult(error)
                        cancelledBeforeDelivery = classified.preDeliveryCancellation
                        return classified.result
                    }
                }
            }
        }
    } else {
        do {
            result = try await spec.handler(arguments)
        } catch {
            result = codedErrorResult("\(error)", code: toolErrorCode(for: error))
        }
    }
    var finalResult = result
    if var transaction {
        let safeCancellationAbort = shouldAbortForPreDeliverySignal(
            signalled: cancelledBeforeDelivery, tracker: deliveryBoundary)
        if safeCancellationAbort || shouldAbortBeforeDelivery(
            result: result, tracker: deliveryBoundary)
        {
            (transaction, finalResult) = abortedTransaction(
                transaction: transaction, result: result,
                cancellationRequested: safeCancellationAbort)
            finalResult = await recordingOperationMetric(
                transaction: transaction, tool: name, result: finalResult,
                appBundleIdentifier: metricAppBundleIdentifier, since: start)
            logToolCall(name, isError: true, since: start)
            await Telemetry.shared.record(tool: name, isError: true, since: start)
            return finalResult
        }
        // The handler owns target resolution, before-capture, and delivery.
        // This dispatch envelope records their completion only after the handler
        // returns; it does not claim delivery began before handler execution.
        try? transaction.advance(to: .deliver)
        try? transaction.recordDelivery(deliveryStatus(for: result))
        try? transaction.advance(to: .after)
        try? transaction.advance(to: .verify)
        try? transaction.recordEffect(effectStatus(for: result))
        try? transaction.advance(to: .commit)
        try? transaction.recordCommit(commitStatus(for: result, tool: name))
        finalResult = result.withActionTransaction(transaction)
        finalResult = await recordingOperationMetric(
            transaction: transaction, tool: name, result: finalResult,
            appBundleIdentifier: metricAppBundleIdentifier, since: start)
    }
    logToolCall(name, isError: finalResult.isError == true, since: start)
    await Telemetry.shared.record(tool: name, isError: finalResult.isError == true, since: start)
    return finalResult
}

func shouldAbortForPreDeliverySignal(
    signalled: Bool,
    tracker: DeliveryBoundaryTracker?
) -> Bool {
    signalled && tracker?.deliveryBegan != true
}

func shouldAbortBeforeDelivery(
    result: CallTool.Result,
    tracker: DeliveryBoundaryTracker?
) -> Bool {
    guard result.isError == true, tracker?.deliveryBegan != true else { return false }
    let meta = result._meta?.fields ?? [:]
    return meta["computer-use-mcp/delivery"] == nil
        && meta[actionTransactionMetaKey] == nil
        && meta[actionOutcomeMetaKey] == nil
}

func handlerErrorResult(_ error: Error) -> (result: CallTool.Result, preDeliveryCancellation: Bool) {
    if error is PreDeliveryCancellationError {
        return (
            codedErrorResult(
                "Operation cancelled before delivery.",
                code: toolErrorCode(forMessage: "cancelled")),
            true)
    }
    return (codedErrorResult("\(error)", code: toolErrorCode(for: error)), false)
}

func abortedTransaction(
    transaction original: ActionTransaction,
    result: CallTool.Result,
    cancellationRequested: Bool
) -> (ActionTransaction, CallTool.Result) {
    var transaction = original
    if cancellationRequested { transaction.requestCancellation() }
    try? transaction.abortBeforeDelivery()
    return (transaction, result.withActionTransaction(transaction))
}

func makeActionTransactionForDispatch(
    noDaemonOperationID: UUID = UUID()
) -> ActionTransaction {
    if ActionTransactionContext.depth > 0 {
        return ActionTransaction()
    }
    return ActionTransaction(
        rootOperationID: DaemonSessionContext.operationID ?? noDaemonOperationID)
}

func deliveryStatus(for result: CallTool.Result) -> ActionDeliveryStatus {
    if case .object(let delivery)? = result._meta?["computer-use-mcp/delivery"],
        delivery["dispatch_succeeded"]?.boolValue == false
    {
        return .notDelivered
    }
    if case .object(let outcome)? = result._meta?[actionOutcomeMetaKey],
        outcome["dispatch_succeeded"]?.boolValue == false
    {
        return .notDelivered
    }
    guard case .object(let fields)? = result._meta?["computer-use-mcp/delivery"],
        let tier = fields["delivery_tier"]?.stringValue
    else { return .unknown }
    return isDroppableBackgroundDeliveryTier(tier) ? .posted : .delivered
}

func effectStatus(for result: CallTool.Result) -> ActionEffectStatus {
    guard case .object(let fields)? = result._meta?[actionOutcomeMetaKey],
        let classification = fields["classification"]?.stringValue
    else { return .notChecked }
    return classification == ActionClassification.success.rawValue ? .verified : .unverified
}

func commitStatus(for result: CallTool.Result, tool _: String) -> ActionCommitStatus {
    if case .object(let fields)? = result._meta?[actionTransactionMetaKey],
        fields["commit_status"]?.stringValue == ActionCommitStatus.partiallyCommitted.rawValue
    {
        return .partiallyCommitted
    }
    if case .object(let fields)? = result._meta?[actionTransactionMetaKey],
        fields["commit_status"]?.stringValue == ActionCommitStatus.unknown.rawValue
    {
        return .unknown
    }
    if case .object(let fields)? = result._meta?[actionTransactionMetaKey],
        fields["commit_status"]?.stringValue == ActionCommitStatus.committed.rawValue
    {
        return .committed
    }
    if case .object(let fields)? = result._meta?[actionTransactionMetaKey],
        fields["commit_status"]?.stringValue == ActionCommitStatus.notCommitted.rawValue
    {
        return .notCommitted
    }
    if case .object(let delivery)? = result._meta?["computer-use-mcp/delivery"],
        delivery["dispatch_succeeded"]?.boolValue == false
    {
        return .notCommitted
    }
    guard case .object(let outcome)? = result._meta?[actionOutcomeMetaKey],
        let classification = outcome["classification"]?.stringValue
    else { return .unknown }
    let dispatched = outcome["dispatch_succeeded"]?.boolValue
    if classification == ActionClassification.unsupported.rawValue || dispatched == false {
        return .notCommitted
    }
    if classification == ActionClassification.success.rawValue, dispatched == true {
        return .committed
    }
    return .unknown
}

private func deliveryMetricFields(
    for result: CallTool.Result
) -> (attempted: [String], final: String?) {
    guard case .object(let fields)? = result._meta?["computer-use-mcp/delivery"] else {
        return ([], nil)
    }
    let final = fields["delivery_tier"]?.stringValue
    var attempted: [String] = []
    if let rung = fields["chain_rung"]?.stringValue { attempted.append(rung) }
    if let final { attempted.append(final) }
    return (attempted, final)
}

private func recordingOperationMetric(
    transaction: ActionTransaction,
    tool: String,
    result: CallTool.Result,
    appBundleIdentifier: String?,
    since start: ContinuousClock.Instant
) async -> CallTool.Result {
    let elapsed = start.duration(to: .now)
    let milliseconds =
        elapsed.components.seconds * 1000
        + elapsed.components.attoseconds / 1_000_000_000_000_000
    let delivery = deliveryMetricFields(for: result)
    let metric = OperationMetric(
        operation: transaction.operationID.uuidString,
        tool: tool,
        appBundleIdentifier: appBundleIdentifier,
        axRole: nil,
        attemptedDeliveryStrategies: delivery.attempted,
        finalDeliveryStrategy: delivery.final,
        effectOutcome: transaction.effectStatus.rawValue,
        queueLatencyMs: Int64(
            max(0, DaemonSessionContext.queueLatencyMilliseconds ?? 0).rounded()),
        executionLatencyMs: milliseconds
    )
    await MetricsRecorder.shared.record(MetricsEvent(payload: .operation(metric)))
    return result.withOperationMetric(metric)
}

/// The gates every tool call passes before its handler runs: screen-lock
/// pause (mutating tools only), human-interference yield, and the browser
/// URL policy. Returns the first refusal message, or nil when clear to act.
private func preflightRefusal(name: String, arguments: [String: Value]) async -> String? {
    if let lockMessage = lockedScreenMessage(toolName: name, isLocked: screenIsLocked()) {
        return lockMessage
    }
    if let yieldMessage = await InterferenceGuard.waitForUserPause(toolName: name, arguments: arguments) {
        return yieldMessage
    }
    return URLPolicy.check(toolName: name, arguments: arguments)
}

/// Stderr per-call log line, enabled with COMPUTER_USE_MCP_LOG=1 (or "log" in
/// the config file). Stderr is safe on a stdio transport.
private func logToolCall(_ name: String, isError: Bool, since start: ContinuousClock.Instant) {
    guard Config.bool("log") == true else { return }
    let elapsed = start.duration(to: .now)
    let milliseconds = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
    FileHandle.standardError.write(
        Data("[computer-use-mcp] \(name) \(isError ? "error" : "ok") \(milliseconds)ms\n".utf8)
    )
}

/// Optional global action throttle ("max_actions_per_sec" /
/// COMPUTER_USE_MCP_MAX_ACTIONS_PER_SEC). Off by default; when set, tool
/// calls are spaced at least 1/n seconds apart as a runaway-agent backstop.
actor RateLimiter {
    static let shared = RateLimiter()
    private var lastCall: ContinuousClock.Instant?
    private let minimumInterval: Duration? = Config.double("max_actions_per_sec")
        .flatMap { $0 > 0 ? .seconds(1.0 / $0) : nil }

    func acquire() async {
        guard let minimumInterval else { return }
        let now = ContinuousClock.now
        if let lastCall, lastCall + minimumInterval > now {
            try? await Task.sleep(until: lastCall + minimumInterval)
            self.lastCall = lastCall + minimumInterval
        } else {
            lastCall = now
        }
    }
}
