 #if os(macOS)
#if os(macOS)
import CoreGraphics
#endif
#if os(macOS)
import Darwin
#endif
import Foundation
import Testing

@testable import computer_use_mcp

@Suite struct SkyLightInputTests {
    @Test func environmentGateDefaultsOff() {
        #expect(!skyLightEnabled(environment: [:]))
        #expect(!skyLightEnabled(environment: ["COMPUTER_USE_MCP_SKYLIGHT": "0"]))
        #expect(skyLightEnabled(environment: ["COMPUTER_USE_MCP_SKYLIGHT": "1"]))
    }

    @Test func gateOffDoesNotConsultAvailability() {
        let posting = ProbeSkyLightPosting(enabled: false, availableValue: true)
        #expect(skyLightStatus(posting) == .disabled)
        #expect(!posting.availableWasRead)
    }

    @Test func enabledMissingSymbolReportsUnavailable() {
        let posting = ProbeSkyLightPosting(enabled: true, availableValue: false)
        #expect(skyLightStatus(posting) == .unavailable)
        #expect(posting.availableWasRead)
    }

    @Test func symbolMissingPathFallsBackCleanly() {
        let context = DeliveryContext(
            pid: 1,
            windowNumber: nil,
            windowFrame: nil,
            allowGlobalCursor: false)
        let reasons = syntheticFallbackReasons(
            context: context,
            bridgeSucceeded: false,
            skyLightStatus: .unavailable)
        #expect(reasons == [.windowNumberUnresolved, .windowFrameUnresolved, .skyLightUnavailable])
    }

    @Test func skylightDisabledDoesNotChangeExistingFallbackReasons() {
        let context = DeliveryContext(
            pid: 1,
            windowNumber: nil,
            windowFrame: nil,
            allowGlobalCursor: false)
        let reasons = syntheticFallbackReasons(
            context: context,
            bridgeSucceeded: false,
            skyLightStatus: .disabled)
        #expect(reasons == [.windowNumberUnresolved, .windowFrameUnresolved])
    }

    @Test func skylightTierIsDroppableBackgroundDelivery() {
        #expect(isDroppableBackgroundDeliveryTier(InputTier.skyLight.rawValue))
        #expect(isDroppableBackgroundDeliveryTier(KeyDeliveryMode.skyLight.rawValue))
    }

    @Test func mouseRecipeStampsChromiumWindowFieldsAndPrimerWithoutAuth() {
        let specs = skyLightMouseRecipe(
            pid: 123,
            point: CGPoint(x: 25, y: 30),
            button: .left,
            clickCount: 1,
            windowNumber: 42,
            windowFrame: CGRect(x: 10, y: 10, width: 100, height: 50),
            clickGroupID: 777)

        #expect(specs.map(\.kind) == [.mouseMoved, .mouseDown, .mouseUp])
        #expect(specs.allSatisfy { !$0.attachAuthMessage })
        #expect(specs[0].windowLocation == CGPoint(x: 15, y: 30))
        #expect(specs[0].delayAfterMilliseconds == 12)
        #expect(specs[1].delayAfterMilliseconds == 28)

        let downFields = fieldsByNumber(specs[1].integerFields)
        #expect(downFields[1] == 1)
        #expect(downFields[3] == 0)
        #expect(downFields[7] == 3)
        #expect(downFields[40] == 123)
        #expect(downFields[51] == 42)
        #expect(downFields[58] == 777)
        #expect(downFields[91] == 42)
        #expect(downFields[92] == 42)
    }

    @Test func keyboardRecipesAttachAuthenticationMessage() {
        let unicode = skyLightUnicodeKeyboardRecipe([65])
        #expect(unicode.map(\.kind) == [.keyDown, .keyUp])
        #expect(unicode.allSatisfy { $0.attachAuthMessage })
        #expect(unicode.allSatisfy { $0.unicode == [65] })

        let chord = KeyChord(keyCode: 36, flags: .maskCommand)
        let key = skyLightKeyRecipe(chord: chord)
        #expect(key.map(\.kind) == [.keyDown, .keyUp])
        #expect(key.allSatisfy { $0.attachAuthMessage })
        #expect(key.allSatisfy { $0.keyCode == 36 })
        #expect(key.allSatisfy { $0.flags == .maskCommand })
    }

    @Test func mousePostingFailsWhenRequiredIntegerFieldFails() {
        let posting = RecordingSkyLightPosting(integerFieldResult: false)
        let context = DeliveryContext(
            pid: 123,
            windowNumber: nil,
            windowFrame: nil,
            allowGlobalCursor: false)

        #expect(!postSkyLightMouseClick(
            point: CGPoint(x: 25, y: 30),
            button: .left,
            clickCount: 1,
            context: context,
            posting: posting))
        #expect(posting.integerFields == [1])
        #expect(posting.postAttachAuthMessages.isEmpty)
    }

    @Test func mousePostingFailsWhenRequiredWindowLocationFails() {
        let posting = RecordingSkyLightPosting(windowLocationResult: false)
        let context = DeliveryContext(
            pid: 123,
            windowNumber: nil,
            windowFrame: CGRect(x: 10, y: 10, width: 100, height: 50),
            allowGlobalCursor: false)

        #expect(!postSkyLightMouseClick(
            point: CGPoint(x: 25, y: 30),
            button: .left,
            clickCount: 1,
            context: context,
            posting: posting))
        #expect(posting.windowLocations == [CGPoint(x: 15, y: 30)])
        #expect(posting.postAttachAuthMessages.isEmpty)
    }

    @Test func keyboardPostingRequiresAuthenticatedPostSuccess() {
        let posting = RecordingSkyLightPosting(postResult: false)

        #expect(!postSkyLightUnicodeKeyboard([65], pid: 123, posting: posting))
        #expect(posting.postAttachAuthMessages == [true])
    }

    private func fieldsByNumber(_ fields: [SkyLightIntegerField]) -> [Int: Int64] {
        Dictionary(uniqueKeysWithValues: fields.map { ($0.field, $0.value) })
    }
}

private final class ProbeSkyLightPosting: SkyLightEventPosting {
    let enabled: Bool
    let availableValue: Bool
    var availableWasRead = false

    init(enabled: Bool, availableValue: Bool) {
        self.enabled = enabled
        self.availableValue = availableValue
    }

    var available: Bool {
        availableWasRead = true
        return availableValue
    }

    func post(_ event: CGEvent, to pid: pid_t, attachAuthMessage: Bool) -> Bool {
        Issue.record("post should not be called by these tests")
        return false
    }

    func setWindowLocation(_ event: CGEvent, _ point: CGPoint) -> Bool {
        Issue.record("setWindowLocation should not be called by these tests")
        return false
    }

    func setIntegerField(_ event: CGEvent, field: Int, value: Int64) -> Bool {
        Issue.record("setIntegerField should not be called by these tests")
        return false
    }
}

private final class RecordingSkyLightPosting: SkyLightEventPosting {
    let enabled = true
    let available = true
    let postResult: Bool
    let integerFieldResult: Bool
    let windowLocationResult: Bool
    var integerFields: [Int] = []
    var windowLocations: [CGPoint] = []
    var postAttachAuthMessages: [Bool] = []

    init(postResult: Bool = true, integerFieldResult: Bool = true, windowLocationResult: Bool = true) {
        self.postResult = postResult
        self.integerFieldResult = integerFieldResult
        self.windowLocationResult = windowLocationResult
    }

    func post(_ event: CGEvent, to pid: pid_t, attachAuthMessage: Bool) -> Bool {
        postAttachAuthMessages.append(attachAuthMessage)
        return postResult
    }

    func setWindowLocation(_ event: CGEvent, _ point: CGPoint) -> Bool {
        windowLocations.append(point)
        return windowLocationResult
    }

func setIntegerField(_ event: CGEvent, field: Int, value: Int64) -> Bool {
    integerFields.append(field)
    return integerFieldResult
    }
}
#endif
