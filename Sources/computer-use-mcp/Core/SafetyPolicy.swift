// Server-side safety policy.
//
// This MCP server can be driven by any agent, so it does not rely on the
// client's model to restrain itself. Clearly destructive/irreversible actions,
// typing into secure (password) fields, and actions against apps on a
// confirmation list require the caller to pass confirm:true. The model sees a
// clear, recoverable error explaining what to confirm — it never silently
// performs the risky action.
//
// Everything here is configurable and fully disable-able:
//   COMPUTER_USE_MCP_NO_SAFETY=1            disable the policy entirely
//   COMPUTER_USE_MCP_CONFIRM_APPS=a,b,c     apps where every action needs confirm
//   COMPUTER_USE_MCP_DESTRUCTIVE=pat,pat    extra destructive label substrings

import Foundation
#if os(macOS)
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
#endif
import MCP

struct SafetyError: Error, CustomStringConvertible {
    let reason: String
    var description: String {
        "Confirmation required: \(reason) Re-run the same call with \"confirm\": true to proceed."
    }
}

enum SafetyPolicy {
    static var isEnabled: Bool { Config.bool("no_safety") != true }

    /// Default destructive label substrings (case-insensitive), plus any configured.
    private static var destructivePatterns: [String] {
        let defaults = [
            "delete", "remove", "erase", "trash", "discard", "don't save", "dont save",
            "reset", "format", "uninstall", "destroy", "wipe", "shut down", "log out",
        ]
        return defaults + Config.list("destructive")
    }

    /// Apps where every action requires confirmation (none by default).
    private static var confirmApps: Set<String> {
        Set(Config.list("confirm_apps"))
    }

    static func confirmed(_ args: [String: Value]) -> Bool {
        args.bool("confirm") == true
    }

    static func checkOpenApp(identifier: String, activate: Bool, isAlreadyRunning: Bool, confirmed: Bool) throws {
        guard isEnabled, !confirmed else { return }
        if activate {
            throw SafetyError(reason: "activating \(identifier) changes the user's foreground app.")
        }
        if !isAlreadyRunning {
            throw SafetyError(reason: "launching \(identifier) starts a local application and may run app startup handlers.")
        }
    }

    static func checkOpenURL(
        _ url: URL, confirmed: Bool,
        denyPatterns: [String] = URLPolicy.denyPatterns,
        confirmPatterns: [String] = URLPolicy.confirmPatterns
    ) throws {
        guard isEnabled else { return }
        // Same decision function as the browser action gate; the URL argument
        // is always known here, so unreadable-URL handling does not apply.
        switch urlPolicyDecision(
            url: url.absoluteString, denyPatterns: denyPatterns,
            confirmPatterns: confirmPatterns, hasExplicitPolicy: false
        ) {
        case .deny(let reason):
            // url_deny is a hard block: confirm does not override it.
            throw ToolError.failed(urlDenyMessage(reason))
        case .requireConfirm(let reason):
            if !confirmed { throw SafetyError(reason: reason + ".") }
        case .allow:
            break
        }
        guard !confirmed else { return }
        let scheme = url.scheme?.lowercased() ?? "file"
        switch scheme {
        case "http", "https":
            return
        case "file":
            throw SafetyError(reason: "opening a local file can launch apps or trigger document handlers.")
        default:
            throw SafetyError(reason: "opening a \(scheme):// URL can trigger an arbitrary app handler.")
        }
    }

    static func checkClipboardWrite(confirmed: Bool) throws {
        guard isEnabled, !confirmed else { return }
        throw SafetyError(reason: "writing the system clipboard overwrites the user's current clipboard contents.")
    }

    /// Gate an action against an app. Throws when confirmation is required and
    /// not given.
    static func check(app: ResolvedApp, confirmed: Bool) throws {
        guard isEnabled, !confirmed else { return }
        if confirmApps.contains(app.name.lowercased()) || confirmApps.contains(app.bundleIdentifier.lowercased()) {
            throw SafetyError(reason: "\(app.name) is on the confirmation list, so all actions against it must be confirmed.")
        }
    }

    /// Gate a click by its element label (destructive button text).
    static func checkClick(label: String?, app: ResolvedApp, confirmed: Bool) throws {
        guard isEnabled, !confirmed, let label, !label.isEmpty else { return }
        let lower = label.lowercased()
        if let hit = destructivePatterns.first(where: { lower.contains($0) }) {
            throw SafetyError(
                reason: "\"\(label)\" in \(app.name) looks destructive or irreversible (matched \"\(hit)\")."
            )
        }
    }

    /// Gate typing into a secure (password) field.
    static func checkTyping(into element: AXUIElement, app: ResolvedApp, confirmed: Bool) throws {
        guard isEnabled, !confirmed else { return }
        let subrole = axString(element, kAXSubroleAttribute)
        if subrole == (kAXSecureTextFieldSubrole as String) {
            throw SafetyError(
                reason: "the target in \(app.name) is a secure text field (password entry)."
            )
        }
    }

    /// Gate a key press: text insertion into secure fields, inherently
    /// destructive shortcuts (⌘⌫ etc.), and Return/Space activating a
    /// focused destructive control.
    static func checkKey(
        combo: String, chord: KeyChord, focused: AXUIElement?, app: ResolvedApp, confirmed: Bool
    ) throws {
        guard isEnabled, !confirmed else { return }
        // Same secure-field policy as checkTyping: printable keys must not
        // enter a password character-by-character without confirm. Primary
        // signal is the AX secure-text subrole; secure-event-input is a
        // cheap secondary when AX focus is missing or incomplete.
        try checkSecureFieldKeyInsertion(
            insertsText: Keymap.wouldInsertText(combo: combo, chord: chord),
            focusedSubrole: focused.flatMap { axString($0, kAXSubroleAttribute) },
            secureEventInputEnabled: IsSecureEventInputEnabled(),
            app: app,
            confirmed: confirmed
        )
        let deleteKeys: Set<CGKeyCode> = [CGKeyCode(kVK_Delete), CGKeyCode(kVK_ForwardDelete)]
        if chord.flags.contains(.maskCommand), deleteKeys.contains(chord.keyCode) {
            throw SafetyError(reason: "\"\(combo)\" is a destructive keyboard shortcut in \(app.name).")
        }
        let activateKeys: Set<CGKeyCode> = [
            CGKeyCode(kVK_Return), CGKeyCode(kVK_ANSI_KeypadEnter), CGKeyCode(kVK_Space),
        ]
        if activateKeys.contains(chord.keyCode), let focused {
            try checkClick(label: clickableLabel(focused), app: app, confirmed: confirmed)
        }
    }

    /// Pure-ish gate for press_key → secure field (testable without AX).
    /// Throws the same SafetyError as checkTyping when confirmation is required.
    static func checkSecureFieldKeyInsertion(
        insertsText: Bool,
        focusedSubrole: String?,
        secureEventInputEnabled: Bool,
        app: ResolvedApp,
        confirmed: Bool
    ) throws {
        guard isEnabled, !confirmed else { return }
        guard keyPressRequiresSecureFieldConfirm(
            insertsText: insertsText,
            focusedSubrole: focusedSubrole,
            secureEventInputEnabled: secureEventInputEnabled
        ) else { return }
        throw SafetyError(
            reason: "the target in \(app.name) is a secure text field (password entry)."
        )
    }

    /// Gate an action that clears a non-empty value (a destructive wipe).
    static func checkValueChange(currentValue: String?, newValue: String, app: ResolvedApp, confirmed: Bool) throws {
        guard isEnabled, !confirmed else { return }
        if let current = currentValue, !current.isEmpty, newValue.isEmpty {
            throw SafetyError(reason: "this clears existing content in \(app.name).")
        }
    }

    /// Gate window-level actions. Closing a window can discard user state or
    /// trigger save/discard dialogs, so require explicit confirmation.
    static func checkWindowAction(action: String, targetDescription: String, app: ResolvedApp, confirmed: Bool) throws {
        try check(app: app, confirmed: confirmed)
        guard isEnabled, !confirmed else { return }
        if action == "close" {
            throw SafetyError(reason: "closing \(targetDescription) may discard unsaved state or dismiss important UI.")
        }
    }
}

/// Pure decision: a text-inserting key into a secure field (or while
/// secure event input is active) requires confirm.
func keyPressRequiresSecureFieldConfirm(
    insertsText: Bool,
    focusedSubrole: String?,
    secureEventInputEnabled: Bool = false
) -> Bool {
    guard insertsText else { return false }
    if focusedSubrole == (kAXSecureTextFieldSubrole as String) { return true }
    return secureEventInputEnabled
}

enum ArgumentBounds {
    static let maxClickCount = 2
    static let maxTypeTextCharacters = 100_000
    static let maxSetValueCharacters = 100_000
    static let maxClipboardCharacters = 200_000
    static let maxReadTextCharacters = 20_000
    static let maxScrollPages = 10.0
    static let minScrollPages = 0.1
    static let maxScrollDelta = 10_000
    static let maxWindowCoordinateMagnitude = 100_000.0
    static let minWindowDimension = 1.0
    static let maxWindowDimension = 100_000.0

    static func checkStringLength(_ value: String, argument: String, maximum: Int) throws {
        if value.count > maximum {
            throw ToolError.invalidArguments(
                "\"\(argument)\" is \(value.count) characters; maximum is \(maximum). "
                    + "Send a smaller value or split the operation into chunks."
            )
        }
    }

    static func checkClickCount(_ count: Int) throws -> Int {
        if count < 1 || count > maxClickCount {
            throw ToolError.invalidArguments("\"click_count\" must be between 1 and \(maxClickCount).")
        }
        return count
    }

    static func checkReadText(offset: Int, length: Int) throws {
        if offset < 0 {
            throw ToolError.invalidArguments("\"offset\" must be at least 0.")
        }
        if length < 1 {
            throw ToolError.invalidArguments("\"length\" must be at least 1.")
        }
        if length > maxReadTextCharacters {
            throw ToolError.invalidArguments(
                "\"length\" is \(length); maximum is \(maxReadTextCharacters). Use offset/length chunking."
            )
        }
    }

    static func checkScrollPages(_ pages: Double) throws -> Double {
        guard pages.isFinite else {
            throw ToolError.invalidArguments("\"pages\" must be a finite number.")
        }
        if pages < minScrollPages || pages > maxScrollPages {
            throw ToolError.invalidArguments("\"pages\" must be between \(minScrollPages) and \(maxScrollPages).")
        }
        return pages
    }

    static func checkScrollDelta(deltaX: Int, deltaY: Int) throws {
        if deltaX < -maxScrollDelta || deltaX > maxScrollDelta || deltaY < -maxScrollDelta || deltaY > maxScrollDelta {
            throw ToolError.invalidArguments(
                "\"delta_x\" and \"delta_y\" must be between -\(maxScrollDelta) and \(maxScrollDelta)."
            )
        }
    }

    static func checkWindowPosition(x: Double, y: Double) throws {
        try checkFinite(x, argument: "x")
        try checkFinite(y, argument: "y")
        if abs(x) > maxWindowCoordinateMagnitude || abs(y) > maxWindowCoordinateMagnitude {
            throw ToolError.invalidArguments(
                "\"x\" and \"y\" must be between -\(Int(maxWindowCoordinateMagnitude)) "
                    + "and \(Int(maxWindowCoordinateMagnitude)) global screen points."
            )
        }
    }

    static func checkWindowSize(width: Double, height: Double) throws {
        try checkFinite(width, argument: "width")
        try checkFinite(height, argument: "height")
        if width < minWindowDimension || width > maxWindowDimension
            || height < minWindowDimension || height > maxWindowDimension
        {
            throw ToolError.invalidArguments(
                "\"width\" and \"height\" must be between \(Int(minWindowDimension)) "
                    + "and \(Int(maxWindowDimension)) points."
            )
        }
    }

    private static func checkFinite(_ value: Double, argument: String) throws {
        guard value.isFinite else {
            throw ToolError.invalidArguments("\"\(argument)\" must be a finite number.")
        }
    }
}
