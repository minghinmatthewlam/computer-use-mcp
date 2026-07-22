#if os(macOS)
import Carbon.HIToolbox
#endif
import Foundation
import Testing

@testable import computer_use_mcp

@Suite(.serialized) struct KeymapTests {
    @Test func namedKey() throws {
        let chord = try Keymap.parse("Return")
        #expect(chord.keyCode == CGKeyCode(kVK_Return))
        #expect(chord.flags.isEmpty)
    }

    @Test func modifierChord() throws {
        let chord = try Keymap.parse("cmd+shift+s")
        #expect(chord.flags.contains(.maskCommand))
        #expect(chord.flags.contains(.maskShift))
    }

    @Test func modifierAliases() throws {
        for alias in ["cmd+a", "command+a", "super+a", "meta+a"] {
            let chord = try Keymap.parse(alias)
            #expect(chord.flags.contains(.maskCommand), "\(alias) should map to command")
        }
    }

    @Test func shiftedCharacterGetsShiftFlag() throws {
        // "?" requires shift on a US layout; the flag must be added implicitly.
        let chord = try Keymap.parse("?")
        #expect(chord.flags.contains(.maskShift))
    }

    @Test func unknownModifierThrows() {
        #expect(throws: (any Error).self) { try Keymap.parse("hyper+a") }
    }

    @Test func unknownKeyThrows() {
        #expect(throws: (any Error).self) { try Keymap.parse("cmd+NotAKey") }
    }

    @Test func emptyThrows() {
        #expect(throws: (any Error).self) { try Keymap.parse("") }
    }

    @Test func wouldInsertTextDetectsPrintableKeys() throws {
        let letter = try Keymap.parse("a")
        #expect(Keymap.wouldInsertText(combo: "a", chord: letter))

        let space = try Keymap.parse("space")
        #expect(Keymap.wouldInsertText(combo: "space", chord: space))

        let shifted = try Keymap.parse("?")
        #expect(Keymap.wouldInsertText(combo: "?", chord: shifted))
    }

    @Test func wouldInsertTextRejectsNavigationAndShortcuts() throws {
        let tab = try Keymap.parse("Tab")
        #expect(!Keymap.wouldInsertText(combo: "Tab", chord: tab))

        let arrow = try Keymap.parse("Up")
        #expect(!Keymap.wouldInsertText(combo: "Up", chord: arrow))

        let shortcut = try Keymap.parse("cmd+a")
        #expect(!Keymap.wouldInsertText(combo: "cmd+a", chord: shortcut))

        let ret = try Keymap.parse("Return")
        #expect(!Keymap.wouldInsertText(combo: "Return", chord: ret))
    }
}
