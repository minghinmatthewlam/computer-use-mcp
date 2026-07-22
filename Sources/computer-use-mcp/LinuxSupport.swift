#if os(Linux)
import Foundation
import Glibc
import CAtSpi

struct LinuxPeerCredentials {
    var pid: pid_t = 0
    var uid: uid_t = 0
    var gid: gid_t = 0
}

typealias CFTypeRef = Any
typealias CFDictionary = [AnyHashable: Any]
typealias CFMachPort = OpaquePointer
typealias CFRunLoopSource = OpaquePointer
typealias CFRunLoop = OpaquePointer
typealias CGDirectDisplayID = UInt32
typealias CGImage = AnyObject
typealias CFString = String
typealias CFArray = [Any]
typealias CFData = Data
typealias CFBoolean = Bool
typealias AXValue = AnyObject
typealias AXUIElementRef = AXUIElement
typealias CGWindowID = UInt32
typealias CGKeyCode = UInt16
typealias UniChar = UInt16
struct DarwinBoolean {
    var boolValue: Bool
    init(_ value: Bool) { boolValue = value }
}
typealias CFTimeInterval = Double
typealias IOPMAssertionID = UInt32
enum CGError: Int32 { case success = 0 }
typealias IOPMAssertionLevel = UInt32
let kIOPMAssertionLevelOn: UInt32 = 255
let kIOPMAssertionTypePreventUserIdleSystemSleep = "PreventUserIdleSystemSleep"
let kIOReturnSuccess: Int32 = 0
func IOPMAssertionCreateWithName(_ type: CFString, _ level: IOPMAssertionLevel, _ name: CFString, _ id: UnsafeMutablePointer<IOPMAssertionID>) -> Int32 { 0 }
func IOPMAssertionRelease(_ id: IOPMAssertionID) -> Int32 { 0 }
func CGSessionCopyCurrentDictionary() -> CFDictionary? { [:] }

struct CFRange {
    init() { location = 0; length = 0 }
    var location: Int
    var length: Int
}

final class LinuxAXValue: @unchecked Sendable {
    enum Kind {
        case range(CFRange)
        case point(CGPoint)
        case size(CGSize)
    }

    let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }
}

final class AXUIElement: @unchecked Sendable {
    let native: UnsafeMutablePointer<AtspiAccessible>?

    init(native: UnsafeMutablePointer<AtspiAccessible>?) {
        self.native = native
    }

    deinit {
        if let native {
            catspi_unref(native)
        }
    }
}

enum AXError: Int32 {
    case success = 0
    case attributeUnsupported = -25205
    case actionUnsupported = -25206
    case apiDisabled = -25207
    case cannotComplete = -25208
    case invalidUIElement = -25209
    case noValue = -25210
    case notImplemented = -25211
}
enum AXValueType { case cfRange, cgPoint, cgSize }

let kAXChildrenAttribute = "AXChildren"
let kAXDescriptionAttribute = "AXDescription"
let kAXHelpAttribute = "AXHelp"
let kAXParentAttribute = "AXParent"
let kAXPositionAttribute = "AXPosition"
let kAXRoleAttribute = "AXRole"
let kAXSizeAttribute = "AXSize"
let kAXTitleAttribute = "AXTitle"
let kAXTitleUIElementAttribute = "AXTitleUIElement"
let kAXValueAttribute = "AXValue"
let kAXVisibleCharacterRangeAttribute = "AXVisibleCharacterRange"
let kAXSubroleAttribute = "AXSubrole"
let kAXFocusedAttribute = "AXFocused"
let kAXFocusedWindowAttribute = "AXFocusedWindow"
let kAXMainWindowAttribute = "AXMainWindow"
let kAXWindowsAttribute = "AXWindows"
let kAXEnabledAttribute = "AXEnabled"
let kAXSelectedAttribute = "AXSelected"
let kAXSelectedTextAttribute = "AXSelectedText"
let kAXRoleDescriptionAttribute = "AXRoleDescription"
let kAXURLAttribute = "AXURL"
let kAXWindowAttribute = "AXWindow"
let kAXFocusedUIElementAttribute = "AXFocusedUIElement"
let kAXSelectedTextRangeAttribute = "AXSelectedTextRange"
let kAXCloseButtonAttribute = "AXCloseButton"
let kAXMainAttribute = "AXMain"
let kAXMenuBarAttribute = "AXMenuBar"
let kAXMinimizedAttribute = "AXMinimized"
let kAXRaiseAction = "AXRaise"
let kCFBooleanFalse = false
let kAXSecureTextFieldSubrole = "AXSecureTextField"
let kAXPressAction = "AXPress"
let kAXAttributedStringForRangeParameterizedAttribute = "AXAttributedStringForRange"
let kAXStringForRangeParameterizedAttribute = "AXStringForRange"
let kCFBooleanTrue = true

private let linuxAXElementTypeID = 0x415845
private let linuxAXValueTypeID = 0x415856
private let linuxBooleanTypeID = 0x415842
private let linuxAttributedStringTypeID = 0x415841

private final class AtSpiState: @unchecked Sendable {
    static let shared = AtSpiState()
    let lock = NSLock()
    var initialized = false
}

@discardableResult
private func ensureAtSpiInitialized() -> Bool {
    let state = AtSpiState.shared
    state.lock.lock()
    defer { state.lock.unlock() }
    if state.initialized { return true }
    guard catspi_init() == 0 else { return false }
    state.initialized = true
    return true
}

func linuxAccessibilityAvailable() -> Bool {
    guard ensureAtSpiInitialized(), let desktop = catspi_desktop() else { return false }
    catspi_unref(desktop)
    return true
}

func AXUIElementCreateApplication(_ pid: pid_t) -> AXUIElement {
    guard ensureAtSpiInitialized() else { return AXUIElement(native: nil) }
    return AXUIElement(native: catspi_application_for_pid(UInt32(pid)))
}
func AXUIElementCreateSystemWide() -> AXUIElement {
    guard ensureAtSpiInitialized() else { return AXUIElement(native: nil) }
    return AXUIElement(native: catspi_desktop())
}
func AXUIElementGetTypeID() -> Int { linuxAXElementTypeID }
func AXValueGetTypeID() -> Int { linuxAXValueTypeID }
func AXValueCreate(_ type: AXValueType, _ value: UnsafeRawPointer?) -> AXValue? {
    guard let value else { return nil }
    switch type {
    case .cfRange:
        return LinuxAXValue(.range(value.assumingMemoryBound(to: CFRange.self).pointee))
    case .cgPoint:
        return LinuxAXValue(.point(value.assumingMemoryBound(to: CGPoint.self).pointee))
    case .cgSize:
        return LinuxAXValue(.size(value.assumingMemoryBound(to: CGSize.self).pointee))
    }
}
func AXValueGetValue(_ value: AXValue, _ type: AXValueType, _ ptr: UnsafeMutableRawPointer) -> Bool {
    guard let value = value as? LinuxAXValue else { return false }
    switch (value.kind, type) {
    case let (.range(range), .cfRange):
        ptr.assumingMemoryBound(to: CFRange.self).pointee = range
    case let (.point(point), .cgPoint):
        ptr.assumingMemoryBound(to: CGPoint.self).pointee = point
    case let (.size(size), .cgSize):
        ptr.assumingMemoryBound(to: CGSize.self).pointee = size
    default:
        return false
    }
    return true
}
func AXUIElementSetMessagingTimeout(_ element: AXUIElement, _ timeout: Float) {}

private func atspiRoleName(_ raw: String?) -> String {
    switch raw?.lowercased() {
    case "application": return "AXApplication"
    case "frame", "window": return "AXWindow"
    case "push button", "button": return "AXButton"
    case "toggle button", "check box": return "AXCheckBox"
    case "radio button": return "AXRadioButton"
    case "combo box": return "AXComboBox"
    case "entry", "text", "password text": return "AXTextField"
    case "text area", "document text": return "AXTextArea"
    case "label", "static": return "AXStaticText"
    case "menu": return "AXMenu"
    case "menu item": return "AXMenuItem"
    case "scroll pane", "scroll bar": return "AXScrollArea"
    case "table": return "AXTable"
    case "list": return "AXList"
    case "list item": return "AXRow"
    case "tree": return "AXOutline"
    case "tree item": return "AXRow"
    case "tool bar": return "AXToolbar"
    case "page tab list": return "AXTabGroup"
    case "page tab": return "AXRadioButton"
    case "dialog": return "AXDialog"
    case "image": return "AXImage"
    case "link": return "AXLink"
    case "separator": return "AXSplitter"
    case "panel", "filler", "section", "group": return "AXGroup"
    default:
        guard let raw, !raw.isEmpty else { return "AXUnknown" }
        return "AX\(raw.split(separator: " ").map { $0.capitalized }.joined())"
    }
}

private func atspiString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    let value = String(cString: pointer)
    catspi_free_string(pointer)
    return value
}

func AXUIElementCopyAttributeValue(
    _ element: AXUIElement, _ attribute: CFString, _ value: UnsafeMutablePointer<CFTypeRef?>
) -> AXError {
    guard let native = element.native else { return .invalidUIElement }
    switch attribute {
    case kAXRoleAttribute:
        value.pointee = atspiRoleName(atspiString(catspi_role_name(native)))
    case kAXRoleDescriptionAttribute:
        value.pointee = atspiString(catspi_role_name(native))
    case kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute:
        let pointer: UnsafeMutablePointer<CChar>?
        if attribute == kAXDescriptionAttribute {
            pointer = catspi_description(native)
        } else if attribute == kAXValueAttribute {
            pointer = catspi_text(native) ?? catspi_name(native)
        } else {
            pointer = catspi_name(native)
        }
        value.pointee = atspiString(pointer)
    case kAXChildrenAttribute, kAXWindowsAttribute:
        let count = catspi_child_count(native)
        var children: [Any] = []
        for index in 0..<count {
            guard let child = catspi_child_at_index(native, index) else { continue }
            let wrapped = AXUIElement(native: child)
            if attribute == kAXWindowsAttribute, axRole(wrapped) != "AXWindow" {
                continue
            }
            children.append(wrapped)
        }
        value.pointee = children
    case kAXParentAttribute:
        if let parent = catspi_parent(native) {
            value.pointee = AXUIElement(native: parent)
        }
    case kAXPositionAttribute:
        var rect = CAtSpiRect()
        guard catspi_extents(native, &rect) != 0 else { return .noValue }
        value.pointee = LinuxAXValue(.point(CGPoint(x: CGFloat(rect.x), y: CGFloat(rect.y))))
    case kAXSizeAttribute:
        var rect = CAtSpiRect()
        guard catspi_extents(native, &rect) != 0 else { return .noValue }
        value.pointee = LinuxAXValue(.size(CGSize(width: CGFloat(rect.width), height: CGFloat(rect.height))))
    case kAXEnabledAttribute:
        value.pointee = Bool(catspi_state(native, 8) != 0)
    case kAXFocusedAttribute:
        value.pointee = Bool(catspi_state(native, 12) != 0)
    case kAXSelectedAttribute:
        value.pointee = Bool(catspi_state(native, 23) != 0)
    case kAXFocusedWindowAttribute:
        let count = catspi_child_count(native)
        for index in 0..<count {
            guard let child = catspi_child_at_index(native, index) else { continue }
            let wrapped = AXUIElement(native: child)
            if axRole(wrapped) == "AXWindow", catspi_state(child, 12) != 0 {
                value.pointee = wrapped
                break
            }
        }
    default:
        return .attributeUnsupported
    }
    return value.pointee == nil ? .noValue : .success
}
func AXUIElementCopyParameterizedAttributeValue(
    _ element: AXUIElement, _ attribute: CFString, _ parameter: CFTypeRef,
    _ value: UnsafeMutablePointer<CFTypeRef?>
) -> AXError { .attributeUnsupported }
func AXUIElementCopyAttributeNames(
    _ element: AXUIElement, _ names: UnsafeMutablePointer<CFArray?>
) -> AXError {
    names.pointee = [
        kAXRoleAttribute, kAXRoleDescriptionAttribute, kAXTitleAttribute,
        kAXDescriptionAttribute, kAXValueAttribute, kAXChildrenAttribute,
        kAXParentAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXEnabledAttribute, kAXFocusedAttribute, kAXSelectedAttribute,
    ]
    return .success
}
func AXUIElementCopyElementAtPosition(
    _ element: AXUIElement, _ x: Float, _ y: Float, _ value: UnsafeMutablePointer<AXUIElement?>
) -> AXError { .attributeUnsupported }
func AXUIElementCopyActionNames(
    _ element: AXUIElement, _ names: UnsafeMutablePointer<CFArray?>
) -> AXError {
    let count = catspi_action_count(element.native)
    var result: [Any] = []
    for index in 0..<count {
        guard let name = catspi_action_name(element.native, index) else { continue }
        result.append(String(cString: name))
        catspi_free_string(name)
    }
    names.pointee = result
    return .success
}
func AXUIElementPerformAction(_ element: AXUIElement, _ action: CFString) -> AXError {
    let count = catspi_action_count(element.native)
    for index in 0..<count {
        guard let name = catspi_action_name(element.native, index) else { continue }
        let matches = String(cString: name).lowercased() == action.lowercased()
            || (action == kAXPressAction && String(cString: name).lowercased() == "click")
            || (action == kAXPressAction && String(cString: name).lowercased() == "activate")
        catspi_free_string(name)
        if matches {
            return catspi_do_action(element.native, index) != 0 ? .success : .cannotComplete
        }
    }
    return .actionUnsupported
}
func AXUIElementSetAttributeValue(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError { .attributeUnsupported }
func AXUIElementIsAttributeSettable(
    _ element: AXUIElement, _ attribute: CFString, _ settable: UnsafeMutablePointer<DarwinBoolean>
) -> AXError { .attributeUnsupported }
func AXIsProcessTrusted() -> Bool { ensureAtSpiInitialized() }
func AXIsProcessTrustedWithOptions(_ options: CFTypeRef) -> Bool { false }
func CFGetTypeID(_ value: CFTypeRef) -> Int {
    if value is AXUIElement { return linuxAXElementTypeID }
    if value is LinuxAXValue { return linuxAXValueTypeID }
    if value is Bool { return linuxBooleanTypeID }
    if value is NSAttributedString { return linuxAttributedStringTypeID }
    return 0
}
func CFEqual(_ lhs: CFTypeRef, _ rhs: CFTypeRef) -> Bool { lhs as AnyObject === rhs as AnyObject }
func CFAttributedStringGetTypeID() -> Int { linuxAttributedStringTypeID }
func CFBooleanGetTypeID() -> Int { linuxBooleanTypeID }
func AXValueGetType(_ value: AXValue) -> Int { 0 }

private func linuxProcessName(_ pid: pid_t) -> String? {
    try? String(contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

final class NSRunningApplication: @unchecked Sendable {
    static let current = NSRunningApplication()
    let processIdentifier: pid_t
    let localizedName: String?
    let bundleIdentifier: String?
    let nativeApplication: AXUIElement?
    var bundleURL: URL? { nil }
    var executableURL: URL? { nil }
    var isTerminated: Bool { false }
    var isHidden: Bool { false }
    var isActive: Bool { false }
    enum ActivationPolicy { case prohibited, regular }
    var activationPolicy: ActivationPolicy { .regular }
    init() {
        processIdentifier = getpid()
        localizedName = linuxProcessName(processIdentifier) ?? "computer-use-mcp"
        bundleIdentifier = localizedName
        nativeApplication = nil
    }
    init?(processIdentifier: pid_t) {
        guard ensureAtSpiInitialized(), let native = catspi_application_for_pid(UInt32(processIdentifier))
        else { return nil }
        self.processIdentifier = processIdentifier
        self.nativeApplication = AXUIElement(native: native)
        self.localizedName = atspiString(catspi_name(native)) ?? linuxProcessName(processIdentifier)
        self.bundleIdentifier = self.localizedName
    }
}
final class NSWorkspace: @unchecked Sendable {
    static let shared = NSWorkspace()
    var runningApplications: [NSRunningApplication] {
        guard ensureAtSpiInitialized(), let desktop = catspi_desktop() else { return [] }
        defer { catspi_unref(desktop) }
        return (0..<catspi_child_count(desktop)).compactMap { index in
            guard let child = catspi_child_at_index(desktop, index) else { return nil }
            let pid = pid_t(catspi_process_id(child))
            catspi_unref(child)
            return NSRunningApplication(processIdentifier: pid)
        }
    }
    var frontmostApplication: NSRunningApplication? { nil }
}

final class NSPasteboard: @unchecked Sendable {
    static let general = NSPasteboard()
    func clearContents() {}
    func setString(_ string: String, forType type: String) -> Bool { false }
    func string(forType type: String) -> String? { nil }
}

struct CGEventFlags: OptionSet, Sendable {
    let rawValue: UInt64
    init(rawValue: UInt64) { self.rawValue = rawValue }
    static let maskShift = Self(rawValue: 1 << 17)
    static let maskControl = Self(rawValue: 1 << 18)
    static let maskAlternate = Self(rawValue: 1 << 19)
    static let maskCommand = Self(rawValue: 1 << 20)
    static let maskSecondaryFn = Self(rawValue: 1 << 23)
}

enum CGEventType: Int32, Sendable {
    case leftMouseDown, leftMouseUp, rightMouseDown, rightMouseUp, mouseMoved
    case leftMouseDragged, rightMouseDragged, otherMouseDown, otherMouseUp, keyDown, keyUp, scrollWheel
}

enum CGMouseButton: Int32, Sendable { case left, right, center }
enum CGEventTapLocation: Int32 { case cghidEventTap, cgSessionEventTap }
enum CGEventTapPlacement: Int32 { case headInsertEventTap }
enum CGEventTapOptions: Int32 { case listenOnly }
enum CGEventField: Int32 {
    case mouseEventClickState = 1
    case mouseEventWindowUnderMousePointer = 2
    case mouseEventWindowUnderMousePointerThatCanHandleThisEvent = 3
    case scrollWheelEventScrollCount = 4
    case scrollWheelEventFixedPtDeltaAxis1 = 5
    case scrollWheelEventFixedPtDeltaAxis2 = 6
    case scrollWheelEventPointDeltaAxis1 = 7
    case scrollWheelEventPointDeltaAxis2 = 8
    case scrollWheelEventIsContinuous = 9
    case scrollWheelEventScrollPhase = 10
    case scrollWheelEventMomentumPhase = 11
}
struct CGScrollPhase: OptionSet, Sendable {
    let rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }
}
typealias CGMomentumScrollPhase = CGScrollPhase
final class CGEvent: @unchecked Sendable {
    var location: CGPoint = .zero
    var flags: CGEventFlags = []
    init?(mouseEventSource: CGEventSource?, mouseType: CGEventType, mouseCursorPosition: CGPoint, mouseButton: CGMouseButton) {
        location = mouseCursorPosition
    }
    init?(keyboardEventSource: CGEventSource?, virtualKey: CGKeyCode, keyDown: Bool) {}
    init?(source: CGEventSource?) {}
    func setIntegerValueField(_ field: CGEventField, value: Int64) {}
    func setFlags(_ flags: CGEventFlags) {}
    func keyboardSetUnicodeString(stringLength: Int, unicodeString: UnsafePointer<UniChar>) {}
    func keyboardSetUnicodeString(stringLength: Int, unicodeString: UnsafePointer<UniChar>?) {}
    func getIntegerValueField(_ field: CGEventField) -> Int64 { 0 }
    func getDoubleValueField(_ field: CGEventField) -> Double { 0 }
    func keyboardGetUnicodeString(maxStringLength: Int, actualStringLength: inout Int, unicodeString: inout [UniChar]) {}
    func post(tap: CGEventTapLocation) {}
    static func tapCreate(
        tap: CGEventTapLocation, place: CGEventTapPlacement, options: CGEventTapOptions,
        eventsOfInterest: UInt64, callback: Any, userInfo: UnsafeMutableRawPointer?
    ) -> OpaquePointer? { nil }
    static func tapEnable(tap: OpaquePointer, enable: Bool) {}
    static func sourceCounterForEventType(_ stateID: Int32, eventType: CGEventType) -> UInt64 { 0 }
}
final class CGEventSource: @unchecked Sendable {
    enum StateID { case privateState, combinedSessionState, hidSystemState }
    init?(stateID: StateID) {}
    static func secondsSinceLastEventType(_ stateID: StateID, eventType: CGEventType) -> TimeInterval { .infinity }
}

struct NSEvent {
    enum EventType { case leftMouseDown, leftMouseUp, rightMouseDown, rightMouseUp, mouseMoved, leftMouseDragged, rightMouseDragged, keyDown, keyUp, scrollWheel }
    struct ModifierFlags: OptionSet { let rawValue: UInt; init(rawValue: UInt) { self.rawValue = rawValue } }
    static func mouseEvent(
        with type: EventType, location: CGPoint, modifierFlags: ModifierFlags, timestamp: TimeInterval,
        windowNumber: Int, context: Any?, eventNumber: Int, clickCount: Int, pressure: Float
    ) -> NSEvent? { nil }
    func cgEvent() -> CGEvent? { nil }
}

func CGMainDisplayID() -> UInt32 { 0 }
func CGWindowListCopyWindowInfo(_ option: [CGWindowListOption], _ relativeToWindow: CGWindowID) -> CFArray? { nil }
let kCGNullWindowID: CGWindowID = 0
let kCGWindowLayer = "kCGWindowLayer"
let kCGWindowOwnerPID = "kCGWindowOwnerPID"
let kCGWindowOwnerName = "kCGWindowOwnerName"
let kCGWindowBounds = "kCGWindowBounds"
struct CGWindowListOption: OptionSet {
    let rawValue: UInt
    init(rawValue: UInt) { self.rawValue = rawValue }
    static let optionOnScreenOnly = Self(rawValue: 1 << 0)
    static let optionIncludingWindow = Self(rawValue: 1 << 1)
}
func CGDisplayBounds(_ display: CGDirectDisplayID) -> CGRect { .zero }
func CGGetActiveDisplayList(_ maxDisplays: UInt32, _ activeDisplays: UnsafeMutablePointer<CGDirectDisplayID>?, _ displayCount: UnsafeMutablePointer<UInt32>) -> CGError { displayCount.pointee = 0; return .success }
struct CGDisplayMode { let pixelWidth: Int }
func CGDisplayCopyDisplayMode(_ display: CGDirectDisplayID) -> CGDisplayMode? { nil }
func CGWarpMouseCursorPosition(_ point: CGPoint) {}
func IsSecureEventInputEnabled() -> Bool { false }
let kVK_Delete = 51
let kVK_ForwardDelete = 117
let kVK_ANSI_KeypadEnter = 76
let kVK_Return = 36
let kVK_Tab = 48
let kVK_Space = 49
let kVK_Escape = 53
let kVK_LeftArrow = 123
let kVK_RightArrow = 124
let kVK_DownArrow = 125
let kVK_UpArrow = 126
let kVK_Home = 115
let kVK_End = 119
let kVK_PageUp = 116
let kVK_PageDown = 121
let kVK_F1 = 122
let kVK_F2 = 120
let kVK_F3 = 99
let kVK_F4 = 118
let kVK_F5 = 96
let kVK_F6 = 97
let kVK_F7 = 98
let kVK_F8 = 100
let kVK_F9 = 101
let kVK_F10 = 109
let kVK_F11 = 103
let kVK_F12 = 111
func proc_listallpids(_ buffer: UnsafeMutableRawPointer, _ size: Int32) -> Int32 { 0 }
#endif
