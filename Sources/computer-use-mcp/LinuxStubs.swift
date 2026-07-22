#if os(Linux)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MCP

enum InputTier: String {
    case accessibilityAction = "tier1-ax-action"
    case accessibilityAttribute = "tier1-ax-attribute"
    case perWindow = "tier2-per-window-nsevent"
    case skyLight = "tier25-skylight-sleventpostto-pid"
    case perPid = "tier3-cgeventpostto-pid"
    case globalCursor = "tier4-global-cursor"
    case pasteboard = "pasteboard"
    case launchServices = "launchservices"
    case windowManagement = "ax-window-management"
}

enum KeyDeliveryMode: String, Equatable {
    case skyLight = "tier25-skylight-sleventpostto-pid"
    case perPid = "tier3-cgeventpostto-pid"
    case globalSessionTap = "tier4-global-session-tap"
}

enum FallbackReason: String, Equatable, Sendable {
    case axActionUnsupported = "ax-action-unsupported"
    case windowNumberUnresolved = "window-number-unresolved"
    case windowFrameUnresolved = "window-frame-unresolved"
    case eventBridgeFailed = "event-bridge-failed"
    case skyLightUnavailable = "skylight-unavailable"
    case globalCursorRequested = "global-cursor-requested"
    case noScrollContainerFound = "no-scroll-container-found"
    case scrollActionUnverified = "scroll-action-unverified"
    case chainAXPressUnverified = "chain-ax-press-unverified"
    case chainAXConfirmUnverified = "chain-ax-confirm-unverified"
    case chainAXOpenUnverified = "chain-ax-open-unverified"
    case chainAXPickUnverified = "chain-ax-pick-unverified"
    case chainSelectionRelayUnverified = "chain-selection-relay-unverified"
    case chainChildActionUnverified = "chain-child-action-unverified"
    case chainAncestorActionUnverified = "chain-ancestor-action-unverified"
}

struct DeliveryOutcome: Equatable {
    let tier: InputTier
    let fallbackReasons: [FallbackReason]

    init(tier: InputTier, fallbackReasons: [FallbackReason] = []) {
        self.tier = tier
        self.fallbackReasons = fallbackReasons
    }
}

struct DeliveryContext {
    let pid: pid_t
    let windowNumber: CGWindowID?
    let windowFrame: CGRect?
    let allowGlobalCursor: Bool
}

enum MouseButtonKind {
    case left, right, middle
    var cgButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }
    var downType: CGEventType {
        switch self {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }
    var upType: CGEventType {
        switch self {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }
}

struct KeyChord {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

enum Keymap {
    static func parse(_ combo: String) throws -> KeyChord {
        var tokens = combo.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let key = tokens.popLast(), !key.isEmpty else {
            throw ToolError.invalidArguments("Empty key string.")
        }
        var flags: CGEventFlags = []
        for token in tokens {
            switch token.lowercased() {
            case "cmd", "command", "super", "meta": flags.insert(.maskCommand)
            case "ctrl", "control": flags.insert(.maskControl)
            case "alt", "option": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            case "fn": flags.insert(.maskSecondaryFn)
            default: throw ToolError.invalidArguments("Unknown modifier \"\(token)\".")
            }
        }
        let named: [String: CGKeyCode] = [
            "return": CGKeyCode(kVK_Return), "enter": CGKeyCode(kVK_Return),
            "tab": CGKeyCode(kVK_Tab), "escape": CGKeyCode(kVK_Escape),
            "esc": CGKeyCode(kVK_Escape), "space": CGKeyCode(kVK_Space),
            "delete": CGKeyCode(kVK_Delete), "up": CGKeyCode(kVK_UpArrow),
            "down": CGKeyCode(kVK_DownArrow), "left": CGKeyCode(kVK_LeftArrow),
            "right": CGKeyCode(kVK_RightArrow)
        ]
        let code: CGKeyCode
        if let namedCode = named[key.lowercased()] {
            code = namedCode
        } else if key.count == 1, let scalar = key.unicodeScalars.first, scalar.isASCII {
            code = CGKeyCode(scalar.value)
            if "!@#$%^&*()_+{}|:\"<>?" .contains(key) {
                flags.insert(.maskShift)
            }
        } else {
            throw ToolError.invalidArguments("Unknown key \"\(key)\".")
        }
        return KeyChord(keyCode: code, flags: flags)
    }
    static func wouldInsertText(combo: String, chord: KeyChord) -> Bool {
        let lower = combo.lowercased()
        guard !chord.flags.contains(.maskCommand), !chord.flags.contains(.maskControl),
            !chord.flags.contains(.maskAlternate)
        else { return false }
        return lower == "space" || (combo.count == 1 && combo.first?.isLetter == true) || combo == "?"
    }
}

enum TextExtraction {
    struct VisibleText {
        var markdown: String
        var range: CFRange
    }

    static func visibleText(of element: AXUIElement) -> VisibleText? { nil }
    static func webAreaMarkdown(of element: AXUIElement) -> String? { nil }
}

func attributedStringToMarkdown(_ attributed: NSAttributedString) -> String { attributed.string }

func perWindowFallbackReasons(context: DeliveryContext, bridgeSucceeded: Bool) -> [FallbackReason] {
    var reasons: [FallbackReason] = []
    if context.windowNumber == nil { reasons.append(.windowNumberUnresolved) }
    if context.windowFrame == nil { reasons.append(.windowFrameUnresolved) }
    if context.windowNumber != nil, context.windowFrame != nil, !bridgeSucceeded {
        reasons.append(.eventBridgeFailed)
    }
    return reasons
}
func isDroppableBackgroundDeliveryTier(_ rawTier: String) -> Bool {
    rawTier == InputTier.perWindow.rawValue
        || rawTier == InputTier.skyLight.rawValue
        || rawTier == InputTier.perPid.rawValue
        || rawTier == KeyDeliveryMode.skyLight.rawValue
        || rawTier == KeyDeliveryMode.perPid.rawValue
}

@discardableResult
func deliverClick(
    at point: CGPoint, button: MouseButtonKind, clickCount: Int, context: DeliveryContext,
    allowGlobalCursor: Bool = false
) throws -> DeliveryOutcome {
    DeliveryOutcome(tier: .windowManagement, fallbackReasons: [])
}

@discardableResult
func deliverScroll(at point: CGPoint, deltaX: Int, deltaY: Int, context: DeliveryContext) -> InputTier { .windowManagement }

@discardableResult
func deliverDrag(from: CGPoint, to: CGPoint, context: DeliveryContext) async -> InputTier { .windowManagement }

@discardableResult
func typeUnicodeText(_ text: String, context: DeliveryContext) throws -> InputTier {
    throw ToolError.notImplemented("Text input is unsupported on Linux.")
}

func keyDeliveryMode(context: DeliveryContext, targetAppIsActive: Bool) throws -> KeyDeliveryMode {
    if context.allowGlobalCursor {
        guard targetAppIsActive else {
            throw ToolError.failed("Global keyboard delivery requires a foreground target.")
        }
        return .globalSessionTap
    }
    return .perPid
}

func deliverKey(_ chord: KeyChord, context: DeliveryContext, targetAppIsActive: Bool) throws -> KeyDeliveryMode {
    throw ToolError.notImplemented("Keyboard input is unsupported on Linux.")
}

func syntheticFallbackReasons(context: DeliveryContext, allowGlobalCursor: Bool) -> [FallbackReason] { [] }
func windowID(for axWindow: AXUIElement) -> CGWindowID? { nil }
func dragReleasePoint(from: CGPoint, to: CGPoint, aborted: Bool) -> CGPoint { aborted ? from : to }
func unicodeTypingChunks(_ text: String) -> [[UniChar]] {
    text.map { Array(String($0).utf16) }
}

func openAppImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.notImplemented("App launching is unsupported on Linux.")
}
func openURLImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.notImplemented("URL opening is unsupported on Linux.")
}
func listWindowsImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.notImplemented("Window enumeration is unsupported on Linux.")
}
func manageWindowImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.notImplemented("Window management is unsupported on Linux.")
}
func clickMenuItemImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.notImplemented("Menu interaction is unsupported on Linux.")
}
func readClipboardImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.notImplemented("Clipboard access is unsupported on Linux.")
}
func writeClipboardImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.notImplemented("Clipboard access is unsupported on Linux.")
}
func clipboardRestoreValue(committed: Bool, previous: String?) -> String? { committed ? nil : previous }
func waitForImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.notImplemented("Waiting for UI conditions is unsupported on Linux.")
}
func typeTextImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.notImplemented("Text entry is unsupported on Linux.")
}
func setValueImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.notImplemented("Value editing is unsupported on Linux.")
}
func selectTextImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.notImplemented("Text selection is unsupported on Linux.")
}
func readTextImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.notImplemented("Text reading is unsupported on Linux.")
}
func performSecondaryActionImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.notImplemented("Secondary actions are unsupported on Linux.")
}

struct PageCoordinateProbe: Equatable {
    let viewportX: Double
    let viewportY: Double
    let contentScreenX: Double
    let contentScreenY: Double
    let devicePixelRatio: Double
    var screenPoint: CGPoint {
        CGPoint(x: contentScreenX + viewportX, y: contentScreenY + viewportY)
    }
}
struct PageDOMSnapshot: Equatable {
    let value: String?
    let text: String?
    let pageSignature: String?
    func differs(from other: PageDOMSnapshot?) -> Bool { false }
}
struct PageProbe { let coordinate: PageCoordinateProbe; let snapshot: PageDOMSnapshot }
enum PageAction: String { case click, setText = "set_text" }
enum PageHostType: String, Equatable { case chromium, safari, electron, wkWebView = "wk_webview", unsupported }
protocol PageJavaScriptExecuting {
    func evaluate(_ javascript: String, app: ResolvedApp, window: TargetWindow, cdpPort: Int?, targetURLContains: String?) async throws -> String
    func insertText(_ text: String, selector: String, app: ResolvedApp, window: TargetWindow, cdpPort: Int?, targetURLContains: String?) async throws
}
struct SystemPageJavaScriptExecutor: PageJavaScriptExecuting {
    func evaluate(_ javascript: String, app: ResolvedApp, window: TargetWindow, cdpPort: Int?, targetURLContains: String?) async throws -> String {
        throw ToolError.notImplemented("Page JavaScript execution is unsupported on Linux.")
    }
    func insertText(_ text: String, selector: String, app: ResolvedApp, window: TargetWindow, cdpPort: Int?, targetURLContains: String?) async throws {}
}

func pageImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.notImplemented("Page interaction is unsupported on Linux.")
}
func pageProbe(selector: String, app: ResolvedApp, window: TargetWindow, cdpPort: Int?, targetURLContains: String?) async throws -> PageProbe {
    throw ToolError.notImplemented("Page interaction is unsupported on Linux.")
}
func pageDOMSnapshot(selector: String, app: ResolvedApp, window: TargetWindow, cdpPort: Int?, targetURLContains: String?) async throws -> PageDOMSnapshot {
    throw ToolError.notImplemented("Page interaction is unsupported on Linux.")
}
func parsePageProbe(_ raw: String) throws -> PageProbe {
    let object = try parsePageJSONObject(raw)
    guard
        let viewportX = (object["vx"] as? NSNumber)?.doubleValue,
        let viewportY = (object["vy"] as? NSNumber)?.doubleValue,
        let contentScreenX = (object["sx"] as? NSNumber)?.doubleValue,
        let contentScreenY = (object["sy"] as? NSNumber)?.doubleValue
    else {
        throw ToolError.failed("page: JavaScript probe missing numeric coordinates: \(raw)")
    }
    let coordinate = PageCoordinateProbe(
        viewportX: viewportX,
        viewportY: viewportY,
        contentScreenX: contentScreenX,
        contentScreenY: contentScreenY,
        devicePixelRatio: (object["dpr"] as? NSNumber)?.doubleValue ?? 1
    )
    return PageProbe(
        coordinate: coordinate,
        snapshot: PageDOMSnapshot(
            value: object["value"] as? String,
            text: object["text"] as? String,
            pageSignature: object["pageSignature"] as? String
        )
    )
}
func parsePageDOMSnapshot(_ raw: String) throws -> PageDOMSnapshot {
    let object = try parsePageJSONObject(raw)
    return PageDOMSnapshot(
        value: object["value"] as? String,
        text: object["text"] as? String,
        pageSignature: object["pageSignature"] as? String
    )
}
private func parsePageJSONObject(_ raw: String) throws -> [String: Any] {
    let first = try JSONSerialization.jsonObject(with: Data(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8), options: [.fragmentsAllowed])
    if let string = first as? String, let nested = try? JSONSerialization.jsonObject(with: Data(string.utf8)), let object = nested as? [String: Any] {
        return object
    }
    guard let object = first as? [String: Any] else {
        throw ToolError.failed("page: JavaScript returned non-object JSON: \(raw)")
    }
    return object
}
func pageHostType(for app: ResolvedApp, frameworks: [String]? = nil) -> PageHostType { .unsupported }
func selectCDPPageTarget(_ targets: [[String: Any]], targetURLContains: String?, port: Int) throws -> [String: Any]? { nil }
func jsonString(_ value: String) -> String { "\"\(value)\"" }

func openClipboard() {}

func withTimeout<T: Sendable>(
    seconds: Double,
    label: String,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw ToolError.failed("\(label) timed out after \(Int(seconds))s.")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

#endif
