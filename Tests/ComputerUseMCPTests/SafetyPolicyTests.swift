#if os(macOS)
import ApplicationServices
#endif
import Foundation
import Testing

@testable import computer_use_mcp

private let app = ResolvedApp(pid: 1, name: "TestApp", bundleIdentifier: "com.example.test")

private func invalidArgumentMessage(_ body: () throws -> Void) -> String {
    do {
        try body()
        #expect(Bool(false), "Expected ToolError.invalidArguments.")
        return ""
    } catch let error as ToolError {
        guard case .invalidArguments(let message) = error else {
            #expect(Bool(false), "Expected ToolError.invalidArguments, got \(error).")
            return ""
        }
        return message
    } catch {
        #expect(Bool(false), "Expected ToolError.invalidArguments, got \(error).")
        return ""
    }
}

@Suite struct SafetyPolicyTests {
    @Test func destructiveLabelsRequireConfirmation() {
        for label in ["Delete", "Move to Trash", "Erase All Content", "Don't Save", "Reset Settings"] {
            #expect(throws: SafetyError.self, "\(label) should be gated") {
                try SafetyPolicy.checkClick(label: label, app: app, confirmed: false)
            }
        }
    }

    @Test func benignLabelsPass() throws {
        for label in ["OK", "Save", "Open", "7", "All Clear"] {
            try SafetyPolicy.checkClick(label: label, app: app, confirmed: false)
        }
    }

    @Test func confirmationBypassesGate() throws {
        try SafetyPolicy.checkClick(label: "Delete", app: app, confirmed: true)
    }

    @Test func clearingValueIsGated() {
        #expect(throws: SafetyError.self) {
            try SafetyPolicy.checkValueChange(currentValue: "existing text", newValue: "", app: app, confirmed: false)
        }
    }

    @Test func settingValueOnEmptyFieldPasses() throws {
        try SafetyPolicy.checkValueChange(currentValue: "", newValue: "hello", app: app, confirmed: false)
        try SafetyPolicy.checkValueChange(currentValue: "old", newValue: "new", app: app, confirmed: false)
    }

    @Test func closingWindowRequiresConfirmation() {
        #expect(throws: SafetyError.self) {
            try SafetyPolicy.checkWindowAction(
                action: "close", targetDescription: "window \"Draft\" of TestApp", app: app, confirmed: false
            )
        }
    }

    @Test func confirmedWindowClosePasses() throws {
        try SafetyPolicy.checkWindowAction(
            action: "close", targetDescription: "window \"Draft\" of TestApp", app: app, confirmed: true
        )
    }

    @Test func nonClosingWindowActionPasses() throws {
        try SafetyPolicy.checkWindowAction(
            action: "minimize", targetDescription: "window \"Draft\" of TestApp", app: app, confirmed: false
        )
    }

    @Test func destructiveShortcutIsGated() throws {
        let chord = try Keymap.parse("cmd+Delete")
        #expect(throws: SafetyError.self) {
            try SafetyPolicy.checkKey(combo: "cmd+Delete", chord: chord, focused: nil, app: app, confirmed: false)
        }
    }

    @Test func plainKeyPasses() throws {
        let chord = try Keymap.parse("Tab")
        try SafetyPolicy.checkKey(combo: "Tab", chord: chord, focused: nil, app: app, confirmed: false)
    }

    @Test func printableKeyIntoSecureFieldIsGated() {
        #expect(throws: SafetyError.self) {
            try SafetyPolicy.checkSecureFieldKeyInsertion(
                insertsText: true,
                focusedSubrole: kAXSecureTextFieldSubrole as String,
                secureEventInputEnabled: false,
                app: app,
                confirmed: false
            )
        }
    }

    @Test func confirmedPrintableKeyIntoSecureFieldPasses() throws {
        try SafetyPolicy.checkSecureFieldKeyInsertion(
            insertsText: true,
            focusedSubrole: kAXSecureTextFieldSubrole as String,
            secureEventInputEnabled: false,
            app: app,
            confirmed: true
        )
    }

    @Test func printableKeyIntoNonSecureFieldPasses() throws {
        try SafetyPolicy.checkSecureFieldKeyInsertion(
            insertsText: true,
            focusedSubrole: nil,
            secureEventInputEnabled: false,
            app: app,
            confirmed: false
        )
        try SafetyPolicy.checkSecureFieldKeyInsertion(
            insertsText: true,
            focusedSubrole: "AXTextField",
            secureEventInputEnabled: false,
            app: app,
            confirmed: false
        )
    }

    @Test func nonTextKeyIntoSecureFieldDoesNotUseSecureFieldGate() throws {
        // Arrows/Tab/shortcuts are not text insertion; existing destructive
        // / activate gates still apply separately.
        try SafetyPolicy.checkSecureFieldKeyInsertion(
            insertsText: false,
            focusedSubrole: kAXSecureTextFieldSubrole as String,
            secureEventInputEnabled: false,
            app: app,
            confirmed: false
        )
        #expect(
            !keyPressRequiresSecureFieldConfirm(
                insertsText: false,
                focusedSubrole: kAXSecureTextFieldSubrole as String
            )
        )
    }

    @Test func secureEventInputIsSecondarySignalForTextKeys() {
        #expect(
            keyPressRequiresSecureFieldConfirm(
                insertsText: true, focusedSubrole: nil, secureEventInputEnabled: true
            )
        )
        #expect(
            !keyPressRequiresSecureFieldConfirm(
                insertsText: true, focusedSubrole: nil, secureEventInputEnabled: false
            )
        )
    }

    @Test func safetyErrorExplainsRecovery() {
        let error = SafetyError(reason: "test reason.")
        #expect(error.description.contains("confirm"))
        #expect(error.description.contains("test reason."))
    }

    @Test func launchingAppRequiresConfirmation() {
        #expect(throws: SafetyError.self) {
            try SafetyPolicy.checkOpenApp(
                identifier: "Notes.app", activate: false, isAlreadyRunning: false, confirmed: false
            )
        }
    }

    @Test func activatingAppRequiresConfirmation() {
        #expect(throws: SafetyError.self) {
            try SafetyPolicy.checkOpenApp(
                identifier: "Notes", activate: true, isAlreadyRunning: true, confirmed: false
            )
        }
    }

    @Test func alreadyRunningOpenAppNoopPassesWithoutConfirmation() throws {
        try SafetyPolicy.checkOpenApp(identifier: "Notes", activate: false, isAlreadyRunning: true, confirmed: false)
    }

    @Test func confirmedOpenAppPasses() throws {
        try SafetyPolicy.checkOpenApp(identifier: "Notes.app", activate: false, isAlreadyRunning: false, confirmed: true)
        try SafetyPolicy.checkOpenApp(identifier: "Notes", activate: true, isAlreadyRunning: true, confirmed: true)
    }

    @Test func routineHttpURLsPassWithoutConfirmation() throws {
        try SafetyPolicy.checkOpenURL(#require(URL(string: "https://example.com")), confirmed: false)
        try SafetyPolicy.checkOpenURL(#require(URL(string: "http://example.com")), confirmed: false)
    }

    @Test func localFilesAndAppSchemesRequireConfirmation() {
        #expect(throws: SafetyError.self) {
            try SafetyPolicy.checkOpenURL(URL(fileURLWithPath: "/tmp/example.txt"), confirmed: false)
        }
        #expect(throws: SafetyError.self) {
            try SafetyPolicy.checkOpenURL(#require(URL(string: "shortcuts://run-shortcut?name=demo")), confirmed: false)
        }
    }

    @Test func confirmedLocalFileAndAppSchemeOpenPasses() throws {
        try SafetyPolicy.checkOpenURL(URL(fileURLWithPath: "/tmp/example.txt"), confirmed: true)
        try SafetyPolicy.checkOpenURL(#require(URL(string: "shortcuts://run-shortcut?name=demo")), confirmed: true)
    }

    @Test func clipboardWriteRequiresConfirmation() {
        #expect(throws: SafetyError.self) {
            try SafetyPolicy.checkClipboardWrite(confirmed: false)
        }
    }

    @Test func confirmedClipboardWritePasses() throws {
        try SafetyPolicy.checkClipboardWrite(confirmed: true)
    }

    @Test func overlongStringArgumentsFailWithUsefulErrors() {
        let typeTextMessage = invalidArgumentMessage {
            try ArgumentBounds.checkStringLength(
                String(repeating: "x", count: ArgumentBounds.maxTypeTextCharacters + 1),
                argument: "text",
                maximum: ArgumentBounds.maxTypeTextCharacters
            )
        }
        #expect(typeTextMessage.contains("\"text\""))
        #expect(typeTextMessage.contains("maximum"))

        let clipboardMessage = invalidArgumentMessage {
            try ArgumentBounds.checkStringLength(
                String(repeating: "x", count: ArgumentBounds.maxClipboardCharacters + 1),
                argument: "text",
                maximum: ArgumentBounds.maxClipboardCharacters
            )
        }
        #expect(clipboardMessage.contains("split"))
    }

    @Test func readTextBoundsFailWithUsefulErrors() {
        let negativeOffset = invalidArgumentMessage {
            try ArgumentBounds.checkReadText(offset: -1, length: 100)
        }
        #expect(negativeOffset.contains("\"offset\""))

        let tooLong = invalidArgumentMessage {
            try ArgumentBounds.checkReadText(offset: 0, length: ArgumentBounds.maxReadTextCharacters + 1)
        }
        #expect(tooLong.contains("\"length\""))
        #expect(tooLong.contains("chunking"))
    }

    @Test func clickCountBoundsFailWithUsefulErrors() throws {
        let zeroClicks = invalidArgumentMessage {
            _ = try ArgumentBounds.checkClickCount(0)
        }
        #expect(zeroClicks.contains("\"click_count\""))

        let tooManyClicks = invalidArgumentMessage {
            _ = try ArgumentBounds.checkClickCount(ArgumentBounds.maxClickCount + 1)
        }
        #expect(tooManyClicks.contains("\(ArgumentBounds.maxClickCount)"))

        #expect(try ArgumentBounds.checkClickCount(1) == 1)
        #expect(try ArgumentBounds.checkClickCount(ArgumentBounds.maxClickCount) == ArgumentBounds.maxClickCount)
    }

    @Test func clickCountArgumentRejectsNonIntegerValues() throws {
        #expect(try clickCountArgument([:]) == 1)
        #expect(try clickCountArgument(["click_count": .int(2)]) == 2)

        let fractional = invalidArgumentMessage {
            _ = try clickCountArgument(["click_count": .double(1.5)])
        }
        #expect(fractional.contains("\"click_count\""))
        #expect(fractional.contains("integer"))
    }

    @Test func scrollBoundsFailWithUsefulErrors() throws {
        let badPages = invalidArgumentMessage {
            _ = try ArgumentBounds.checkScrollPages(ArgumentBounds.maxScrollPages + 0.1)
        }
        #expect(badPages.contains("\"pages\""))

        let badDelta = invalidArgumentMessage {
            try ArgumentBounds.checkScrollDelta(deltaX: ArgumentBounds.maxScrollDelta + 1, deltaY: 0)
        }
        #expect(badDelta.contains("\"delta_x\""))

        _ = try ArgumentBounds.checkScrollPages(1)
        try ArgumentBounds.checkScrollDelta(deltaX: ArgumentBounds.maxScrollDelta, deltaY: -ArgumentBounds.maxScrollDelta)
    }

    @Test func windowGeometryBoundsFailWithUsefulErrors() throws {
        let nonFinitePosition = invalidArgumentMessage {
            try ArgumentBounds.checkWindowPosition(x: .infinity, y: 0)
        }
        #expect(nonFinitePosition.contains("\"x\""))
        #expect(nonFinitePosition.contains("finite"))

        let hugePosition = invalidArgumentMessage {
            try ArgumentBounds.checkWindowPosition(x: ArgumentBounds.maxWindowCoordinateMagnitude + 1, y: 0)
        }
        #expect(hugePosition.contains("\"x\""))
        #expect(hugePosition.contains("\"y\""))

        let zeroSize = invalidArgumentMessage {
            try ArgumentBounds.checkWindowSize(width: 0, height: 100)
        }
        #expect(zeroSize.contains("\"width\""))
        #expect(zeroSize.contains("\"height\""))

        let nonFiniteSize = invalidArgumentMessage {
            try ArgumentBounds.checkWindowSize(width: 100, height: .nan)
        }
        #expect(nonFiniteSize.contains("\"height\""))
        #expect(nonFiniteSize.contains("finite"))

        try ArgumentBounds.checkWindowPosition(x: -ArgumentBounds.maxWindowCoordinateMagnitude, y: 0)
        try ArgumentBounds.checkWindowSize(width: ArgumentBounds.minWindowDimension, height: ArgumentBounds.maxWindowDimension)
    }
}
