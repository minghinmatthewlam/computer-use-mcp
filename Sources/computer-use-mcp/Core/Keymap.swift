 #if os(macOS)
// Parse xdotool-style key strings ("cmd+shift+s", "Return", "a") into a
// CGKeyCode + modifier flags. Named keys use layout-independent virtual
// keycodes; printable characters are translated against the current keyboard
// layout via UCKeyTranslate.

import Foundation
#if os(macOS)
import Carbon.HIToolbox
import CoreGraphics
#endif

struct KeyChord {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

enum Keymap {
    /// Parse a chord like "cmd+shift+s". All but the last token are modifiers.
    static func parse(_ combo: String) throws -> KeyChord {
        var tokens = combo.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let keyToken = tokens.popLast(), !keyToken.isEmpty else {
            throw ToolError.invalidArguments("Empty key string.")
        }

        var flags: CGEventFlags = []
        for token in tokens {
            guard let flag = modifierFlag(token) else {
                throw ToolError.invalidArguments(
                    "Unknown modifier \"\(token)\" in \"\(combo)\". Use cmd, ctrl, alt/option, shift, fn."
                )
            }
            flags.formUnion(flag)
        }

        guard let resolved = keyCode(for: keyToken) else {
            throw ToolError.invalidArguments(
                "Unknown key \"\(keyToken)\" in \"\(combo)\". Use a single character or a named key "
                    + "like Return, Tab, Escape, Up, F5, Delete, space."
            )
        }
        if resolved.needsShift {
            flags.formUnion(.maskShift)
        }
        return KeyChord(keyCode: resolved.code, flags: flags)
    }

    /// True when this chord would insert a character into a text field
    /// (a printable key or Space, with at most Shift). Modifier shortcuts
    /// (⌘/⌃/⌥/Fn) and navigation/named keys do not insert text.
    static func wouldInsertText(combo: String, chord: KeyChord) -> Bool {
        var nonShift = chord.flags
        nonShift.remove(.maskShift)
        guard nonShift.isEmpty else { return false }

        let tokens = combo.split(separator: "+").map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        guard let keyToken = tokens.last, !keyToken.isEmpty else { return false }
        if keyToken.count == 1 { return true }
        switch keyToken.lowercased() {
        case "space", " ": return true
        default: return false
        }
    }

    private static func modifierFlag(_ token: String) -> CGEventFlags? {
        switch token.lowercased() {
        case "cmd", "command", "super", "meta", "win": return .maskCommand
        case "ctrl", "control": return .maskControl
        case "alt", "option", "opt": return .maskAlternate
        case "shift": return .maskShift
        case "fn", "function": return .maskSecondaryFn
        default: return nil
        }
    }

    /// Named keys → layout-independent virtual keycodes (Carbon kVK_*).
    private static let namedKeys: [String: CGKeyCode] = [
        "return": CGKeyCode(kVK_Return), "enter": CGKeyCode(kVK_Return),
        "tab": CGKeyCode(kVK_Tab), "space": CGKeyCode(kVK_Space), " ": CGKeyCode(kVK_Space),
        "delete": CGKeyCode(kVK_Delete), "backspace": CGKeyCode(kVK_Delete),
        "forwarddelete": CGKeyCode(kVK_ForwardDelete),
        "escape": CGKeyCode(kVK_Escape), "esc": CGKeyCode(kVK_Escape),
        "left": CGKeyCode(kVK_LeftArrow), "right": CGKeyCode(kVK_RightArrow),
        "up": CGKeyCode(kVK_UpArrow), "down": CGKeyCode(kVK_DownArrow),
        "home": CGKeyCode(kVK_Home), "end": CGKeyCode(kVK_End),
        "pageup": CGKeyCode(kVK_PageUp), "pagedown": CGKeyCode(kVK_PageDown),
        "f1": CGKeyCode(kVK_F1), "f2": CGKeyCode(kVK_F2), "f3": CGKeyCode(kVK_F3),
        "f4": CGKeyCode(kVK_F4), "f5": CGKeyCode(kVK_F5), "f6": CGKeyCode(kVK_F6),
        "f7": CGKeyCode(kVK_F7), "f8": CGKeyCode(kVK_F8), "f9": CGKeyCode(kVK_F9),
        "f10": CGKeyCode(kVK_F10), "f11": CGKeyCode(kVK_F11), "f12": CGKeyCode(kVK_F12),
    ]

    private static func keyCode(for token: String) -> (code: CGKeyCode, needsShift: Bool)? {
        if let named = namedKeys[token.lowercased()] {
            return (named, false)
        }
        if token.count == 1, let char = token.first {
            return keyCodeForCharacter(char)
        }
        return nil
    }

    /// Translate a printable character to a keycode on the current layout by
    /// scanning keycodes — first unshifted, then shifted (so bare "?" / "@"
    /// resolve and report that Shift is required).
    private static func keyCodeForCharacter(_ character: Character) -> (code: CGKeyCode, needsShift: Bool)? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        let target = String(character)

        return layoutData.withUnsafeBytes { raw -> (CGKeyCode, Bool)? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            let keyboardType = UInt32(LMGetKbdType())
            for shift in [false, true] {
                for code in 0..<CGKeyCode(128) {
                    if produced(layout, code, shift: shift, keyboardType: keyboardType) == target {
                        return (code, shift)
                    }
                }
            }
            return nil
        }
    }

    private static func produced(
        _ layout: UnsafePointer<UCKeyboardLayout>, _ code: CGKeyCode, shift: Bool, keyboardType: UInt32
    ) -> String? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let modifiers: UInt32 = shift ? UInt32((shiftKey >> 8) & 0xff) : 0
        let status = UCKeyTranslate(
            layout, code, UInt16(kUCKeyActionDown), modifiers, keyboardType,
            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
#endif
