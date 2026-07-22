import Foundation
import MCP
#if os(macOS)
import AppKit
import ApplicationServices
#endif

private let focusTelemetryMetaKey = "computer-use-mcp/focus"
private let deliveryTelemetryMetaKey = "computer-use-mcp/delivery"

struct FrontmostAppSnapshot: Equatable {
    let name: String
    let bundleIdentifier: String
    let pid: pid_t

    static func current() -> FrontmostAppSnapshot? {
        // NSWorkspace.frontmostApplication is KVO-updated on a serviced run
        // loop and freezes in the daemon (same failure as its
        // runningApplications had): the interference guard then pins "the
        // app the user is working in" to whatever was frontmost at daemon
        // spawn. The window server is always current: the frontmost app is
        // the owner of the frontmost normal-layer on-screen window.
        let windows =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                let app = NSRunningApplication(processIdentifier: pid)
            else { continue }
            return FrontmostAppSnapshot(
                name: app.localizedName ?? "unknown",
                bundleIdentifier: app.bundleIdentifier ?? "",
                pid: pid
            )
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontmostAppSnapshot(
            name: app.localizedName ?? "unknown",
            bundleIdentifier: app.bundleIdentifier ?? "",
            pid: app.processIdentifier
        )
    }

    var value: Value {
        .object([
            "name": .string(name),
            "bundle_identifier": .string(bundleIdentifier),
            "pid": .int(Int(pid)),
        ])
    }
}

struct FocusTelemetry: Equatable {
    let before: FrontmostAppSnapshot?
    let after: FrontmostAppSnapshot?
    let deliveryTier: String?
    let focusChangeAllowed: Bool
    let cursorMovementAllowed: Bool
    /// Why the ladder skipped higher-priority tiers to reach `deliveryTier`
    /// (FallbackReason raw values, in tier order). Empty when the top viable
    /// tier was used. Surfaced so callers learn WHY delivery fell through.
    var fallbackReasons: [String] = []
    /// Whether the re-perceived UI tree differed from the pre-action snapshot.
    /// Factual dirty bit — an unchanged tree after a background-event delivery
    /// is the one observable hint that the app may have dropped the event.
    var uiChanged: Bool? = nil
    /// Which multi-strategy AX chain rung landed (its verified effect was
    /// observed), when tier 1 was a chain. nil for non-chain deliveries.
    var landedRung: String? = nil

    var focusChanged: Bool {
        before != after
    }

    /// The `computer-use-mcp/focus` block: strictly frontmost-app identity and
    /// the focus/cursor policy for this call. Delivery telemetry lives in its
    /// own sibling block (`deliveryValue`).
    var focusValue: Value {
        var fields: [String: Value] = [
            "focus_changed": .bool(focusChanged),
            "focus_change_allowed": .bool(focusChangeAllowed),
            "cursor_movement_allowed": .bool(cursorMovementAllowed),
        ]
        if let before {
            fields["frontmost_before"] = before.value
        }
        if let after {
            fields["frontmost_after"] = after.value
        }
        return .object(fields)
    }

    /// The `computer-use-mcp/delivery` block: which tier landed the event, why
    /// the ladder fell through, and whether the UI changed. nil when there is
    /// nothing to report (read-only recapture with no delivery). Kept separate
    /// from focus so delivery ("how we tried to make it happen") sits next to
    /// the outcome contract ("did it happen").
    var deliveryValue: Value? {
        var fields: [String: Value] = [:]
        if let deliveryTier {
            fields["delivery_tier"] = .string(deliveryTier)
        }
        if !fallbackReasons.isEmpty {
            fields["fallback_reasons"] = .array(fallbackReasons.map { .string($0) })
        }
        if let landedRung {
            fields["chain_rung"] = .string(landedRung)
        }
        if let uiChanged {
            fields["ui_changed"] = .bool(uiChanged)
        }
        return fields.isEmpty ? nil : .object(fields)
    }
}

struct FocusChangeTracker {
    let before: FrontmostAppSnapshot?
    let focusChangeAllowed: Bool
    let cursorMovementAllowed: Bool

    static func start(focusChangeAllowed: Bool = false, cursorMovementAllowed: Bool = false) -> FocusChangeTracker {
        FocusChangeTracker(
            before: FrontmostAppSnapshot.current(),
            focusChangeAllowed: focusChangeAllowed,
            cursorMovementAllowed: cursorMovementAllowed
        )
    }

    func finish(
        deliveryTier: String? = nil, fallbackReasons: [FallbackReason] = [], landedRung: String? = nil
    ) -> FocusTelemetry {
        FocusTelemetry(
            before: before,
            after: FrontmostAppSnapshot.current(),
            deliveryTier: deliveryTier,
            focusChangeAllowed: focusChangeAllowed,
            cursorMovementAllowed: cursorMovementAllowed,
            fallbackReasons: fallbackReasons.map(\.rawValue),
            landedRung: landedRung
        )
    }
}

func allowGlobalCursorArgument(_ args: [String: Value]) throws -> Bool {
    let allowGlobalCursor = args.bool("allow_global_cursor") == true
    if allowGlobalCursor && args.bool("allow_focus_change") != true {
        throw ToolError.invalidArguments(
            "\"allow_global_cursor\" may move the real cursor and change foreground focus. "
                + "Retry with \"allow_focus_change\": true when that escalation is intentional."
        )
    }
    return allowGlobalCursor
}

func allowGlobalKeyboardArgument(_ args: [String: Value]) throws -> Bool {
    // Preferred name is allow_global_keyboard; allow_global_cursor remains a
    // wire-compat alias used by older clients / press_key schemas.
    let viaCursorAlias = args.bool("allow_global_cursor") == true
    let viaKeyboardName = args.bool("allow_global_keyboard") == true
    let allowGlobalKeyboard = viaCursorAlias || viaKeyboardName
    if allowGlobalKeyboard && args.bool("allow_focus_change") != true {
        let flag = viaKeyboardName && !viaCursorAlias ? "allow_global_keyboard" : "allow_global_cursor"
        throw ToolError.invalidArguments(
            "\"\(flag)\" sends keyboard input through the global session tap and may change focus. "
                + "Retry with \"allow_focus_change\": true when that escalation is intentional."
        )
    }
    return allowGlobalKeyboard
}

func requireFocusChangeAllowed(_ args: [String: Value], reason: String) throws {
    guard args.bool("allow_focus_change") == true else {
        throw ToolError.invalidArguments(
            "\(reason) Retry with \"allow_focus_change\": true when changing foreground focus is intentional."
        )
    }
}

extension CallTool.Result {
    /// Attach one `computer-use-mcp/*` _meta field, preserving any already set
    /// by another emission path (focus/delivery/outcome share one _meta block).
    func mergingMetaField(_ key: String, _ value: Value) -> CallTool.Result {
        var result = self
        var fields = result._meta?.fields ?? [:]
        fields[key] = value
        result._meta = Metadata(additionalFields: fields)
        return result
    }

    func withFocusTelemetry(_ telemetry: FocusTelemetry?) -> CallTool.Result {
        guard let telemetry else { return self }
        var result = mergingMetaField(focusTelemetryMetaKey, telemetry.focusValue)
        if let delivery = telemetry.deliveryValue {
            result = result.mergingMetaField(deliveryTelemetryMetaKey, delivery)
        }
        return result
    }
}
