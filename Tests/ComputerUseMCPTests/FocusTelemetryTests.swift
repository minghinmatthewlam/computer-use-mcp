 #if os(macOS)
import MCP
import Testing

@testable import computer_use_mcp

@Suite struct FocusTelemetryTests {
    @Test func focusTelemetryReportsStableFrontmostApp() throws {
        let app = FrontmostAppSnapshot(name: "Finder", bundleIdentifier: "com.apple.finder", pid: 42)
        let telemetry = FocusTelemetry(
            before: app,
            after: app,
            deliveryTier: InputTier.accessibilityAttribute.rawValue,
            focusChangeAllowed: false,
            cursorMovementAllowed: false
        )

        guard case let .object(fields) = telemetry.focusValue else {
            Issue.record("expected object telemetry")
            return
        }
        #expect(fields["focus_changed"]?.boolValue == false)
        #expect(fields["focus_change_allowed"]?.boolValue == false)
        #expect(fields["cursor_movement_allowed"]?.boolValue == false)
        // delivery_tier now lives in the sibling delivery block, not focus.
        #expect(fields["delivery_tier"] == nil)
        guard case let .object(delivery)? = telemetry.deliveryValue else {
            Issue.record("expected delivery block")
            return
        }
        #expect(delivery["delivery_tier"]?.stringValue == InputTier.accessibilityAttribute.rawValue)
    }

    @Test func focusTelemetryReportsChangedFrontmostApp() throws {
        let before = FrontmostAppSnapshot(name: "Finder", bundleIdentifier: "com.apple.finder", pid: 42)
        let after = FrontmostAppSnapshot(name: "Fixture", bundleIdentifier: "dev.computer-use.fixture", pid: 99)
        let telemetry = FocusTelemetry(
            before: before,
            after: after,
            deliveryTier: InputTier.globalCursor.rawValue,
            focusChangeAllowed: true,
            cursorMovementAllowed: true
        )

        guard case let .object(fields) = telemetry.focusValue else {
            Issue.record("expected object telemetry")
            return
        }
        #expect(fields["focus_changed"]?.boolValue == true)
        #expect(fields["focus_change_allowed"]?.boolValue == true)
        #expect(fields["cursor_movement_allowed"]?.boolValue == true)
    }

    @Test func focusTelemetryReportsUIChangeBit() throws {
        let app = FrontmostAppSnapshot(name: "Finder", bundleIdentifier: "com.apple.finder", pid: 42)
        var telemetry = FocusTelemetry(
            before: app, after: app,
            deliveryTier: InputTier.perPid.rawValue,
            focusChangeAllowed: false, cursorMovementAllowed: false
        )
        // ui_changed unset: the delivery block has only the tier, no ui_changed.
        guard case let .object(unset)? = telemetry.deliveryValue else {
            Issue.record("expected delivery block")
            return
        }
        #expect(unset["ui_changed"] == nil)

        telemetry.uiChanged = false
        guard case let .object(fields)? = telemetry.deliveryValue else {
            Issue.record("expected delivery block")
            return
        }
        #expect(fields["ui_changed"]?.boolValue == false)
        // The focus block never carries ui_changed.
        guard case let .object(focus) = telemetry.focusValue else {
            Issue.record("expected focus block")
            return
        }
        #expect(focus["ui_changed"] == nil)
    }

    @Test func droppedEventHintOnlyForBackgroundEventTiers() {
        #expect(droppedEventHint(deliveryTier: InputTier.perWindow.rawValue) != nil)
        #expect(droppedEventHint(deliveryTier: InputTier.perPid.rawValue) != nil)
        #expect(droppedEventHint(deliveryTier: InputTier.accessibilityAction.rawValue) == nil)
        #expect(droppedEventHint(deliveryTier: InputTier.accessibilityAttribute.rawValue) == nil)
        #expect(droppedEventHint(deliveryTier: InputTier.globalCursor.rawValue) == nil)
        #expect(droppedEventHint(deliveryTier: nil) == nil)
    }

    @Test func typedTextReadBackWarnsOnlyOnMissingText() {
        #expect(typedTextWarning(typed: "hello", currentValue: "say hello world") == nil)
        #expect(typedTextWarning(typed: "hello", currentValue: "unrelated") != nil)
        // Not verifiable: no value, empty text, or text too long to compare.
        #expect(typedTextWarning(typed: "hello", currentValue: nil) == nil)
        #expect(typedTextWarning(typed: "", currentValue: "anything") == nil)
        #expect(typedTextWarning(typed: String(repeating: "a", count: 501), currentValue: "x") == nil)
    }

    @Test func globalCursorRequiresExplicitFocusChangeAllowance() throws {
        let message = invalidArgumentMessage {
            _ = try allowGlobalCursorArgument(["allow_global_cursor": .bool(true)])
        }
        #expect(message.contains("\"allow_global_cursor\""))
        #expect(message.contains("\"allow_focus_change\""))

        #expect(try allowGlobalCursorArgument(["allow_global_cursor": .bool(true), "allow_focus_change": .bool(true)]))
        #expect(try allowGlobalCursorArgument([:]) == false)
    }

    @Test func globalKeyboardRequiresExplicitFocusChangeAllowance() throws {
        let message = invalidArgumentMessage {
            _ = try allowGlobalKeyboardArgument(["allow_global_cursor": .bool(true)])
        }
        #expect(message.contains("\"allow_global_cursor\""))
        #expect(message.contains("\"allow_focus_change\""))

        #expect(try allowGlobalKeyboardArgument(["allow_global_cursor": .bool(true), "allow_focus_change": .bool(true)]))
        #expect(try allowGlobalKeyboardArgument([:]) == false)
    }

    @Test func globalKeyboardAcceptsAllowGlobalKeyboardAlias() throws {
        let message = invalidArgumentMessage {
            _ = try allowGlobalKeyboardArgument(["allow_global_keyboard": .bool(true)])
        }
        #expect(message.contains("\"allow_global_keyboard\""))
        #expect(message.contains("\"allow_focus_change\""))

        #expect(
            try allowGlobalKeyboardArgument([
                "allow_global_keyboard": .bool(true),
                "allow_focus_change": .bool(true),
            ])
        )
        // Wire-compat: either name enables the escape hatch.
        #expect(
            try allowGlobalKeyboardArgument([
                "allow_global_cursor": .bool(true),
                "allow_focus_change": .bool(true),
            ])
        )
    }

    @Test func focusMutatingToolsRequireExplicitFocusChangeAllowance() throws {
        let message = invalidArgumentMessage {
            try requireFocusChangeAllowed([:], reason: "This may change focus.")
        }
        #expect(message.contains("allow_focus_change"))

        try requireFocusChangeAllowed(["allow_focus_change": .bool(true)], reason: "This may change focus.")
    }

    @Test func resultMetadataMergesFocusTelemetry() {
        let app = FrontmostAppSnapshot(name: "Finder", bundleIdentifier: "com.apple.finder", pid: 42)
        let telemetry = FocusTelemetry(
            before: app,
            after: app,
            deliveryTier: InputTier.accessibilityAction.rawValue,
            focusChangeAllowed: false,
            cursorMovementAllowed: false
        )

        let result = CallTool.Result.text("ok").withFocusTelemetry(telemetry)
        #expect(result._meta?["computer-use-mcp/focus"] != nil)
    }

    @Test func focusTrackerUsesExplicitPolicyNotRawArguments() {
        let tracker = FocusChangeTracker.start()
        let telemetry = tracker.finish()

        guard case let .object(fields) = telemetry.focusValue else {
            Issue.record("expected object telemetry")
            return
        }
        #expect(fields["focus_change_allowed"]?.boolValue == false)
        #expect(fields["cursor_movement_allowed"]?.boolValue == false)
    }
}

private func invalidArgumentMessage(_ body: () throws -> Void) -> String {
    do {
        try body()
    } catch let error as ToolError {
        if case .invalidArguments(let message) = error {
            return message
        }
        return String(describing: error)
    } catch {
        return String(describing: error)
    }
    return ""
}
#endif
