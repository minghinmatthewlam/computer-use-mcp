import Foundation
#if os(macOS)
import CoreGraphics
import Darwin
#endif

private let skyLightFrameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

enum SkyLightEventKind: Equatable {
    case mouseMoved
    case mouseDown
    case mouseUp
    case keyDown
    case keyUp
}

struct SkyLightIntegerField: Equatable {
    let field: Int
    let value: Int64
}

struct SkyLightEventSpec: Equatable {
    let kind: SkyLightEventKind
    let point: CGPoint?
    let button: MouseButtonKind?
    let keyCode: CGKeyCode?
    let unicode: [UniChar]
    let flags: CGEventFlags
    let attachAuthMessage: Bool
    let integerFields: [SkyLightIntegerField]
    let windowLocation: CGPoint?
    let delayAfterMilliseconds: UInt64
}

func skyLightEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    environment["COMPUTER_USE_MCP_SKYLIGHT"] == "1"
}

func skyLightClickGroupID() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000_000_000) & 0x7fff_ffff
}

func skyLightWindowLocalPoint(point: CGPoint, windowFrame: CGRect) -> CGPoint {
    CGPoint(x: point.x - windowFrame.origin.x, y: windowFrame.maxY - point.y)
}

func skyLightMouseRecipe(
    pid: pid_t,
    point: CGPoint,
    button: MouseButtonKind,
    clickCount: Int,
    windowNumber: CGWindowID?,
    windowFrame: CGRect?,
    clickGroupID: Int64 = skyLightClickGroupID()
) -> [SkyLightEventSpec] {
    let count = max(1, clickCount)
    let local = windowFrame.map { skyLightWindowLocalPoint(point: point, windowFrame: $0) }
    let buttonNumber = button.skyLightButtonNumber
    let windowFields: [SkyLightIntegerField]
    if let windowNumber {
        let id = Int64(windowNumber)
        windowFields = [
            SkyLightIntegerField(field: 51, value: id),
            SkyLightIntegerField(field: 58, value: clickGroupID),
            SkyLightIntegerField(field: 91, value: id),
            SkyLightIntegerField(field: 92, value: id),
        ]
    } else {
        windowFields = []
    }

    func fields(clickState: Int64) -> [SkyLightIntegerField] {
        [
            SkyLightIntegerField(field: 1, value: clickState),
            SkyLightIntegerField(field: 3, value: buttonNumber),
            SkyLightIntegerField(field: 7, value: 3),
            SkyLightIntegerField(field: 40, value: Int64(pid)),
        ] + windowFields
    }

    var specs = [
        SkyLightEventSpec(
            kind: .mouseMoved,
            point: point,
            button: button,
            keyCode: nil,
            unicode: [],
            flags: [],
            attachAuthMessage: false,
            integerFields: fields(clickState: 0),
            windowLocation: local,
            delayAfterMilliseconds: 12)
    ]

    for clickState in 1...count {
        specs.append(
            SkyLightEventSpec(
                kind: .mouseDown,
                point: point,
                button: button,
                keyCode: nil,
                unicode: [],
                flags: [],
                attachAuthMessage: false,
                integerFields: fields(clickState: Int64(clickState)),
                windowLocation: local,
                delayAfterMilliseconds: 28))
        specs.append(
            SkyLightEventSpec(
                kind: .mouseUp,
                point: point,
                button: button,
                keyCode: nil,
                unicode: [],
                flags: [],
                attachAuthMessage: false,
                integerFields: fields(clickState: Int64(clickState)),
                windowLocation: local,
                delayAfterMilliseconds: clickState < count ? 80 : 0))
    }
    return specs
}

func skyLightUnicodeKeyboardRecipe(_ chunk: [UniChar]) -> [SkyLightEventSpec] {
    [
        SkyLightEventSpec(
            kind: .keyDown, point: nil, button: nil, keyCode: 0, unicode: chunk, flags: [],
            attachAuthMessage: true, integerFields: [], windowLocation: nil, delayAfterMilliseconds: 8),
        SkyLightEventSpec(
            kind: .keyUp, point: nil, button: nil, keyCode: 0, unicode: chunk, flags: [],
            attachAuthMessage: true, integerFields: [], windowLocation: nil, delayAfterMilliseconds: 0),
    ]
}

func skyLightKeyRecipe(chord: KeyChord) -> [SkyLightEventSpec] {
    [
        SkyLightEventSpec(
            kind: .keyDown, point: nil, button: nil, keyCode: chord.keyCode, unicode: [], flags: chord.flags,
            attachAuthMessage: true, integerFields: [], windowLocation: nil, delayAfterMilliseconds: 8),
        SkyLightEventSpec(
            kind: .keyUp, point: nil, button: nil, keyCode: chord.keyCode, unicode: [], flags: chord.flags,
            attachAuthMessage: true, integerFields: [], windowLocation: nil, delayAfterMilliseconds: 0),
    ]
}

protocol SkyLightEventPosting {
    var enabled: Bool { get }
    var available: Bool { get }
    func post(_ event: CGEvent, to pid: pid_t, attachAuthMessage: Bool) -> Bool
    func setWindowLocation(_ event: CGEvent, _ point: CGPoint) -> Bool
    func setIntegerField(_ event: CGEvent, field: Int, value: Int64) -> Bool
}

struct LiveSkyLightEventPosting: SkyLightEventPosting {
    static let shared = LiveSkyLightEventPosting()

    var enabled: Bool { skyLightEnabled() }
    var available: Bool { SkyLightSymbols.shared.postToPid != nil }

    func post(_ event: CGEvent, to pid: pid_t, attachAuthMessage: Bool) -> Bool {
        SkyLightSymbols.shared.post(event, to: pid, attachAuthMessage: attachAuthMessage)
    }

    func setWindowLocation(_ event: CGEvent, _ point: CGPoint) -> Bool {
        SkyLightSymbols.shared.setWindowLocation(event, point)
    }

    func setIntegerField(_ event: CGEvent, field: Int, value: Int64) -> Bool {
        SkyLightSymbols.shared.setIntegerField(event, field: field, value: value)
    }
}

func skyLightStatus(_ posting: SkyLightEventPosting) -> SkyLightAttemptStatus {
    guard posting.enabled else { return .disabled }
    guard posting.available else { return .unavailable }
    return .available
}

enum SkyLightAttemptStatus: Equatable {
    case disabled
    case unavailable
    case available
}

@discardableResult
func postSkyLightMouseClick(
    point: CGPoint,
    button: MouseButtonKind,
    clickCount: Int,
    context: DeliveryContext,
    posting: SkyLightEventPosting = LiveSkyLightEventPosting.shared
) -> Bool {
    guard skyLightStatus(posting) == .available else { return false }
    let specs = skyLightMouseRecipe(
        pid: context.pid,
        point: point,
        button: button,
        clickCount: clickCount,
        windowNumber: context.windowNumber,
        windowFrame: context.windowFrame)
    return postSkyLightSpecs(specs, pid: context.pid, posting: posting)
}

@discardableResult
func postSkyLightUnicodeKeyboard(
    _ chunk: [UniChar],
    pid: pid_t,
    posting: SkyLightEventPosting = LiveSkyLightEventPosting.shared
) -> Bool {
    guard skyLightStatus(posting) == .available else { return false }
    return postSkyLightSpecs(skyLightUnicodeKeyboardRecipe(chunk), pid: pid, posting: posting)
}

@discardableResult
func postSkyLightKey(
    _ chord: KeyChord,
    pid: pid_t,
    posting: SkyLightEventPosting = LiveSkyLightEventPosting.shared
) -> Bool {
    guard skyLightStatus(posting) == .available else { return false }
    return postSkyLightSpecs(skyLightKeyRecipe(chord: chord), pid: pid, posting: posting)
}

private func postSkyLightSpecs(_ specs: [SkyLightEventSpec], pid: pid_t, posting: SkyLightEventPosting) -> Bool {
    for spec in specs {
        guard let event = makeCGEvent(from: spec) else { return false }
        for field in spec.integerFields {
            guard posting.setIntegerField(event, field: field.field, value: field.value) else { return false }
        }
        if let point = spec.windowLocation {
            guard posting.setWindowLocation(event, point) else { return false }
        }
        guard posting.post(event, to: pid, attachAuthMessage: spec.attachAuthMessage) else {
            return false
        }
        if spec.delayAfterMilliseconds > 0 {
            Thread.sleep(forTimeInterval: Double(spec.delayAfterMilliseconds) / 1000)
        }
    }
    return true
}

private func makeCGEvent(from spec: SkyLightEventSpec) -> CGEvent? {
    let source = CGEventSource(stateID: .privateState)
    switch spec.kind {
    case .mouseMoved:
        guard let point = spec.point, let button = spec.button else { return nil }
        let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button.cgButton)
        event?.flags = spec.flags
        return event
    case .mouseDown:
        guard let point = spec.point, let button = spec.button else { return nil }
        let event = CGEvent(mouseEventSource: source, mouseType: button.downType, mouseCursorPosition: point, mouseButton: button.cgButton)
        event?.flags = spec.flags
        return event
    case .mouseUp:
        guard let point = spec.point, let button = spec.button else { return nil }
        let event = CGEvent(mouseEventSource: source, mouseType: button.upType, mouseCursorPosition: point, mouseButton: button.cgButton)
        event?.flags = spec.flags
        return event
    case .keyDown:
        guard let keyCode = spec.keyCode else { return nil }
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        applyKeyboardPayload(spec, to: event)
        return event
    case .keyUp:
        guard let keyCode = spec.keyCode else { return nil }
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        applyKeyboardPayload(spec, to: event)
        return event
    }
}

private func applyKeyboardPayload(_ spec: SkyLightEventSpec, to event: CGEvent?) {
    guard let event else { return }
    event.flags = spec.flags
    let unicode = spec.unicode
    if !unicode.isEmpty {
        unicode.withUnsafeBufferPointer { buffer in
            event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
    }
}

private extension MouseButtonKind {
    var skyLightButtonNumber: Int64 {
        switch self {
        case .left: return 0
        case .right: return 1
        case .middle: return 2
        }
    }
}

// The symbol table is immutable after init. The stored values are raw C function
// pointers resolved with dlsym/unsafeBitCast and the dlopen handle is never
// mutated or closed after initialization. Swift cannot prove these function
// pointer values are Sendable, so the singleton is @unchecked Sendable; sharing
// it across tasks only shares resolved code addresses, not mutable Swift state.
private final class SkyLightSymbols: @unchecked Sendable {
    static let shared = SkyLightSymbols()

    typealias PostToPidFn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Void
    typealias SetAuthMessageFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Void
    typealias SetWindowLocationFn = @convention(c) (UnsafeMutableRawPointer, Double, Double) -> Void
    typealias SetIntegerFieldFn = @convention(c) (UnsafeMutableRawPointer, UInt32, Int64) -> Void
    typealias ObjCGetClassFn = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
    typealias SelRegisterNameFn = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
    typealias ObjectGetClassFn = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    typealias ClassRespondsToSelectorFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Bool
    typealias FactoryMsgSendFn =
        @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UnsafeMutableRawPointer, Int32, UInt32) -> UnsafeMutableRawPointer?

    let postToPid: PostToPidFn?
    private let setAuthMessage: SetAuthMessageFn?
    private let setWindowLocationFn: SetWindowLocationFn?
    private let setIntegerFieldFn: SetIntegerFieldFn?
    private let objcGetClass: ObjCGetClassFn?
    private let selRegisterName: SelRegisterNameFn?
    private let objectGetClass: ObjectGetClassFn?
    private let classRespondsToSelector: ClassRespondsToSelectorFn?
    private let factoryMsgSend: FactoryMsgSendFn?

    private init() {
        // Private SPI risk: SkyLight is not public API and can change or vanish
        // across macOS releases; binaries using it may also be rejected by
        // notarization or App Review. We therefore never link it, resolve it
        // lazily, and only use this path when COMPUTER_USE_MCP_SKYLIGHT=1.
        let handle = dlopen(skyLightFrameworkPath, RTLD_LAZY | RTLD_GLOBAL)
        postToPid =
            Self.load("SLEventPostToPid", handle: Self.rtldDefaultHandle)
            ?? Self.load("SLEventPostToPid", handle: handle)
        setAuthMessage =
            Self.load("SLEventSetAuthenticationMessage", handle: Self.rtldDefaultHandle)
            ?? Self.load("SLEventSetAuthenticationMessage", handle: handle)
        setWindowLocationFn =
            Self.load("CGEventSetWindowLocation", handle: Self.rtldDefaultHandle)
            ?? Self.load("CGEventSetWindowLocation", handle: handle)
        setIntegerFieldFn =
            Self.load("SLEventSetIntegerValueField", handle: Self.rtldDefaultHandle)
            ?? Self.load("SLEventSetIntegerValueField", handle: handle)

        objcGetClass = Self.load("objc_getClass", handle: Self.rtldDefaultHandle)
        selRegisterName = Self.load("sel_registerName", handle: Self.rtldDefaultHandle)
        objectGetClass = Self.load("object_getClass", handle: Self.rtldDefaultHandle)
        classRespondsToSelector = Self.load("class_respondsToSelector", handle: Self.rtldDefaultHandle)
        factoryMsgSend = Self.load("objc_msgSend", handle: Self.rtldDefaultHandle)
    }

    func post(_ event: CGEvent, to pid: pid_t, attachAuthMessage: Bool) -> Bool {
        guard let postToPid, let eventPtr = eventPointer(event) else { return false }
        if attachAuthMessage, !attachAuthenticationMessage(to: event, eventPtr: eventPtr, pid: pid) {
            return false
        }
        postToPid(pid, eventPtr)
        return true
    }

    func setWindowLocation(_ event: CGEvent, _ point: CGPoint) -> Bool {
        guard let setWindowLocationFn, let eventPtr = eventPointer(event) else { return false }
        setWindowLocationFn(eventPtr, Double(point.x), Double(point.y))
        return true
    }

    func setIntegerField(_ event: CGEvent, field: Int, value: Int64) -> Bool {
        guard let setIntegerFieldFn, let eventPtr = eventPointer(event) else { return false }
        setIntegerFieldFn(eventPtr, UInt32(field), value)
        return true
    }

    private func attachAuthenticationMessage(to event: CGEvent, eventPtr: UnsafeMutableRawPointer, pid: pid_t) -> Bool {
        guard
            let objcGetClass,
            let selRegisterName,
            let objectGetClass,
            let classRespondsToSelector,
            let factoryMsgSend,
            let setAuthMessage,
            let cls = withCString("SLSEventAuthenticationMessage", objcGetClass),
            let metaclass = objectGetClass(cls),
            let sel = withCString("messageWithEventRecord:pid:version:", selRegisterName),
            classRespondsToSelector(metaclass, sel),
            let record = extractEventRecord(event),
            let message = factoryMsgSend(cls, sel, record, Int32(pid), 0)
        else {
            return false
        }
        setAuthMessage(eventPtr, message)
        return true
    }

    private func extractEventRecord(_ event: CGEvent) -> UnsafeMutableRawPointer? {
        guard let base = eventPointer(event) else { return nil }
        for offset in [24, 32, 16] {
            let slot = base.advanced(by: offset).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            if let record = slot.pointee {
                return record
            }
        }
        return nil
    }

    private func eventPointer(_ event: CGEvent) -> UnsafeMutableRawPointer? {
        Unmanaged.passUnretained(event).toOpaque()
    }

    private static func load<T>(_ name: String, handle: UnsafeMutableRawPointer?) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }

    private static var rtldDefaultHandle: UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: -2)
    }
}

private func withCString<T>(_ string: String, _ body: (UnsafePointer<CChar>) -> T?) -> T? {
    string.withCString { pointer in body(pointer) }
}
