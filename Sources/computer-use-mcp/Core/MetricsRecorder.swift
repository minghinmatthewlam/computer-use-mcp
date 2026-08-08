import Darwin
import Dispatch
import Foundation
import MCP

let metricsMetaKey = "computer-use-mcp/metrics"
private let metricsSchemaVersion = 2

/// Privacy-safe, daemon-wide operational metrics. This schema intentionally has
/// no fields for accessibility labels/values, screenshots, tree text, typed
/// text, URLs, window titles, or other user content.
struct OperationMetric: Codable, Equatable, Sendable {
  let operation: String
  let tool: String
  let appBundleIdentifier: String?
  let axRole: String?
  let attemptedDeliveryStrategies: [String]
  let finalDeliveryStrategy: String?
  let effectOutcome: String?
  let queueLatencyMs: Int64
  let executionLatencyMs: Int64

  enum CodingKeys: String, CodingKey {
    case operation
    case tool
    case appBundleIdentifier = "app_bundle_identifier"
    case axRole = "ax_role"
    case attemptedDeliveryStrategies = "attempted_delivery_strategies"
    case finalDeliveryStrategy = "final_delivery_strategy"
    case effectOutcome = "effect_outcome"
    case queueLatencyMs = "queue_latency_ms"
    case executionLatencyMs = "execution_latency_ms"
  }

  init(
    operation: String,
    tool: String,
    appBundleIdentifier: String?,
    axRole: String?,
    attemptedDeliveryStrategies: [String],
    finalDeliveryStrategy: String?,
    effectOutcome: String?,
    queueLatencyMs: Int64,
    executionLatencyMs: Int64
  ) {
    self.operation = safeMetricDimension(operation)
    self.tool = safeMetricDimension(tool)
    self.appBundleIdentifier = appBundleIdentifier.map(safeMetricDimension)
    self.axRole = axRole.map(safeMetricDimension)
    self.attemptedDeliveryStrategies = attemptedDeliveryStrategies.map(safeMetricDimension)
    self.finalDeliveryStrategy = finalDeliveryStrategy.map(safeMetricDimension)
    self.effectOutcome = effectOutcome.map(safeMetricDimension)
    self.queueLatencyMs = max(0, queueLatencyMs)
    self.executionLatencyMs = max(0, executionLatencyMs)
  }
}

enum StateResponseEncoding: String, Codable, CaseIterable, Sendable {
  case none
  case unchanged
  case diff
  case full
}

struct PerceptionMetric: Codable, Equatable, Sendable {
  let operation: String
  let tool: String
  let appBundleIdentifier: String?
  let perceptionMs: Int64
  let settleMs: Int64
  let screenshotMs: Int64
  let snapshotMs: Int64
  let verificationMs: Int64
  let responseConstructionMs: Int64
  let otherMs: Int64
  let elementsVisited: Int
  let elementsReturned: Int
  let partial: Bool
  let responseEncoding: StateResponseEncoding
  let textBytes: Int
  let screenshotPNGBytes: Int

  enum CodingKeys: String, CodingKey {
    case operation
    case tool
    case appBundleIdentifier = "app_bundle_identifier"
    case perceptionMs = "perception_ms"
    case settleMs = "settle_ms"
    case screenshotMs = "screenshot_ms"
    case snapshotMs = "snapshot_ms"
    case verificationMs = "verification_ms"
    case responseConstructionMs = "response_construction_ms"
    case otherMs = "other_ms"
    case elementsVisited = "elements_visited"
    case elementsReturned = "elements_returned"
    case partial
    case responseEncoding = "response_encoding"
    case textBytes = "text_bytes"
    case screenshotPNGBytes = "screenshot_png_bytes"
  }

  init(
    operation: String,
    tool: String,
    appBundleIdentifier: String?,
    perceptionMs: Int64,
    settleMs: Int64,
    screenshotMs: Int64,
    snapshotMs: Int64,
    verificationMs: Int64,
    responseConstructionMs: Int64,
    otherMs: Int64,
    elementsVisited: Int,
    elementsReturned: Int,
    partial: Bool,
    responseEncoding: StateResponseEncoding,
    textBytes: Int,
    screenshotPNGBytes: Int
  ) {
    self.operation = safeMetricDimension(operation)
    self.tool = safeMetricDimension(tool)
    self.appBundleIdentifier = appBundleIdentifier.map(safeMetricDimension)
    self.perceptionMs = max(0, perceptionMs)
    self.settleMs = max(0, settleMs)
    self.screenshotMs = max(0, screenshotMs)
    self.snapshotMs = max(0, snapshotMs)
    self.verificationMs = max(0, verificationMs)
    self.responseConstructionMs = max(0, responseConstructionMs)
    self.otherMs = max(0, otherMs)
    self.elementsVisited = max(0, elementsVisited)
    self.elementsReturned = max(0, elementsReturned)
    self.partial = partial
    self.responseEncoding = responseEncoding
    self.textBytes = max(0, textBytes)
    self.screenshotPNGBytes = max(0, screenshotPNGBytes)
  }

  init?(value: Value) {
    guard case .object(let fields) = value,
      let operation = fields["operation"]?.stringValue,
      let tool = fields["tool"]?.stringValue,
      let perceptionMs = fields["perception_ms"]?.intValue,
      let settleMs = fields["settle_ms"]?.intValue,
      let screenshotMs = fields["screenshot_ms"]?.intValue,
      let snapshotMs = fields["snapshot_ms"]?.intValue,
      let verificationMs = fields["verification_ms"]?.intValue,
      let responseConstructionMs = fields["response_construction_ms"]?.intValue,
      let otherMs = fields["other_ms"]?.intValue,
      let elementsVisited = fields["elements_visited"]?.intValue,
      let elementsReturned = fields["elements_returned"]?.intValue,
      let partial = fields["partial"]?.boolValue,
      let rawEncoding = fields["response_encoding"]?.stringValue,
      let responseEncoding = StateResponseEncoding(rawValue: rawEncoding),
      let textBytes = fields["text_bytes"]?.intValue,
      let screenshotPNGBytes = fields["screenshot_png_bytes"]?.intValue
    else { return nil }
    self.init(
      operation: operation,
      tool: tool,
      appBundleIdentifier: fields["app_bundle_identifier"]?.stringValue,
      perceptionMs: Int64(perceptionMs),
      settleMs: Int64(settleMs),
      screenshotMs: Int64(screenshotMs),
      snapshotMs: Int64(snapshotMs),
      verificationMs: Int64(verificationMs),
      responseConstructionMs: Int64(responseConstructionMs),
      otherMs: Int64(otherMs),
      elementsVisited: elementsVisited,
      elementsReturned: elementsReturned,
      partial: partial,
      responseEncoding: responseEncoding,
      textBytes: textBytes,
      screenshotPNGBytes: screenshotPNGBytes)
  }

  func addingResponseConstruction(milliseconds: Int64, textBytes: Int) -> PerceptionMetric {
    PerceptionMetric(
      operation: operation,
      tool: tool,
      appBundleIdentifier: appBundleIdentifier,
      perceptionMs: perceptionMs + max(0, milliseconds),
      settleMs: settleMs,
      screenshotMs: screenshotMs,
      snapshotMs: snapshotMs,
      verificationMs: verificationMs,
      responseConstructionMs: responseConstructionMs + max(0, milliseconds),
      otherMs: otherMs,
      elementsVisited: elementsVisited,
      elementsReturned: elementsReturned,
      partial: partial,
      responseEncoding: responseEncoding,
      textBytes: self.textBytes + max(0, textBytes),
      screenshotPNGBytes: screenshotPNGBytes)
  }

  func replacingResponse(
    encoding: StateResponseEncoding,
    textBytes: Int,
    screenshotPNGBytes: Int,
    addedConstructionMs: Int64
  ) -> PerceptionMetric {
    PerceptionMetric(
      operation: operation,
      tool: tool,
      appBundleIdentifier: appBundleIdentifier,
      perceptionMs: perceptionMs + max(0, addedConstructionMs),
      settleMs: settleMs,
      screenshotMs: screenshotMs,
      snapshotMs: snapshotMs,
      verificationMs: verificationMs,
      responseConstructionMs: responseConstructionMs + max(0, addedConstructionMs),
      otherMs: otherMs,
      elementsVisited: elementsVisited,
      elementsReturned: encoding == .none ? 0 : elementsReturned,
      partial: partial,
      responseEncoding: encoding,
      textBytes: textBytes,
      screenshotPNGBytes: screenshotPNGBytes)
  }
}

enum PerceptionMetricRecordingContext {
  @TaskLocal static var deferred = false
}

extension OperationMetric {
  var value: Value {
    var fields: [String: Value] = [
      "operation": .string(operation),
      "tool": .string(tool),
      "attempted_delivery_strategies": .array(
        attemptedDeliveryStrategies.map(Value.string)),
      "queue_latency_ms": .int(Int(clamping: queueLatencyMs)),
      "execution_latency_ms": .int(Int(clamping: executionLatencyMs)),
    ]
    if let appBundleIdentifier {
      fields["app_bundle_identifier"] = .string(appBundleIdentifier)
    }
    if let axRole { fields["ax_role"] = .string(axRole) }
    if let finalDeliveryStrategy {
      fields["final_delivery_strategy"] = .string(finalDeliveryStrategy)
    }
    if let effectOutcome { fields["effect_outcome"] = .string(effectOutcome) }
    return .object(fields)
  }
}

extension PerceptionMetric {
  var value: Value {
    var fields: [String: Value] = [
      "operation": .string(operation),
      "tool": .string(tool),
      "perception_ms": .int(Int(clamping: perceptionMs)),
      "settle_ms": .int(Int(clamping: settleMs)),
      "screenshot_ms": .int(Int(clamping: screenshotMs)),
      "snapshot_ms": .int(Int(clamping: snapshotMs)),
      "verification_ms": .int(Int(clamping: verificationMs)),
      "response_construction_ms": .int(Int(clamping: responseConstructionMs)),
      "other_ms": .int(Int(clamping: otherMs)),
      "elements_visited": .int(elementsVisited),
      "elements_returned": .int(elementsReturned),
      "partial": .bool(partial),
      "response_encoding": .string(responseEncoding.rawValue),
      "text_bytes": .int(textBytes),
      "screenshot_png_bytes": .int(screenshotPNGBytes),
    ]
    if let appBundleIdentifier {
      fields["app_bundle_identifier"] = .string(appBundleIdentifier)
    }
    return .object(fields)
  }
}

extension CallTool.Result {
  func withOperationMetric(_ metric: OperationMetric) -> CallTool.Result {
    withMetric("operation", value: metric.value)
  }

  func withPerceptionMetric(_ metric: PerceptionMetric) -> CallTool.Result {
    withMetric("perception", value: metric.value)
  }

  private func withMetric(_ name: String, value: Value) -> CallTool.Result {
    var envelope: [String: Value]
    if case .object(let existing)? = _meta?[metricsMetaKey] {
      envelope = existing
    } else {
      envelope = [:]
    }
    envelope["schema_version"] = .int(metricsSchemaVersion)
    envelope[name] = value
    return mergingMetaField(metricsMetaKey, .object(envelope))
  }
}

func perceptionMetric(in result: CallTool.Result) -> PerceptionMetric? {
  guard case .object(let envelope)? = result._meta?[metricsMetaKey],
    let value = envelope["perception"]
  else { return nil }
  return PerceptionMetric(value: value)
}

func recordingDeferredPerceptionMetric(
  from source: CallTool.Result,
  attachingTo target: CallTool.Result? = nil,
  addedTextBytes: Int = 0,
  addedResponseConstructionMs: Int64 = 0,
  replacingEncoding: StateResponseEncoding? = nil,
  replacingTextBytes: Int? = nil,
  replacingScreenshotPNGBytes: Int? = nil
) async -> CallTool.Result {
  let result = target ?? source
  guard let metric = perceptionMetric(in: source) else { return result }
  let adjusted: PerceptionMetric
  if let replacingEncoding, let replacingTextBytes, let replacingScreenshotPNGBytes {
    adjusted = metric.replacingResponse(
      encoding: replacingEncoding,
      textBytes: replacingTextBytes,
      screenshotPNGBytes: replacingScreenshotPNGBytes,
      addedConstructionMs: addedResponseConstructionMs)
  } else {
    adjusted = metric.addingResponseConstruction(
      milliseconds: addedResponseConstructionMs,
      textBytes: addedTextBytes)
  }
  await MetricsRecorder.shared.record(MetricsEvent(payload: .perception(adjusted)))
  return result.withPerceptionMetric(adjusted)
}

private func safeMetricDimension(_ value: String) -> String {
  guard !value.isEmpty, value.utf8.count <= 128,
    value.unicodeScalars.allSatisfy({
      CharacterSet.alphanumerics.contains($0) || "._:-".unicodeScalars.contains($0)
    })
  else {
    return "unknown"
  }
  return value
}

enum MetricsEventPayload: Equatable, Sendable {
  case operation(OperationMetric)
  case perception(PerceptionMetric)
}

struct MetricsEvent: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let timestamp: Date
  let payload: MetricsEventPayload

  init(timestamp: Date = Date(), payload: MetricsEventPayload) {
    schemaVersion = 2
    self.timestamp = timestamp
    self.payload = payload
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case timestamp
    case type
    case operation
    case perception
  }

  private enum EventType: String, Codable {
    case operation
    case perception
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    timestamp = try container.decode(Date.self, forKey: .timestamp)
    switch try container.decode(EventType.self, forKey: .type) {
    case .operation:
      payload = .operation(try container.decode(OperationMetric.self, forKey: .operation))
    case .perception:
      payload = .perception(try container.decode(PerceptionMetric.self, forKey: .perception))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(timestamp, forKey: .timestamp)
    switch payload {
    case .operation(let metric):
      try container.encode(EventType.operation, forKey: .type)
      try container.encode(metric, forKey: .operation)
    case .perception(let metric):
      try container.encode(EventType.perception, forKey: .type)
      try container.encode(metric, forKey: .perception)
    }
  }
}

struct MetricCounter: Codable, Equatable, Sendable {
  var count = 0
  var total = 0

  mutating func record(_ value: Int) {
    count += 1
    total += value
  }
}

struct MetricsAggregateSnapshot: Codable, Equatable, Sendable {
  var schemaVersion = 2
  var updatedAt: Date
  var events = 0
  var operations = 0
  var perceptions = 0
  var tools: [String: Int] = [:]
  var appBundleIdentifiers: [String: Int] = [:]
  var axRoles: [String: Int] = [:]
  var attemptedDeliveryStrategies: [String: Int] = [:]
  var finalDeliveryStrategies: [String: Int] = [:]
  var effectOutcomes: [String: Int] = [:]
  var queueLatencyMs = MetricCounter()
  var executionLatencyMs = MetricCounter()
  var perceptionLatencyMs = MetricCounter()
  var settleLatencyMs = MetricCounter()
  var screenshotLatencyMs = MetricCounter()
  var snapshotLatencyMs = MetricCounter()
  var verificationLatencyMs = MetricCounter()
  var responseConstructionLatencyMs = MetricCounter()
  var otherLatencyMs = MetricCounter()
  var elementsVisited = MetricCounter()
  var elementsReturned = MetricCounter()
  var partialPerceptions = 0
  var responseEncodings: [String: Int] = [:]
  var textBytes = MetricCounter()
  var screenshotPNGBytes = MetricCounter()

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case updatedAt = "updated_at"
    case events
    case operations
    case perceptions
    case tools
    case appBundleIdentifiers = "app_bundle_identifiers"
    case axRoles = "ax_roles"
    case attemptedDeliveryStrategies = "attempted_delivery_strategies"
    case finalDeliveryStrategies = "final_delivery_strategies"
    case effectOutcomes = "effect_outcomes"
    case queueLatencyMs = "queue_latency_ms"
    case executionLatencyMs = "execution_latency_ms"
    case perceptionLatencyMs = "perception_latency_ms"
    case settleLatencyMs = "settle_latency_ms"
    case screenshotLatencyMs = "screenshot_latency_ms"
    case snapshotLatencyMs = "snapshot_latency_ms"
    case verificationLatencyMs = "verification_latency_ms"
    case responseConstructionLatencyMs = "response_construction_latency_ms"
    case otherLatencyMs = "other_latency_ms"
    case elementsVisited = "elements_visited"
    case elementsReturned = "elements_returned"
    case partialPerceptions = "partial_perceptions"
    case responseEncodings = "response_encodings"
    case textBytes = "text_bytes"
    case screenshotPNGBytes = "screenshot_png_bytes"
  }

  init(updatedAt: Date = Date()) {
    self.updatedAt = updatedAt
  }

  mutating func record(_ event: MetricsEvent) {
    updatedAt = event.timestamp
    events += 1
    switch event.payload {
    case .operation(let metric):
      operations += 1
      increment(metric.tool, in: &tools)
      metric.appBundleIdentifier.map { increment($0, in: &appBundleIdentifiers) }
      metric.axRole.map { increment($0, in: &axRoles) }
      for strategy in metric.attemptedDeliveryStrategies {
        increment(strategy, in: &attemptedDeliveryStrategies)
      }
      metric.finalDeliveryStrategy.map { increment($0, in: &finalDeliveryStrategies) }
      metric.effectOutcome.map { increment($0, in: &effectOutcomes) }
      queueLatencyMs.record(clampedInt(metric.queueLatencyMs))
      executionLatencyMs.record(clampedInt(metric.executionLatencyMs))
    case .perception(let metric):
      perceptions += 1
      increment(metric.tool, in: &tools)
      metric.appBundleIdentifier.map { increment($0, in: &appBundleIdentifiers) }
      perceptionLatencyMs.record(clampedInt(metric.perceptionMs))
      settleLatencyMs.record(clampedInt(metric.settleMs))
      screenshotLatencyMs.record(clampedInt(metric.screenshotMs))
      snapshotLatencyMs.record(clampedInt(metric.snapshotMs))
      verificationLatencyMs.record(clampedInt(metric.verificationMs))
      responseConstructionLatencyMs.record(clampedInt(metric.responseConstructionMs))
      otherLatencyMs.record(clampedInt(metric.otherMs))
      elementsVisited.record(max(0, metric.elementsVisited))
      elementsReturned.record(max(0, metric.elementsReturned))
      partialPerceptions += metric.partial ? 1 : 0
      increment(metric.responseEncoding.rawValue, in: &responseEncodings)
      textBytes.record(max(0, metric.textBytes))
      screenshotPNGBytes.record(max(0, metric.screenshotPNGBytes))
    }
  }
}

private func increment(_ key: String, in values: inout [String: Int]) {
  values[key, default: 0] += 1
}

private func clampedInt(_ value: Int64) -> Int {
  Int(clamping: max(0, value))
}

struct MetricsRecorderConfiguration: Sendable {
  let eventsPath: String
  let summaryPath: String
  let lockPath: String
  let lockTimeoutMilliseconds: Int
  let maxFileBytes: Int
  let retainedFiles: Int
  let enabled: Bool

  static func runtime(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String] = CommandLine.arguments,
    productionDirectory: @autoclosure () -> String = daemonRuntimePaths(
      createRuntimeDirectory: true
    ).directory
  ) -> MetricsRecorderConfiguration {
    let enabled = !isMetricsTestProcess(environment: environment, arguments: arguments)
    let directory: String
    if enabled {
      directory = productionDirectory()
    } else {
      // Never resolve, create, chmod, or read the production runtime directory
      // from a test process. The disabled recorder will not create this inert
      // path either.
      directory =
        FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "computer-use-mcp-disabled-metrics-\(ProcessInfo.processInfo.processIdentifier)",
          isDirectory: true
        ).path
    }
    return MetricsRecorderConfiguration(
      eventsPath: URL(fileURLWithPath: directory).appendingPathComponent("metrics.jsonl").path,
      summaryPath: URL(fileURLWithPath: directory).appendingPathComponent("metrics-summary.json")
        .path,
      lockPath: URL(fileURLWithPath: directory).appendingPathComponent("metrics.lock").path,
      lockTimeoutMilliseconds: 50,
      maxFileBytes: 1_048_576,
      retainedFiles: 3,
      enabled: enabled
    )
  }
}

/// Swift Testing runs inside an XCTest bundle. Tests frequently exercise the
/// real dispatch funnel, so the process-level recorder must not treat those
/// calls as production activity. Explicitly constructed recorders remain
/// enabled for persistence tests.
func isMetricsTestProcess(environment: [String: String], arguments: [String]) -> Bool {
  if environment["XCTestConfigurationFilePath"] != nil
    || environment["XCTestBundlePath"] != nil
    || environment["SWIFT_TESTING_ENABLED"] != nil
  {
    return true
  }
  return arguments.first.map { URL(fileURLWithPath: $0).pathExtension == "xctest" } ?? false
}

actor MetricsRecorder {
  static let shared = MetricsRecorder(configuration: .runtime())

  private let configuration: MetricsRecorderConfiguration
  private var aggregate: MetricsAggregateSnapshot
  private let encoder: JSONEncoder

  init(configuration: MetricsRecorderConfiguration) {
    self.configuration = configuration
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    aggregate =
      configuration.enabled
      ? MetricsAggregateSnapshot.read(atPath: configuration.summaryPath)
        ?? MetricsAggregateSnapshot()
      : MetricsAggregateSnapshot()
  }

  func record(_ event: MetricsEvent) {
    guard configuration.enabled else { return }
    guard let encoded = try? encoder.encode(event) else { return }
    var line = encoded
    line.append(0x0A)
    guard
      let lockFD = acquireMetricsFileLock(
        atPath: configuration.lockPath,
        timeoutMilliseconds: configuration.lockTimeoutMilliseconds)
    else {
      return
    }
    defer {
      flock(lockFD, LOCK_UN)
      close(lockFD)
    }
    do {
      // Another process may have persisted events since this actor's last
      // write. Reload while holding the cross-process lock before merging.
      aggregate =
        MetricsAggregateSnapshot.read(atPath: configuration.summaryPath)
        ?? MetricsAggregateSnapshot()
      try rotateIfNeeded(addingBytes: line.count)
      try append(line)
      aggregate.record(event)
      try aggregate.write(toPath: configuration.summaryPath)
    } catch {
      // Metrics are best effort and must never fail an operation.
    }
  }

  func snapshot() -> MetricsAggregateSnapshot {
    aggregate
  }

  private func append(_ data: Data) throws {
    let manager = FileManager.default
    let url = URL(fileURLWithPath: configuration.eventsPath)
    try manager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !manager.fileExists(atPath: url.path) {
      try data.write(to: url, options: .atomic)
      return
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  }

  private func rotateIfNeeded(addingBytes: Int) throws {
    let manager = FileManager.default
    let path = configuration.eventsPath
    let currentSize =
      (try? manager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
    guard currentSize > 0, currentSize + addingBytes > max(1, configuration.maxFileBytes)
    else { return }

    if configuration.retainedFiles <= 0 {
      try? manager.removeItem(atPath: path)
      return
    }
    let oldest = "\(path).\(configuration.retainedFiles)"
    try? manager.removeItem(atPath: oldest)
    if configuration.retainedFiles > 1 {
      for index in stride(from: configuration.retainedFiles - 1, through: 1, by: -1) {
        let source = "\(path).\(index)"
        let destination = "\(path).\(index + 1)"
        if manager.fileExists(atPath: source) {
          try manager.moveItem(atPath: source, toPath: destination)
        }
      }
    }
    try manager.moveItem(atPath: path, toPath: "\(path).1")
  }
}

/// Correctness lock for the JSONL + summary transaction. Unlike the
/// best-effort ScreenCaptureKit lock, failure to acquire this lock skips the
/// metric rather than risking corruption or lost aggregate counts.
private func acquireMetricsFileLock(
  atPath path: String,
  timeoutMilliseconds: Int
) -> Int32? {
  let url = URL(fileURLWithPath: path)
  do {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  } catch {
    return nil
  }
  let fd = open(path, O_CREAT | O_WRONLY, 0o600)
  guard fd >= 0 else { return nil }
  let timeoutNanoseconds = UInt64(max(0, timeoutMilliseconds)) * 1_000_000
  let start = DispatchTime.now().uptimeNanoseconds
  let deadline = start.addingReportingOverflow(timeoutNanoseconds)
  let deadlineNanoseconds = deadline.overflow ? UInt64.max : deadline.partialValue
  while flock(fd, LOCK_EX | LOCK_NB) != 0 {
    guard DispatchTime.now().uptimeNanoseconds < deadlineNanoseconds else {
      close(fd)
      return nil
    }
    if errno == EINTR {
      continue
    }
    guard errno == EWOULDBLOCK || errno == EAGAIN else {
      close(fd)
      return nil
    }
    usleep(1_000)
  }
  return fd
}

extension MetricsAggregateSnapshot {
  static func read(atPath path: String) -> MetricsAggregateSnapshot? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return try? decoder.decode(MetricsAggregateSnapshot.self, from: data)
  }

  func write(toPath path: String) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(self).write(to: url, options: .atomic)
  }
}

func operationMetricsSummaryPath(createRuntimeDirectory: Bool = false) -> String {
  URL(
    fileURLWithPath: daemonRuntimePaths(
      createRuntimeDirectory: createRuntimeDirectory
    ).directory
  ).appendingPathComponent("metrics-summary.json").path
}
