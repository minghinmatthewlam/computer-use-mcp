// Teach mode: record the user demonstrating a task, compile it into a skill
// draft the agent can review and save_skill.
//
// A listen-only CGEventTap (needs the Input Monitoring grant, prompted on
// first use) observes the user's real clicks and keystrokes while the target
// app is frontmost — it never modifies or injects events. Clicks are mapped
// to the accessibility element underneath (role + label → a durable locator,
// the same anchor run_skill re-resolves). Consecutive typed characters
// coalesce into type_text; a modifier chord becomes press_key. Recording
// pauses whenever secure input is active, so passwords are never captured.
//
// The tap runs on its own thread with a CFRunLoop because the daemon's main
// thread is parked. The compile step (recorded events → skill steps) is a
// pure function, unit-tested without a tap.

import Foundation
import MCP
#if os(macOS)
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
#endif

/// One observed user action, app-relative. Captured live, compiled at stop.
enum RecordedEvent: Equatable {
    case click(role: String, label: String?, clickCount: Int, button: String)
    case text(String)
    case key(combo: String)
    case scroll(direction: String)
}

/// Compile observed events into skill steps. Pure: no tap, no AX, fully
/// testable. Adjacent text runs are already merged by the recorder; this
/// drops empty text and renders each event as the step the executor replays.
func compileRecordedEvents(_ events: [RecordedEvent]) -> [SkillStep] {
    var steps: [SkillStep] = []
    for event in events {
        switch event {
        case .click(let role, let label, let clickCount, let button):
            var arguments: [String: Value] = [:]
            if clickCount > 1 { arguments["click_count"] = .int(clickCount) }
            if button != "left" { arguments["mouse_button"] = .string(button) }
            steps.append(
                SkillStep(tool: "click", locator: SkillLocator(role: role, label: label), arguments: arguments))
        case .text(let string):
            guard !string.isEmpty else { continue }
            steps.append(SkillStep(tool: "type_text", arguments: ["text": .string(string)]))
        case .key(let combo):
            steps.append(SkillStep(tool: "press_key", arguments: ["key": .string(combo)]))
        case .scroll(let direction):
            steps.append(SkillStep(tool: "scroll", arguments: ["direction": .string(direction)]))
        }
    }
    return steps
}

/// Locator label for a recorded click. Text-entry elements get none — their
/// label is the field's own description/placeholder/content, which churns as
/// the user types (and would bake user data into the skill); role + structure
/// anchor them instead.
func recordedClickLabel(role: String, label: String?) -> String? {
    isTextEntryRole(role) ? nil : label
}

/// Modifier chords that make a keyDown a shortcut (press_key) rather than
/// typed text. Shift alone is just capitalization, so it is not here.
func keyComboIsShortcut(commandDown: Bool, controlDown: Bool, optionDown: Bool) -> Bool {
    commandDown || controlDown || optionDown
}

enum RecorderError: Error, CustomStringConvertible {
    case tapCreationFailed
    case alreadyRecording(app: String)
    case notRecording

    var description: String {
        switch self {
        case .tapCreationFailed:
            return
                "Could not start recording. Grant Input Monitoring to this app under System "
                + "Settings → Privacy & Security → Input Monitoring, then try again."
        case .alreadyRecording(let app):
            return "Already recording \(app). Call record_skill_stop first."
        case .notRecording:
            return "Not currently recording. Call record_skill_start first."
        }
    }
}

#if os(macOS)
/// Owns the event tap and the live event buffer. A final class (not an actor)
/// because the CGEventTap C callback needs a stable refcon pointer and runs on
/// the tap thread; a lock guards the shared buffer.
final class SkillRecorder: @unchecked Sendable {
    static let shared = SkillRecorder()

    private let lock = NSLock()
    private var targetPid: pid_t?
    private var targetApp: String?
    private var events: [RecordedEvent] = []
    private var pendingText = ""
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?

    var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return targetPid != nil
    }

    func start(app: ResolvedApp) throws {
        lock.lock()
        if let current = targetApp {
            lock.unlock()
            throw RecorderError.alreadyRecording(app: current)
        }
        targetPid = app.pid
        targetApp = app.name
        events = []
        pendingText = ""
        lock.unlock()

        // The tap must live on a thread running a CFRunLoop; the daemon main
        // thread does not run one. Create the tap on that thread and block
        // until it is installed so failure surfaces synchronously.
        let ready = DispatchSemaphore(value: 0)
        var creationOK = false
        let thread = Thread { [weak self] in
            guard let self else { return }
            let mask: CGEventMask =
                (1 << CGEventType.leftMouseDown.rawValue)
                | (1 << CGEventType.rightMouseDown.rawValue)
                | (1 << CGEventType.keyDown.rawValue)
                | (1 << CGEventType.scrollWheel.rawValue)
            guard
                let tap = CGEvent.tapCreate(
                    tap: .cgSessionEventTap, place: .headInsertEventTap,
                    options: .listenOnly, eventsOfInterest: mask,
                    callback: { _, type, event, refcon in
                        let recorder = Unmanaged<SkillRecorder>.fromOpaque(refcon!).takeUnretainedValue()
                        recorder.handle(type: type, event: event)
                        return Unmanaged.passUnretained(event)  // listen-only: pass through unchanged
                    },
                    userInfo: Unmanaged.passUnretained(self).toOpaque()
                )
            else {
                ready.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self.lock.lock()
            self.tap = tap
            self.runLoopSource = source
            self.tapRunLoop = CFRunLoopGetCurrent()
            self.lock.unlock()
            creationOK = true
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "computer-use-mcp.recorder"
        tapThread = thread
        thread.start()
        ready.wait()
        guard creationOK else {
            lock.lock()
            targetPid = nil
            targetApp = nil
            lock.unlock()
            throw RecorderError.tapCreationFailed
        }
    }

    /// Stop recording and return the compiled draft steps.
    func stop() throws -> (app: String, steps: [SkillStep]) {
        lock.lock()
        guard let app = targetApp else {
            lock.unlock()
            throw RecorderError.notRecording
        }
        flushPendingTextLocked()
        let recorded = events
        let tap = self.tap
        let source = self.runLoopSource
        let runLoop = self.tapRunLoop
        targetPid = nil
        targetApp = nil
        events = []
        self.tap = nil
        self.runLoopSource = nil
        self.tapRunLoop = nil
        lock.unlock()

        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopStop(runLoop)
        }
        tapThread = nil
        return (app, compileRecordedEvents(recorded))
    }

    // MARK: tap callback

    private func handle(type: CGEventType, event: CGEvent) {
        // Only record while the target app is the one receiving input, so
        // clicks into other apps (or onto the desktop) are ignored.
        lock.lock()
        guard let pid = targetPid else { lock.unlock(); return }
        lock.unlock()
        guard FrontmostAppSnapshot.current()?.pid == pid else { return }

        switch type {
        case .keyDown:
            handleKey(event)
        case .leftMouseDown, .rightMouseDown:
            handleClick(event, pid: pid, button: type == .rightMouseDown ? "right" : "left")
        case .scrollWheel:
            let dy = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            recordEvent(.scroll(direction: dy < 0 ? "down" : "up"))
        default:
            break
        }
    }

    private func handleClick(_ event: CGEvent, pid: pid_t, button: String) {
        let point = event.location
        let clickCount = max(1, Int(event.getIntegerValueField(.mouseEventClickState)))
        var role = "AXButton"
        var label: String?
        if let element = accessibilityElement(at: point, pid: pid) {
            role = axRole(element)
            label = recordedClickLabel(role: role, label: clickableLabel(element))
        }
        lock.lock()
        flushPendingTextLocked()
        events.append(.click(role: role, label: label, clickCount: clickCount, button: button))
        lock.unlock()
    }

    private func handleKey(_ event: CGEvent) {
        // Never capture keystrokes while a secure input field is active: this
        // is the password guard.
        guard !IsSecureEventInputEnabled() else { return }
        let flags = event.flags
        let command = flags.contains(.maskCommand)
        let control = flags.contains(.maskControl)
        let option = flags.contains(.maskAlternate)

        if keyComboIsShortcut(commandDown: command, controlDown: control, optionDown: option) {
            var parts: [String] = []
            if command { parts.append("cmd") }
            if control { parts.append("ctrl") }
            if option { parts.append("option") }
            if flags.contains(.maskShift) { parts.append("shift") }
            if let key = keyNameForShortcut(event) {
                parts.append(key)
                lock.lock()
                flushPendingTextLocked()
                events.append(.key(combo: parts.joined(separator: "+")))
                lock.unlock()
            }
            return
        }

        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return }
        let string = String(utf16CodeUnits: chars, count: length)
        // Enter/Tab/Escape are navigation, not text — emit as key presses.
        if let control = controlKeyName(string) {
            lock.lock()
            flushPendingTextLocked()
            events.append(.key(combo: control))
            lock.unlock()
            return
        }
        lock.lock()
        pendingText += string
        lock.unlock()
    }

    private func recordEvent(_ event: RecordedEvent) {
        lock.lock()
        flushPendingTextLocked()
        events.append(event)
        lock.unlock()
    }

    /// Flush buffered typed characters into a single text event. Caller holds
    /// the lock.
    private func flushPendingTextLocked() {
        guard !pendingText.isEmpty else { return }
        events.append(.text(pendingText))
        pendingText = ""
    }
}
#else
final class SkillRecorder: @unchecked Sendable {
    static let shared = SkillRecorder()
    var isRecording: Bool { false }

    func start(app: ResolvedApp) throws {
        throw RecorderError.tapCreationFailed
    }

    func stop() throws -> (app: String, steps: [SkillStep]) {
        throw RecorderError.notRecording
    }
}
#endif

/// Map a control character produced by keyboardGetUnicodeString to a key name,
/// or nil when it is ordinary text.
func controlKeyName(_ string: String) -> String? {
    switch string {
    case "\r", "\u{3}": return "Return"
    case "\t": return "Tab"
    case "\u{1b}": return "Escape"
    case "\u{7f}", "\u{8}": return "BackSpace"
    default: return nil
    }
}

/// Best-effort key name for a shortcut's non-modifier key, from the typed
/// character with modifiers stripped.
private func keyNameForShortcut(_ event: CGEvent) -> String? {
    var length = 0
    var chars = [UniChar](repeating: 0, count: 8)
    // Re-read without modifier influence by consulting the base layer is
    // overkill here; the unicode string with cmd held is still the base key
    // for letter/digit shortcuts, which covers the common case.
    event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
    guard length > 0 else { return nil }
    let string = String(utf16CodeUnits: chars, count: length).lowercased()
    if let control = controlKeyName(string) { return control }
    let scalar = string.unicodeScalars.first
    if let scalar, scalar.value >= 32, scalar.value < 127 { return string }
    return nil
}
