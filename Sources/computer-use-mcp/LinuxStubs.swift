#if os(Linux)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CX11
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
    case globalXTest = "tier4-global-xtest"
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
    case x11GlobalInput = "x11-global-input"
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
    let keyString: String?

    init(keyCode: CGKeyCode, flags: CGEventFlags, keyString: String? = nil) {
        self.keyCode = keyCode
        self.flags = flags
        self.keyString = keyString
    }
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
        return KeyChord(keyCode: code, flags: flags, keyString: key)
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

private final class X11State: @unchecked Sendable {
    static let shared = X11State()
    let lock = NSLock()
}

private func withX11Display<R>(_ body: (CX11DisplayRef) throws -> R) throws -> R {
    guard let display = cx11_open_display() else {
        throw ToolError.failed(
            "X11 input is unavailable because DISPLAY is not set or the X server cannot be opened."
        )
    }
    defer { cx11_close_display(display) }
    return try body(display)
}

private func ensureLinuxX11Focus(pid: pid_t) throws {
    try withX11Display { display in
        let window = cx11_window_for_pid(display, UInt(pid))
        guard window != 0 else {
            throw ToolError.failed(
                "Could not find an X11 window for pid \(pid); refusing to send global keyboard input."
            )
        }
        guard cx11_activate_window(display, window) != 0 else {
            throw ToolError.failed(
                "Could not activate the X11 window for pid \(pid); refusing to send global keyboard input."
            )
        }
        Thread.sleep(forTimeInterval: 0.05)
        guard cx11_focus_matches_pid(display, UInt(pid)) != 0 else {
            throw ToolError.failed(
                "X11 focus did not reach the target app (pid \(pid)); refusing to send global keyboard input."
            )
        }
    }
}

private func linuxX11InputAvailability(displayName: String?) -> InputDeliveryDiagnostic {
    guard let displayName, !displayName.isEmpty else {
        return InputDeliveryDiagnostic(
            status: "unavailable",
            detail: "DISPLAY is not set, so X11/XTest input is unavailable."
        )
    }
    guard let display = cx11_open_display() else {
        return InputDeliveryDiagnostic(
            status: "unavailable",
            detail: "Could not open X11 display \(displayName)."
        )
    }
    defer { cx11_close_display(display) }
    guard cx11_xtest_available(display) != 0 else {
        return InputDeliveryDiagnostic(
            status: "unavailable",
            detail: "XTest is not available on display \(displayName)."
        )
    }
    return InputDeliveryDiagnostic(
        status: "available",
        detail: "X11/XTest input is available on display \(displayName)."
    )
}

func linuxInputDeliveryDiagnostic(displayName: String? = ProcessInfo.processInfo.environment["DISPLAY"]) -> InputDeliveryDiagnostic {
    linuxX11InputAvailability(displayName: displayName)
}

func linuxInputDeliveryAvailable() -> Bool {
    linuxInputDeliveryDiagnostic().status == "available"
}

private func linuxKeyToken(for chord: KeyChord) -> String? {
    if let keyString = chord.keyString, !keyString.isEmpty {
        return keyString
    }
    switch chord.keyCode {
    case CGKeyCode(kVK_Return): return "Return"
    case CGKeyCode(kVK_Tab): return "Tab"
    case CGKeyCode(kVK_Space): return "space"
    case CGKeyCode(kVK_Delete): return "Delete"
    case CGKeyCode(kVK_ForwardDelete): return "ForwardDelete"
    case CGKeyCode(kVK_Escape): return "Escape"
    case CGKeyCode(kVK_LeftArrow): return "Left"
    case CGKeyCode(kVK_RightArrow): return "Right"
    case CGKeyCode(kVK_UpArrow): return "Up"
    case CGKeyCode(kVK_DownArrow): return "Down"
    case CGKeyCode(kVK_Home): return "Home"
    case CGKeyCode(kVK_End): return "End"
    case CGKeyCode(kVK_PageUp): return "PageUp"
    case CGKeyCode(kVK_PageDown): return "PageDown"
    default:
        if chord.keyCode < 128,
            let scalar = UnicodeScalar(UInt32(chord.keyCode)),
            scalar.value >= 32
        {
            return String(scalar)
        }
        return nil
    }
}

private func linuxModifierKeycodes(for flags: CGEventFlags, display: CX11DisplayRef) -> [KeyCode] {
    var codes: [KeyCode] = []
    if flags.contains(.maskShift), let code = linuxKeycode(named: "Shift_L", display: display) {
        codes.append(code)
    }
    if flags.contains(.maskControl), let code = linuxKeycode(named: "Control_L", display: display) {
        codes.append(code)
    }
    if flags.contains(.maskAlternate), let code = linuxKeycode(named: "Alt_L", display: display) {
        codes.append(code)
    }
    if flags.contains(.maskCommand), let code = linuxKeycode(named: "Super_L", display: display) {
        codes.append(code)
    }
    return codes
}

private func linuxKeycode(named name: String, display: CX11DisplayRef) -> KeyCode? {
    let keysym = cx11_keysym_for_name(name)
    guard keysym != 0 else { return nil }
    let keycode = cx11_keycode_for_keysym(display, keysym)
    return keycode == 0 ? nil : keycode
}

private func linuxKeycode(for token: String, display: CX11DisplayRef) -> KeyCode? {
    let keysym = cx11_keysym_for_name(token)
    if keysym != 0 {
        let keycode = cx11_keycode_for_keysym(display, keysym)
        if keycode != 0 { return keycode }
    }
    if token.count == 1, let scalar = token.unicodeScalars.first {
        let codepointKeysym = KeySym(0x0100_0000 | UInt32(scalar.value))
        let keycode = cx11_keycode_for_keysym(display, codepointKeysym)
        if keycode != 0 { return keycode }
    }
    return nil
}

private func linuxSendKeySequence(
    display: CX11DisplayRef,
    keycode: KeyCode,
    modifiers: [KeyCode]
) -> Bool {
    for modifier in modifiers {
        guard cx11_fake_key_event(display, unsignedInt(modifier), 1) != 0 else { return false }
    }
    guard cx11_fake_key_event(display, unsignedInt(keycode), 1) != 0 else { return false }
    guard cx11_fake_key_event(display, unsignedInt(keycode), 0) != 0 else { return false }
    for modifier in modifiers.reversed() {
        guard cx11_fake_key_event(display, unsignedInt(modifier), 0) != 0 else { return false }
    }
    return cx11_flush(display) != 0 && cx11_sync(display) != 0
}

private func linuxSendUnicodeScalar(_ scalar: UnicodeScalar, display: CX11DisplayRef) throws {
    var minKeycode: Int32 = 0
    var maxKeycode: Int32 = 0
    guard cx11_display_keycodes(display, &minKeycode, &maxKeycode) != 0, minKeycode <= maxKeycode else {
        throw ToolError.failed("Could not query the X11 keyboard map for Unicode text delivery.")
    }
    let spareKeycode = maxKeycode
    var keysymsPerKeycode: Int32 = 0
    guard let mapping = cx11_keyboard_mapping(display, spareKeycode, 1, &keysymsPerKeycode),
        keysymsPerKeycode > 0
    else {
        throw ToolError.failed("Could not read the X11 keyboard map for Unicode text delivery.")
    }
    defer { cx11_free(mapping) }

    let saved = Array(UnsafeBufferPointer<KeySym>(start: mapping, count: Int(keysymsPerKeycode)))
    let unicodeKeysym = KeySym(0x0100_0000 | UInt32(scalar.value))
    var replacement = Array(repeating: KeySym(0), count: Int(keysymsPerKeycode))
    replacement[0] = unicodeKeysym
    replacement.withUnsafeBufferPointer { buffer in
        _ = cx11_change_keyboard_mapping(display, spareKeycode, keysymsPerKeycode, buffer.baseAddress, 1)
    }
    guard cx11_sync(display) != 0 else {
        throw ToolError.failed("Could not update the X11 keyboard map for Unicode text delivery.")
    }
    Thread.sleep(forTimeInterval: 0.01)
    defer {
        saved.withUnsafeBufferPointer { buffer in
            _ = cx11_change_keyboard_mapping(display, spareKeycode, keysymsPerKeycode, buffer.baseAddress, 1)
        }
        _ = cx11_sync(display)
        Thread.sleep(forTimeInterval: 0.01)
    }

    guard linuxSendKeySequence(display: display, keycode: KeyCode(spareKeycode), modifiers: []) else {
        throw ToolError.failed("Could not synthesize Unicode text on X11.")
    }
    Thread.sleep(forTimeInterval: 0.02)
}

private func unsignedInt(_ keycode: KeyCode) -> UInt32 {
    UInt32(keycode)
}

@discardableResult
func deliverClick(
    at point: CGPoint, button: MouseButtonKind, clickCount: Int, context: DeliveryContext,
    allowGlobalCursor: Bool = false
) throws -> DeliveryOutcome {
    guard linuxInputDeliveryAvailable() else {
        throw ToolError.failed("Mouse click delivery is unavailable because X11/XTest is unavailable.")
    }
    try withX11Display { display in
        let screen = cx11_default_screen(display)
        let clickButton: UInt32 = switch button {
        case .left: 1
        case .middle: 2
        case .right: 3
        }
        for _ in 0..<max(1, clickCount) {
            guard cx11_fake_motion_event(display, screen, Int32(point.x.rounded()), Int32(point.y.rounded())) != 0 else {
                throw ToolError.failed("Could not move the X11 pointer for click delivery.")
            }
            guard cx11_fake_button_event(display, clickButton, 1) != 0 else {
                throw ToolError.failed("Could not press the X11 mouse button.")
            }
            guard cx11_fake_button_event(display, clickButton, 0) != 0 else {
                throw ToolError.failed("Could not release the X11 mouse button.")
            }
        }
    }
    return DeliveryOutcome(tier: .globalCursor, fallbackReasons: [.x11GlobalInput])
}

@discardableResult
func deliverScroll(at point: CGPoint, deltaX: Int, deltaY: Int, context: DeliveryContext) throws -> InputTier {
    guard linuxInputDeliveryAvailable() else {
        throw ToolError.failed("Scroll delivery is unavailable because X11/XTest is unavailable.")
    }
    try withX11Display { display in
        let screen = cx11_default_screen(display)
        let clicksX = max(1, abs(deltaX) / 120)
        let clicksY = max(1, abs(deltaY) / 120)
        guard cx11_fake_motion_event(display, screen, Int32(point.x.rounded()), Int32(point.y.rounded())) != 0 else {
            throw ToolError.failed("Could not position the X11 pointer for scroll delivery.")
        }
        if deltaY > 0 {
            for _ in 0..<clicksY { guard cx11_fake_button_event(display, 5, 1) != 0, cx11_fake_button_event(display, 5, 0) != 0 else { throw ToolError.failed("Could not synthesize a vertical scroll event.") } }
        } else if deltaY < 0 {
            for _ in 0..<clicksY { guard cx11_fake_button_event(display, 4, 1) != 0, cx11_fake_button_event(display, 4, 0) != 0 else { throw ToolError.failed("Could not synthesize a vertical scroll event.") } }
        }
        if deltaX > 0 {
            for _ in 0..<clicksX { guard cx11_fake_button_event(display, 7, 1) != 0, cx11_fake_button_event(display, 7, 0) != 0 else { throw ToolError.failed("Could not synthesize a horizontal scroll event.") } }
        } else if deltaX < 0 {
            for _ in 0..<clicksX { guard cx11_fake_button_event(display, 6, 1) != 0, cx11_fake_button_event(display, 6, 0) != 0 else { throw ToolError.failed("Could not synthesize a horizontal scroll event.") } }
        }
    }
    return .globalCursor
}

@discardableResult
func deliverDrag(from: CGPoint, to: CGPoint, context: DeliveryContext) async throws -> InputTier {
    guard linuxInputDeliveryAvailable() else {
        throw ToolError.failed("Drag delivery is unavailable because X11/XTest is unavailable.")
    }
    try withX11Display { display in
        let screen = cx11_default_screen(display)
        guard cx11_fake_motion_event(display, screen, Int32(from.x.rounded()), Int32(from.y.rounded())) != 0 else {
            throw ToolError.failed("Could not position the X11 pointer for drag delivery.")
        }
        guard cx11_fake_button_event(display, 1, 1) != 0 else {
            throw ToolError.failed("Could not press the X11 drag button.")
        }
        guard cx11_fake_motion_event(display, screen, Int32(to.x.rounded()), Int32(to.y.rounded())) != 0 else {
            throw ToolError.failed("Could not move the X11 pointer during drag delivery.")
        }
        guard cx11_fake_button_event(display, 1, 0) != 0 else {
            throw ToolError.failed("Could not release the X11 drag button.")
        }
    }
    return .globalCursor
}

@discardableResult
func typeUnicodeText(_ text: String, context: DeliveryContext) throws -> InputTier {
    guard linuxInputDeliveryAvailable() else {
        throw ToolError.failed("Text input is unavailable because X11/XTest is unavailable.")
    }
    try ensureLinuxX11Focus(pid: context.pid)
    X11State.shared.lock.lock()
    defer { X11State.shared.lock.unlock() }
    try withX11Display { display in
        for scalar in text.unicodeScalars {
            try linuxSendUnicodeScalar(scalar, display: display)
        }
    }
    return .globalCursor
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
    guard linuxInputDeliveryAvailable() else {
        throw ToolError.failed("Keyboard input is unavailable because X11/XTest is unavailable.")
    }
    guard let token = linuxKeyToken(for: chord) else {
        throw ToolError.failed("Could not map the requested key to an X11 keysym.")
    }
    try ensureLinuxX11Focus(pid: context.pid)
    try withX11Display { display in
        let modifiers = linuxModifierKeycodes(for: chord.flags, display: display)
        let keycode: KeyCode
        if let mapped = linuxKeycode(for: token, display: display) {
            keycode = mapped
        } else {
            throw ToolError.failed("Could not map \(token) to an X11 keycode.")
        }
        guard linuxSendKeySequence(display: display, keycode: keycode, modifiers: modifiers) else {
            throw ToolError.failed("Could not synthesize keyboard input on X11.")
        }
    }
    return .globalXTest
}

func syntheticFallbackReasons(context: DeliveryContext, allowGlobalCursor: Bool) -> [FallbackReason] {
    [.x11GlobalInput]
}
func windowID(for axWindow: AXUIElement) -> CGWindowID? { nil }
func dragReleasePoint(from: CGPoint, to: CGPoint, aborted: Bool) -> CGPoint { aborted ? from : to }
func unicodeTypingChunks(_ text: String) -> [[UniChar]] {
    text.map { Array(String($0).utf16) }
}

private func linuxExecutable(named name: String) -> String? {
    let candidates = [
        name,
        "/usr/bin/\(name)",
        "/usr/local/bin/\(name)",
        "\(NSHomeDirectory())/.local/bin/\(name)",
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

private func runLinuxProcess(
    executable: String,
    arguments: [String],
    input: Data? = nil
) throws -> (status: Int32, output: Data, error: Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    if let input {
        let pipe = Pipe()
        process.standardInput = pipe
        try process.run()
        pipe.fileHandleForWriting.write(input)
        pipe.fileHandleForWriting.closeFile()
    } else {
        try process.run()
    }
    process.waitUntilExit()
    return (
        process.terminationStatus,
        output.fileHandleForReading.readDataToEndOfFile(),
        error.fileHandleForReading.readDataToEndOfFile()
    )
}

private func launchLinuxProcess(executable: String, arguments: [String], input: Data) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardInput = pipe
    try process.run()
    pipe.fileHandleForWriting.write(input)
    pipe.fileHandleForWriting.closeFile()
}

func openAppImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let identifier = try args.requireString("app")
    let activate = args.bool("activate") ?? false
    let confirmed = SafetyPolicy.confirmed(args)
    if let running = try? resolveApp(identifier) {
        try SafetyPolicy.checkOpenApp(
            identifier: running.name,
            activate: activate,
            isAlreadyRunning: true,
            confirmed: confirmed
        )
        return .text("\(running.name) is already running.")
    }
    try SafetyPolicy.checkOpenApp(
        identifier: identifier,
        activate: activate,
        isAlreadyRunning: false,
        confirmed: confirmed
    )
    let executable: String
    let arguments: [String]
    if let gtkLaunch = linuxExecutable(named: "gtk-launch"),
        !identifier.contains("/"),
        identifier.hasSuffix(".desktop")
    {
        executable = gtkLaunch
        arguments = [identifier]
    } else if let path = linuxExecutable(named: identifier) {
        executable = path
        arguments = []
    } else if FileManager.default.isExecutableFile(atPath: identifier) {
        executable = identifier
        arguments = []
    } else {
        throw ToolError.failed(
            "No executable named \"\(identifier)\" was found on Linux. Pass a binary name or executable path."
        )
    }
    do {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
        if process.environment?["GTK_MODULES"] == nil {
            process.environment?["GTK_MODULES"] = "atk-bridge"
        }
        try process.run()
        try? await Task.sleep(for: .milliseconds(300))
        guard process.isRunning else {
            throw ToolError.failed("\(identifier) exited immediately after launch.")
        }
        return .text("Launched \(identifier) (pid \(process.processIdentifier)).")
    } catch {
        throw ToolError.failed("Launching \(identifier) failed: \(error.localizedDescription).")
    }
}
func openURLImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let raw = try args.requireString("url")
    try requireFocusChangeAllowed(
        args,
        reason: "Opening a URL or file path can launch or activate its default handler."
    )
    let url: URL
    if let parsed = URL(string: raw), parsed.scheme != nil {
        url = parsed
    } else if FileManager.default.fileExists(atPath: (raw as NSString).expandingTildeInPath) {
        url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    } else {
        throw ToolError.invalidArguments("\"\(raw)\" is not a valid URL.")
    }
    try SafetyPolicy.checkOpenURL(url, confirmed: SafetyPolicy.confirmed(args))
    guard let opener = linuxExecutable(named: "xdg-open") else {
        throw ToolError.failed("URL opening requires xdg-open on Linux.")
    }
    do {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: opener)
        process.arguments = [raw]
        process.environment = ProcessInfo.processInfo.environment
        try process.run()
        return .text("Opened \(raw) with xdg-open.")
    } catch {
        throw ToolError.failed("Opening \(raw) failed: \(error.localizedDescription).")
    }
}
func listWindowsImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    try requireAppAlive(app)
    let windows = axElements(app.axApplication, kAXWindowsAttribute)
    guard !windows.isEmpty else {
        return .text("\(app.name) has no windows right now.")
    }
    var lines = ["Windows of \(app.name) (pid \(app.pid)):"]
    for window in windows where axRole(window) == "AXWindow" {
        var parts = ["\"\(axString(window, kAXTitleAttribute) ?? "")\""]
        if let frame = axFrame(window) {
            parts.append("(\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height)) pt)")
        }
        if axBool(window, kAXFocusedAttribute) == true { parts.append("focused") }
        lines.append("  " + parts.joined(separator: " "))
    }
    return .text(lines.joined(separator: "\n"))
}
func manageWindowImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.failed("Window management is unsupported on Linux.")
}
func clickMenuItemImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.failed("Menu interaction is unsupported on Linux.")
}
private func linuxClipboardCommand() -> (String, [String], [String])? {
    if let xclip = linuxExecutable(named: "xclip") {
        return (
            xclip,
            ["-selection", "clipboard", "-o"],
            ["-selection", "clipboard", "-in"]
        )
    }
    if let xsel = linuxExecutable(named: "xsel") {
        return (
            xsel,
            ["--clipboard", "--output"],
            ["--clipboard", "--input"]
        )
    }
    return nil
}
func readClipboardImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    guard let (command, readArguments, _) = linuxClipboardCommand() else {
        throw ToolError.failed("Clipboard access requires xclip or xsel on Linux.")
    }
    let result = try runLinuxProcess(executable: command, arguments: readArguments)
    guard result.status == 0 else {
        let detail = String(data: result.error, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        throw ToolError.failed("Could not read the X11 clipboard\(detail.map { ": \($0)" } ?? "").")
    }
    let text = String(data: result.output, encoding: .utf8) ?? ""
    return .text("Clipboard text (\(text.count) chars):\n\(text)")
}
func writeClipboardImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let text = try args.requireString("text")
    try ArgumentBounds.checkStringLength(text, argument: "text", maximum: ArgumentBounds.maxClipboardCharacters)
    try SafetyPolicy.checkClipboardWrite(confirmed: SafetyPolicy.confirmed(args))
    guard let (command, _, writeArguments) = linuxClipboardCommand() else {
        throw ToolError.failed("Clipboard access requires xclip or xsel on Linux.")
    }
    let previous = try? runLinuxProcess(
        executable: command,
        arguments: linuxClipboardCommand()!.1
    )
    let previousText: String?
    if let previous, previous.status == 0 {
        previousText = String(data: previous.output, encoding: .utf8)
    } else {
        previousText = nil
    }
    do {
        try launchLinuxProcess(
            executable: command,
            arguments: writeArguments,
            input: Data(text.utf8)
        )
    } catch {
        throw ToolError.failed("Could not write the X11 clipboard: \(error.localizedDescription).")
    }
    try? await Task.sleep(for: .milliseconds(80))
    let verification = try? runLinuxProcess(
        executable: command,
        arguments: linuxClipboardCommand()!.1
    )
    guard let verification, verification.status == 0,
        String(data: verification.output, encoding: .utf8) == text
    else {
        if let previousText {
            try? launchLinuxProcess(
                executable: command,
                arguments: writeArguments,
                input: Data(previousText.utf8)
            )
        }
        throw ToolError.failed("The X11 clipboard did not accept the requested write.")
    }
    return .text("Replaced the clipboard with \(text.count) characters.")
}
func clipboardRestoreValue(committed: Bool, previous: String?) -> String? { committed ? nil : previous }
func waitForImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    let label = args.string("label")
    let role = args.string("role")
    let valueContains = args.string("value_contains")
    guard label != nil || role != nil || valueContains != nil else {
        throw ToolError.invalidArguments("Provide at least one of label, role, or value_contains.")
    }
    let waitForGone = args.bool("gone") ?? false
    let timeout = min(60.0, max(1.0, args.number("timeout_seconds") ?? 10))
    let start = Date()
    let deadline = start.addingTimeInterval(timeout)
    var conditionMet = false
    repeat {
        let window = try? targetWindow(for: app, title: args.string("window_title"))
        let found = window.map {
            linuxElementExists(
                in: $0.element,
                role: role,
                label: label,
                valueContains: valueContains
            )
        } ?? false
        if found != waitForGone {
            conditionMet = true
            break
        }
        try? await Task.sleep(for: .milliseconds(400))
    } while Date() < deadline
    let what = [
        role.map { "role \($0)" },
        label.map { "label \"\($0)\"" },
        valueContains.map { "value containing \"\($0)\"" },
    ].compactMap { $0 }.joined(separator: ", ")
    let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
    let note = conditionMet
        ? "Condition met after \(elapsed)s: \(what)\(waitForGone ? " is gone" : " appeared")."
        : "TIMED OUT after \(Int(timeout))s waiting for \(what)\(waitForGone ? " to disappear" : ""). Current state below."
    return try await stateResult(
        app: app,
        windowTitle: args.string("window_title"),
        note: note,
        screenshot: screenshotDetail(args)
    )
}

private func linuxElementExists(
    in root: AXUIElement,
    role: String?,
    label: String?,
    valueContains: String?,
    depth: Int = 0
) -> Bool {
    if depth <= 14 {
        let matchesRole = role.map { axRole(root).lowercased() == $0.lowercased() } ?? true
        let query = label?.lowercased()
        let title = axString(root, kAXTitleAttribute)?.lowercased()
        let description = axString(root, kAXDescriptionAttribute)?.lowercased()
        let value = axString(root, kAXValueAttribute)?.lowercased()
        let matchesLabel = query.map {
            (title?.contains($0) ?? false) || (description?.contains($0) ?? false)
        } ?? true
        let matchesValue = valueContains.map { value?.contains($0.lowercased()) ?? false } ?? true
        if matchesRole && matchesLabel && matchesValue { return true }
    }
    return axElements(root, kAXChildrenAttribute).contains {
        linuxElementExists(
            in: $0,
            role: role,
            label: label,
            valueContains: valueContains,
            depth: depth + 1
        )
    }
}
func typeTextImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    let text = try args.requireString("text")
    try ArgumentBounds.checkStringLength(text, argument: "text", maximum: ArgumentBounds.maxTypeTextCharacters)
    let confirmed = SafetyPolicy.confirmed(args)
    try SafetyPolicy.check(app: app, confirmed: confirmed)

    let element: AXUIElement
    let described: String
    if let elementID = args.string("element_id") {
        let target = try await resolveTarget(app: app, elementID: elementID)
        element = target.element
        described = describeTarget(target)
    } else {
        guard let focused = axElement(app.axApplication, kAXFocusedUIElementAttribute) else {
            throw ToolError.failed(
                "\(app.name) has no focused element. Pass element_id for the field to type into."
            )
        }
        element = focused
        described = "the focused element (\(axRole(focused)))"
    }

    try SafetyPolicy.checkTyping(into: element, app: app, confirmed: confirmed)
    let context = DeliveryContext(
        pid: app.pid,
        windowNumber: nil,
        windowFrame: nil,
        allowGlobalCursor: false
    )
    if let frame = axFrame(element) {
        _ = try deliverClick(
            at: CGPoint(x: frame.midX, y: frame.midY),
            button: .left,
            clickCount: 1,
            context: context
        )
    }
    let tier = try typeUnicodeText(text, context: context)
    return .text("Typed \(text.count) characters into \(described) [\(tier.rawValue)].")
}
func setValueImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.failed("Value editing is unsupported on Linux.")
}
func selectTextImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.failed("Text selection is unsupported on Linux.")
}
func readTextImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    let app = try resolveApp(args.requireString("app"))
    try requireAccessibilityTrusted()
    let target = try await resolveTarget(app: app, elementID: args.requireString("element_id"))
    guard let value = axString(target.element, kAXValueAttribute) else {
        throw ToolError.failed("\(describeTarget(target)) has no readable text value.")
    }
    return .text("Text of \(describeTarget(target)) — \(value.count) chars total:\n\(value)")
}
func performSecondaryActionImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.failed("Secondary actions are unsupported on Linux.")
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
        throw ToolError.failed("Page JavaScript execution is unsupported on Linux.")
    }
    func insertText(_ text: String, selector: String, app: ResolvedApp, window: TargetWindow, cdpPort: Int?, targetURLContains: String?) async throws {}
}

func pageImpl(_ args: [String: Value]) async throws -> CallTool.Result {
    throw ToolError.failed("Page interaction is unsupported on Linux.")
}
func pageProbe(selector: String, app: ResolvedApp, window: TargetWindow, cdpPort: Int?, targetURLContains: String?) async throws -> PageProbe {
    throw ToolError.failed("Page interaction is unsupported on Linux.")
}
func pageDOMSnapshot(selector: String, app: ResolvedApp, window: TargetWindow, cdpPort: Int?, targetURLContains: String?) async throws -> PageDOMSnapshot {
    throw ToolError.failed("Page interaction is unsupported on Linux.")
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

private actor LinuxTimeoutGate<T: Sendable> {
    private var finished = false
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<T, Error>) {
        guard !finished, let continuation else { return }
        finished = true
        self.continuation = nil
        continuation.resume(with: result)
    }
}

func withTimeout<T: Sendable>(
    seconds: Double,
    label: String,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let gate = LinuxTimeoutGate(continuation)
        Task.detached {
            do {
                await gate.finish(.success(try await operation()))
            } catch {
                await gate.finish(.failure(error))
            }
        }
        Task.detached {
            try? await Task.sleep(for: .seconds(seconds))
            await gate.finish(.failure(ToolError.failed("\(label) timed out after \(Int(seconds))s.")))
        }
    }
}

#endif
