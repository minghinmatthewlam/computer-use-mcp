#if os(Linux)
import Foundation
import Glibc

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

final class AXUIElement: @unchecked Sendable {}

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

func AXUIElementCreateApplication(_ pid: pid_t) -> AXUIElement { AXUIElement() }
func AXUIElementCreateSystemWide() -> AXUIElement { AXUIElement() }
func AXUIElementGetTypeID() -> Int { 0 }
func AXValueGetTypeID() -> Int { 0 }
func AXValueCreate(_ type: AXValueType, _ value: UnsafeRawPointer?) -> AXValue? { nil }
func AXValueGetValue(_ value: AXValue, _ type: AXValueType, _ ptr: UnsafeMutableRawPointer) -> Bool { false }
func AXUIElementSetMessagingTimeout(_ element: AXUIElement, _ timeout: Float) {}
func AXUIElementCopyAttributeValue(
    _ element: AXUIElement, _ attribute: CFString, _ value: UnsafeMutablePointer<CFTypeRef?>
) -> AXError { .attributeUnsupported }
func AXUIElementCopyParameterizedAttributeValue(
    _ element: AXUIElement, _ attribute: CFString, _ parameter: CFTypeRef,
    _ value: UnsafeMutablePointer<CFTypeRef?>
) -> AXError { .attributeUnsupported }
func AXUIElementCopyAttributeNames(
    _ element: AXUIElement, _ names: UnsafeMutablePointer<CFArray?>
) -> AXError { .attributeUnsupported }
func AXUIElementCopyElementAtPosition(
    _ element: AXUIElement, _ x: Float, _ y: Float, _ value: UnsafeMutablePointer<AXUIElement?>
) -> AXError { .attributeUnsupported }
func AXUIElementCopyActionNames(
    _ element: AXUIElement, _ names: UnsafeMutablePointer<CFArray?>
) -> AXError { .attributeUnsupported }
func AXUIElementPerformAction(_ element: AXUIElement, _ action: CFString) -> AXError { .attributeUnsupported }
func AXUIElementSetAttributeValue(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError { .attributeUnsupported }
func AXUIElementIsAttributeSettable(
    _ element: AXUIElement, _ attribute: CFString, _ settable: UnsafeMutablePointer<DarwinBoolean>
) -> AXError { .attributeUnsupported }
func AXIsProcessTrusted() -> Bool { false }
func AXIsProcessTrustedWithOptions(_ options: CFTypeRef) -> Bool { false }
func CFGetTypeID(_ value: CFTypeRef) -> Int { 0 }
func CFEqual(_ lhs: CFTypeRef, _ rhs: CFTypeRef) -> Bool { lhs as AnyObject === rhs as AnyObject }
func CFAttributedStringGetTypeID() -> Int { 0 }
func CFBooleanGetTypeID() -> Int { 0 }
func AXValueGetType(_ value: AXValue) -> Int { 0 }

final class NSRunningApplication: @unchecked Sendable {
    static let current = NSRunningApplication()
    var processIdentifier: pid_t { getpid() }
    var localizedName: String? { nil }
    var bundleIdentifier: String? { nil }
    var bundleURL: URL? { nil }
    var executableURL: URL? { nil }
    var isTerminated: Bool { false }
    var isHidden: Bool { false }
    var isActive: Bool { false }
    enum ActivationPolicy { case prohibited, regular }
    var activationPolicy: ActivationPolicy { .regular }
    init() {}
    init?(processIdentifier: pid_t) {}
}
final class NSWorkspace: @unchecked Sendable {
    static let shared = NSWorkspace()
    var runningApplications: [NSRunningApplication] { [] }
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
func getpeereid(_ fd: Int32, _ euid: UnsafeMutablePointer<uid_t>, _ egid: UnsafeMutablePointer<gid_t>) -> Int32 { -1 }

#endif
