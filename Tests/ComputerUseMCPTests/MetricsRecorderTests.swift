import Darwin
import Foundation
import MCP
import Testing

@testable import computer_use_mcp

@Suite struct MetricsRecorderTests {
  @Test func eventsRoundTripAsJSONLines() throws {
    let event = operationEvent(index: 1)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970

    let data = try encoder.encode(event)
    #expect(try decoder.decode(MetricsEvent.self, from: data) == event)
  }

  @Test func aggregateCoversOperationAndPerceptionDimensions() {
    var aggregate = MetricsAggregateSnapshot(updatedAt: Date(timeIntervalSince1970: 0))
    aggregate.record(operationEvent(index: 1))
    aggregate.record(perceptionEvent(index: 2))

    #expect(aggregate.events == 2)
    #expect(aggregate.operations == 1)
    #expect(aggregate.perceptions == 1)
    #expect(aggregate.tools == ["click": 1, "get_app_state": 1])
    #expect(aggregate.appBundleIdentifiers == ["com.example.fixture": 2])
    #expect(aggregate.axRoles == ["AXButton": 1])
    #expect(aggregate.attemptedDeliveryStrategies == ["ax_press": 1, "pid_event": 1])
    #expect(aggregate.finalDeliveryStrategies == ["ax_press": 1])
    #expect(aggregate.effectOutcomes == ["success": 1])
    #expect(aggregate.queueLatencyMs == MetricCounter(count: 1, total: 3))
    #expect(aggregate.executionLatencyMs == MetricCounter(count: 1, total: 11))
    #expect(aggregate.perceptionLatencyMs == MetricCounter(count: 1, total: 22))
    #expect(aggregate.settleLatencyMs == MetricCounter(count: 1, total: 4))
    #expect(aggregate.screenshotLatencyMs == MetricCounter(count: 1, total: 5))
    #expect(aggregate.snapshotLatencyMs == MetricCounter(count: 1, total: 6))
    #expect(aggregate.verificationLatencyMs == MetricCounter(count: 1, total: 2))
    #expect(aggregate.responseConstructionLatencyMs == MetricCounter(count: 1, total: 3))
    #expect(aggregate.otherLatencyMs == MetricCounter(count: 1, total: 2))
    #expect(aggregate.elementsVisited == MetricCounter(count: 1, total: 50))
    #expect(aggregate.elementsReturned == MetricCounter(count: 1, total: 20))
    #expect(aggregate.partialPerceptions == 1)
    #expect(aggregate.responseEncodings == ["diff": 1])
    #expect(aggregate.textBytes == MetricCounter(count: 1, total: 2048))
    #expect(aggregate.screenshotPNGBytes == MetricCounter(count: 1, total: 4096))
  }

  @Test func recorderSerializesConcurrentWritesAndPersistsSummary() async throws {
    try await withRecorder { recorder, configuration in
      await withTaskGroup(of: Void.self) { group in
        for index in 0..<100 {
          group.addTask {
            await recorder.record(operationEvent(index: index))
          }
        }
      }

      let lines = try String(contentsOfFile: configuration.eventsPath, encoding: .utf8)
        .split(separator: "\n")
      #expect(lines.count == 100)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .secondsSince1970
      for line in lines {
        _ = try decoder.decode(MetricsEvent.self, from: Data(line.utf8))
      }
      #expect(MetricsAggregateSnapshot.read(atPath: configuration.summaryPath)?.events == 100)
      #expect(await recorder.snapshot().events == 100)
    }
  }

  @Test func independentRecordersMergeConcurrentWritesWithoutLostCounts() async throws {
    try await withTemporaryDirectory { directory in
      let configuration = recorderConfiguration(directory: directory)
      let first = MetricsRecorder(configuration: configuration)
      let second = MetricsRecorder(configuration: configuration)
      await withTaskGroup(of: Void.self) { group in
        for index in 0..<100 {
          group.addTask {
            await (index.isMultiple(of: 2) ? first : second).record(
              operationEvent(index: index))
          }
        }
      }

      let events = try decodeEvents(paths: [configuration.eventsPath])
      #expect(events.count == 100)
      #expect(MetricsAggregateSnapshot.read(atPath: configuration.summaryPath)?.events == 100)
      #expect(await first.snapshot().events <= 100)
      #expect(await second.snapshot().events <= 100)
    }
  }

  @Test func recorderRotatesAndBoundsRetention() async throws {
    try await withRecorder(maxFileBytes: 450, retainedFiles: 2) {
      recorder, configuration in
      for index in 0..<20 {
        await recorder.record(operationEvent(index: index))
      }

      let manager = FileManager.default
      #expect(manager.fileExists(atPath: configuration.eventsPath))
      #expect(manager.fileExists(atPath: "\(configuration.eventsPath).1"))
      #expect(manager.fileExists(atPath: "\(configuration.eventsPath).2"))
      #expect(!manager.fileExists(atPath: "\(configuration.eventsPath).3"))
      for suffix in ["", ".1", ".2"] {
        let size =
          (try manager.attributesOfItem(
            atPath: configuration.eventsPath + suffix
          )[.size] as? NSNumber)?.intValue ?? 0
        // One event may exceed a deliberately tiny test limit, but a
        // rotated file never contains multiple oversized events.
        #expect(size < 900)
      }
    }
  }

  @Test func independentRecordersKeepRotatedJSONLinesParseable() async throws {
    try await withTemporaryDirectory { directory in
      let configuration = recorderConfiguration(
        directory: directory, maxFileBytes: 450, retainedFiles: 3)
      let first = MetricsRecorder(configuration: configuration)
      let second = MetricsRecorder(configuration: configuration)
      await withTaskGroup(of: Void.self) { group in
        for index in 0..<30 {
          group.addTask {
            await (index.isMultiple(of: 2) ? first : second).record(
              operationEvent(index: index))
          }
        }
      }

      let paths = ["", ".1", ".2", ".3"].map { configuration.eventsPath + $0 }
      let events = try decodeEvents(
        paths: paths.filter { FileManager.default.fileExists(atPath: $0) })
      #expect(!events.isEmpty)
      #expect(MetricsAggregateSnapshot.read(atPath: configuration.summaryPath)?.events == 30)
      #expect(!FileManager.default.fileExists(atPath: "\(configuration.eventsPath).4"))
    }
  }

  @Test func heldCrossProcessLockDropsMetricWithinBoundWithoutMutation() async throws {
    try await withTemporaryDirectory { directory in
      let configuration = recorderConfiguration(
        directory: directory, lockTimeoutMilliseconds: 20)
      let lockFD = open(configuration.lockPath, O_CREAT | O_WRONLY, 0o600)
      #expect(lockFD >= 0)
      guard lockFD >= 0 else { return }
      defer {
        flock(lockFD, LOCK_UN)
        close(lockFD)
      }
      #expect(flock(lockFD, LOCK_EX | LOCK_NB) == 0)

      let recorder = MetricsRecorder(configuration: configuration)
      let clock = ContinuousClock()
      let elapsed = await clock.measure {
        await recorder.record(operationEvent(index: 1))
      }

      #expect(elapsed < .milliseconds(250))
      #expect(!FileManager.default.fileExists(atPath: configuration.eventsPath))
      #expect(!FileManager.default.fileExists(atPath: configuration.summaryPath))
      #expect(await recorder.snapshot().events == 0)
    }
  }

  @Test func encodedSchemaCannotContainUserContentFields() throws {
    let data = try JSONEncoder().encode(operationEvent(index: 1))
    let json = String(decoding: data, as: UTF8.self)
    for forbidden in [
      "\"label\"", "\"value\"", "\"text\"", "\"screenshot\"",
      "\"tree\"", "\"url\"", "\"window_title\"", "\"typed_text\"",
    ] {
      #expect(!json.contains(forbidden))
    }
    #expect(json.contains("\"app_bundle_identifier\""))
    #expect(json.contains("\"ax_role\""))
  }

  @Test func dimensionValuesRejectFreeFormUserContent() throws {
    let metric = OperationMetric(
      operation: "click user's private button",
      tool: "click",
      appBundleIdentifier: "com.example.safe",
      axRole: "AXButton:Account Number 1234",
      attemptedDeliveryStrategies: ["ax press"],
      finalDeliveryStrategy: nil,
      effectOutcome: "success",
      queueLatencyMs: -1,
      executionLatencyMs: -1
    )
    #expect(metric.operation == "unknown")
    #expect(metric.axRole == "unknown")
    #expect(metric.attemptedDeliveryStrategies == ["unknown"])
    #expect(metric.queueLatencyMs == 0)
    #expect(metric.executionLatencyMs == 0)
  }

  @Test func resultMetadataSupportsOperationOnlyMetrics() {
    let original = CallTool.Result.text("ok")
    let result = original.withOperationMetric(operationMetric())

    guard case .object(let envelope)? = result._meta?[metricsMetaKey] else {
      Issue.record("Missing metrics envelope")
      return
    }
    #expect(envelope["schema_version"] == .int(2))
    #expect(envelope["operation"] == operationMetric().value)
    #expect(envelope["perception"] == nil)
    #expect(result.content == original.content)
  }

  @Test func resultMetadataSupportsPerceptionOnlyMetrics() {
    let result = CallTool.Result.text("ok").withPerceptionMetric(perceptionMetric())

    guard case .object(let envelope)? = result._meta?[metricsMetaKey] else {
      Issue.record("Missing metrics envelope")
      return
    }
    #expect(envelope["schema_version"] == .int(2))
    #expect(envelope["operation"] == nil)
    #expect(envelope["perception"] == perceptionMetric().value)
  }

  @Test func perceptionMetadataReportsActualEncodingAndSeparatePayloadBytes() {
    guard case .object(let fields) = perceptionMetric().value else {
      Issue.record("Expected perception metric object")
      return
    }
    #expect(fields["response_encoding"] == .string("diff"))
    #expect(fields["text_bytes"] == .int(2048))
    #expect(fields["screenshot_png_bytes"] == .int(4096))
    #expect(fields["diff"] == nil)
    #expect(fields["context_bytes"] == nil)
  }

  @Test func perceptionMetricRoundTripsThroughMetadataValue() {
    #expect(PerceptionMetric(value: perceptionMetric().value) == perceptionMetric())
  }

  @Test func addingOperationMetricPreservesPerceptionMetric() {
    let result = CallTool.Result(
      content: [.text(text: "ok", annotations: nil, _meta: nil)],
      _meta: Metadata(additionalFields: ["unrelated": .string("preserve-me")])
    )
      .withPerceptionMetric(perceptionMetric())
      .withOperationMetric(operationMetric())

    guard case .object(let envelope)? = result._meta?[metricsMetaKey] else {
      Issue.record("Missing metrics envelope")
      return
    }
    #expect(envelope["schema_version"] == .int(2))
    #expect(envelope["operation"] == operationMetric().value)
    #expect(envelope["perception"] == perceptionMetric().value)
    #expect(result._meta?["unrelated"] == .string("preserve-me"))
  }

  @Test func addingMetricPreservesUnrelatedMetadata() {
    let result = CallTool.Result(
      content: [.text(text: "ok", annotations: nil, _meta: nil)],
      isError: false,
      _meta: Metadata(additionalFields: ["unrelated": .string("preserve-me")])
    ).withPerceptionMetric(perceptionMetric())

    #expect(result._meta?["unrelated"] == .string("preserve-me"))
    #expect(result._meta?[metricsMetaKey] != nil)
  }

  @Test func summaryRoundTripsForCrossProcessHealthRead() throws {
    try withTemporaryDirectory { directory in
      let path = directory.appendingPathComponent("summary.json").path
      var aggregate = MetricsAggregateSnapshot()
      aggregate.record(perceptionEvent(index: 3))
      try aggregate.write(toPath: path)
      #expect(MetricsAggregateSnapshot.read(atPath: path) == aggregate)
    }
  }

  @Test func runtimeConfigurationDisablesTestProcessesButNotProduction() {
    let xctest = MetricsRecorderConfiguration.runtime(
      environment: [:],
      arguments: ["/tmp/computer-use-mcpPackageTests.xctest"]
    )
    let swiftTesting = MetricsRecorderConfiguration.runtime(
      environment: ["SWIFT_TESTING_ENABLED": "1"],
      arguments: ["/tmp/computer-use-mcp"]
    )
    let production = MetricsRecorderConfiguration.runtime(
      environment: [:],
      arguments: ["/Applications/Computer Use MCP.app/Contents/MacOS/computer-use-mcp"],
      productionDirectory: "/tmp/production-metrics"
    )

    #expect(xctest.enabled == false)
    #expect(swiftTesting.enabled == false)
    #expect(production.enabled == true)
    #expect(production.eventsPath == "/tmp/production-metrics/metrics.jsonl")
    #expect(!xctest.eventsPath.contains("/Library/Caches/computer-use-mcp/"))
    #expect(!swiftTesting.summaryPath.contains("/Library/Caches/computer-use-mcp/"))
  }

  @Test func disabledRecorderDoesNotCreateOrAggregateMetrics() async throws {
    try await withRecorder(enabled: false) { recorder, configuration in
      await recorder.record(operationEvent(index: 1))

      #expect(!FileManager.default.fileExists(atPath: configuration.eventsPath))
      #expect(!FileManager.default.fileExists(atPath: configuration.summaryPath))
      #expect(await recorder.snapshot().events == 0)
    }
  }

  @Test func disabledRecorderDoesNotReadOrTouchSuppliedSentinelSummary() async throws {
    try await withTemporaryDirectory { directory in
      let events = directory.appendingPathComponent("production-sentinel.jsonl")
      let summary = directory.appendingPathComponent("production-sentinel-summary.json")
      let sentinel = Data("do-not-read-or-modify".utf8)
      try sentinel.write(to: summary)
      let before = try FileManager.default.attributesOfItem(atPath: summary.path)
      let configuration = MetricsRecorderConfiguration(
        eventsPath: events.path,
        summaryPath: summary.path,
        lockPath: directory.appendingPathComponent("sentinel.lock").path,
        lockTimeoutMilliseconds: 50,
        maxFileBytes: 100,
        retainedFiles: 1,
        enabled: false
      )

      let recorder = MetricsRecorder(configuration: configuration)
      #expect(await recorder.snapshot().events == 0)
      await recorder.record(operationEvent(index: 1))

      #expect(!FileManager.default.fileExists(atPath: events.path))
      #expect(try Data(contentsOf: summary) == sentinel)
      let after = try FileManager.default.attributesOfItem(atPath: summary.path)
      #expect(before[.size] as? NSNumber == after[.size] as? NSNumber)
      #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
    }
  }

  private func withRecorder(
    maxFileBytes: Int = 1_000_000,
    retainedFiles: Int = 2,
    enabled: Bool = true,
    body: (MetricsRecorder, MetricsRecorderConfiguration) async throws -> Void
  ) async throws {
    try await withTemporaryDirectory { directory in
      let configuration = recorderConfiguration(
        directory: directory, maxFileBytes: maxFileBytes,
        retainedFiles: retainedFiles, enabled: enabled)
      try await body(MetricsRecorder(configuration: configuration), configuration)
    }
  }

  private func recorderConfiguration(
    directory: URL,
    maxFileBytes: Int = 1_000_000,
    retainedFiles: Int = 2,
    lockTimeoutMilliseconds: Int = 50,
    enabled: Bool = true
  ) -> MetricsRecorderConfiguration {
    MetricsRecorderConfiguration(
      eventsPath: directory.appendingPathComponent("metrics.jsonl").path,
      summaryPath: directory.appendingPathComponent("summary.json").path,
      lockPath: directory.appendingPathComponent("metrics.lock").path,
      lockTimeoutMilliseconds: lockTimeoutMilliseconds,
      maxFileBytes: maxFileBytes,
      retainedFiles: retainedFiles,
      enabled: enabled
    )
  }

  private func decodeEvents(paths: [String]) throws -> [MetricsEvent] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return try paths.flatMap { path in
      try String(contentsOfFile: path, encoding: .utf8)
        .split(separator: "\n")
        .map { try decoder.decode(MetricsEvent.self, from: Data($0.utf8)) }
    }
  }

  private func withTemporaryDirectory<T>(
    _ body: (URL) async throws -> T
  ) async throws -> T {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("metrics-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
  }

  private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("metrics-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
  }
}

private func operationEvent(index: Int) -> MetricsEvent {
  MetricsEvent(
    timestamp: Date(timeIntervalSince1970: Double(index)),
    payload: .operation(
      OperationMetric(
        operation: "interaction",
        tool: "click",
        appBundleIdentifier: "com.example.fixture",
        axRole: "AXButton",
        attemptedDeliveryStrategies: ["ax_press", "pid_event"],
        finalDeliveryStrategy: "ax_press",
        effectOutcome: "success",
        queueLatencyMs: 3,
        executionLatencyMs: 11
      )))
}

private func perceptionEvent(index: Int) -> MetricsEvent {
  MetricsEvent(
    timestamp: Date(timeIntervalSince1970: Double(index)),
    payload: .perception(
      PerceptionMetric(
        operation: "snapshot",
        tool: "get_app_state",
        appBundleIdentifier: "com.example.fixture",
        perceptionMs: 22,
        settleMs: 4,
        screenshotMs: 5,
        snapshotMs: 6,
        verificationMs: 2,
        responseConstructionMs: 3,
        otherMs: 2,
        elementsVisited: 50,
        elementsReturned: 20,
        partial: true,
        responseEncoding: .diff,
        textBytes: 2048,
        screenshotPNGBytes: 4096
      )))
}

private func operationMetric() -> OperationMetric {
  OperationMetric(
    operation: "operation-1",
    tool: "click",
    appBundleIdentifier: "com.example.fixture",
    axRole: "AXButton",
    attemptedDeliveryStrategies: ["ax_press", "pid_event"],
    finalDeliveryStrategy: "ax_press",
    effectOutcome: "verified",
    queueLatencyMs: 3,
    executionLatencyMs: 11
  )
}

private func perceptionMetric() -> PerceptionMetric {
  PerceptionMetric(
    operation: "operation-1",
    tool: "get_app_state",
    appBundleIdentifier: "com.example.fixture",
    perceptionMs: 22,
    settleMs: 4,
    screenshotMs: 5,
    snapshotMs: 6,
    verificationMs: 2,
    responseConstructionMs: 3,
    otherMs: 2,
    elementsVisited: 50,
    elementsReturned: 20,
    partial: true,
    responseEncoding: .diff,
    textBytes: 2048,
    screenshotPNGBytes: 4096
  )
}
