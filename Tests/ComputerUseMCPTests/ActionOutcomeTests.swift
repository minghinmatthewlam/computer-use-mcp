import CoreGraphics
import MCP
import Testing

@testable import computer_use_mcp

/// Pure-reducer tests: one per docs/outcome-contract.md §4 matrix row. These
/// lock the classification logic without a live UI — the fixture E2E suite
/// proves the observations feeding it are correct.
@Suite struct ActionOutcomeTests {
    private let axTier = InputTier.accessibilityAction.rawValue      // not droppable
    private let attrTier = InputTier.accessibilityAttribute.rawValue // not droppable
    private let droppableTier = InputTier.perPid.rawValue            // droppable background

    private func reduceClick(
        _ v: ActionVerification, intent: ActionIntent = .activate,
        rereadFailed: Bool = false, tier: String? = nil, hasTargetElement: Bool = true
    ) -> ActionOutcome {
        ActionVerifier.reduce(
            family: .click, intent: intent, verification: v,
            rereadFailed: rereadFailed, dispatchSucceeded: true,
            deliveryTier: tier ?? axTier, hasTargetElement: hasTargetElement)
    }

    // MARK: click

    @Test func clickIntentDerivesCheckboxTransition() {
        #expect(clickIntent(
            role: "AXCheckBox", button: "left", clickCount: 1,
            beforeSelected: false) == .toggle(true))
        #expect(clickIntent(
            role: "AXCheckBox", button: "left", clickCount: 1,
            beforeSelected: true) == .toggle(false))
    }

    @Test func clickIntentDoesNotGuessWhenCheckboxStateIsUnknown() {
        #expect(clickIntent(
            role: "AXCheckBox", button: "left", clickCount: 1,
            beforeSelected: nil) == .activate)
        #expect(clickIntent(
            role: "AXCheckBox", button: "left", clickCount: 2,
            beforeSelected: false) == .activate)
    }

    @Test func clickIntentPreservesFocusAndGenericActivation() {
        #expect(clickIntent(
            role: "AXTextArea", button: "left", clickCount: 1,
            beforeSelected: nil) == .focusTarget)
        #expect(clickIntent(
            role: "AXButton", button: "left", clickCount: 1,
            beforeSelected: nil) == .activate)
        #expect(clickIntent(
            role: "AXCheckBox", button: "right", clickCount: 1,
            beforeSelected: false) == .activate)
    }

    @Test func genericActivationWindowChangeDoesNotClaimBusinessEffect() {
        var v = ActionVerification()
        v.renderedTextChanged = true
        #expect(reduceClick(v).classification == .effectNotVerified)
    }

    @Test func checkboxAlreadyCheckedIsSuccess() {
        // Pre-dispatch already-satisfied: never punish a correct no-op.
        var v = ActionVerification()
        v.beforeSelected = true
        #expect(ActionIntent.toggle(true).alreadySatisfied(by: v))
        let outcome = reduceClick(v, intent: .toggle(true))
        #expect(outcome.classification == .success)
        #expect(outcome.failureDomain == nil)
    }

    @Test func checkboxToggleFlipIsSuccess() {
        var v = ActionVerification()
        v.beforeSelected = false
        v.afterSelected = true
        v.targetStateChanged = true
        let outcome = reduceClick(v, intent: .toggle(true))
        #expect(outcome.classification == .success)
    }

    @Test func liarButtonIsEffectNotVerifiedVerification() {
        // Dispatch ok, reread ok, nothing changed, non-droppable AX tier.
        var v = ActionVerification()
        v.targetStateChanged = false
        v.renderedTextChanged = false
        let outcome = reduceClick(v)
        #expect(outcome.classification == .effectNotVerified)
        #expect(outcome.failureDomain == .verification)
    }

    @Test func droppedBackgroundEventIsTransport() {
        var v = ActionVerification()
        v.targetStateChanged = false
        v.renderedTextChanged = false
        let outcome = reduceClick(v, tier: droppableTier)
        #expect(outcome.classification == .effectNotVerified)
        #expect(outcome.failureDomain == .transport)
    }

    @Test func focusedFieldClickIsSuccess() {
        // Focus/caret is a valid, often invisible, effect.
        var v = ActionVerification()
        v.afterFocused = true
        v.renderedTextChanged = false
        let outcome = reduceClick(v, intent: .focusTarget)
        #expect(outcome.classification == .success)
    }

    @Test func genericActivationRereadFailureWithWindowChangeIsUnverified() {
        var v = ActionVerification()
        v.renderedTextChanged = true
        let outcome = reduceClick(v, rereadFailed: true)
        #expect(outcome.classification == .effectNotVerified)
    }

    @Test func closeControlWindowDisappearancePreservesDeliveryEvidenceWithoutFalseSuccess() {
        let verifier = ActionVerifier(
            family: .click, intent: .activate, deliveryTier: axTier,
            dispatchSucceeded: true, hasTargetElement: true,
            snapshotElement: nil, beforeWindowTitle: "Document")

        let outcome = verifier.missingWindowOutcome()

        #expect(outcome.classification == .verifierAmbiguous)
        #expect(outcome.dispatchSucceeded == true)
        #expect(outcome.verification?.windowTitleChanged == true)
        #expect(outcome.verification?.targetRelocated == true)
    }

    @Test func typeWindowDisappearanceCannotSynthesizeSuccessFromBeforeFields() {
        var before = ActionVerification()
        before.beforeValuePreview = "draft"
        let verifier = ActionVerifier(
            family: .type, intent: .insertText("hello"), deliveryTier: attrTier,
            dispatchSucceeded: true, hasTargetElement: true,
            snapshotElement: nil, before: before,
            beforeWindowTitle: "Document")

        let outcome = verifier.missingWindowOutcome()

        #expect(outcome.classification == .verifierAmbiguous)
        #expect(!outcome.isSuccess)
        #expect(outcome.dispatchSucceeded == true)
        #expect(outcome.verification?.targetRelocated == true)
    }

    @Test func rereadFailedWithoutWindowChangeIsAmbiguousTargeting() {
        var v = ActionVerification()
        v.renderedTextChanged = false
        let outcome = reduceClick(v, rereadFailed: true)
        #expect(outcome.classification == .verifierAmbiguous)
        #expect(outcome.failureDomain == .targeting)
    }

    @Test func coordinateClickNoElementNoChangeIsAmbiguous() {
        // No element to re-read: absence of change is unprovable, not a failure.
        var v = ActionVerification()
        v.renderedTextChanged = false
        let outcome = reduceClick(v, tier: droppableTier, hasTargetElement: false)
        #expect(outcome.classification == .verifierAmbiguous)
        #expect(outcome.failureDomain == .targeting)
    }

    // MARK: unsupported (pre-dispatch, constructed directly)

    @Test func disabledControlIsUnsupported() {
        let outcome = ActionOutcome.unsupported(.unsupported, "disabled")
        #expect(outcome.classification == .unsupported)
        #expect(outcome.failureDomain == .unsupported)
    }

    @Test func nonNumericIntoNumericIsCoercion() {
        let outcome = ActionOutcome.unsupported(.coercion, "not a number")
        #expect(outcome.classification == .unsupported)
        #expect(outcome.failureDomain == .coercion)
    }

    // MARK: type_text

    @Test func typedTextPresentIsSuccess() {
        var v = ActionVerification()
        v.afterValuePreview = "say hello world"
        let outcome = ActionVerifier.reduce(
            family: .type, intent: .insertText("hello"), verification: v,
            rereadFailed: false, dispatchSucceeded: true, deliveryTier: attrTier, hasTargetElement: true)
        #expect(outcome.classification == .success)
    }

    @Test func typedTextReflectedInSeparateReadoutIsSuccess() {
        // Fixture keystroke-input: the acted element's value is read-only, but
        // the echo readout changes the tree — that is the confirming signal.
        var v = ActionVerification()
        v.afterValuePreview = ""
        v.renderedTextChanged = true
        let outcome = ActionVerifier.reduce(
            family: .type, intent: .insertText("hi"), verification: v,
            rereadFailed: false, dispatchSucceeded: true, deliveryTier: droppableTier, hasTargetElement: true)
        #expect(outcome.classification == .success)
    }

    @Test func typedTextIgnoredIsEffectNotVerified() {
        var v = ActionVerification()
        v.beforeValuePreview = "unrelated"
        v.afterValuePreview = "unrelated"
        v.renderedTextChanged = false
        let outcome = ActionVerifier.reduce(
            family: .type, intent: .insertText("hello"), verification: v,
            rereadFailed: false, dispatchSucceeded: true, deliveryTier: attrTier, hasTargetElement: true)
        #expect(outcome.classification == .effectNotVerified)
        #expect(outcome.failureDomain == .verification)
    }

    @Test func webAXEchoBareTypeTextIsEffectNotVerifiedWeb() {
        var v = ActionVerification()
        v.beforeValuePreview = ""
        v.afterValuePreview = "hello"
        v.targetStateChanged = true
        v.renderedTextChanged = true
        v.targetInWebArea = true
        v.independentElementChanged = false
        let outcome = ActionVerifier.reduce(
            family: .type, intent: .insertText("hello"), verification: v,
            rereadFailed: false, dispatchSucceeded: true, deliveryTier: attrTier, hasTargetElement: true)
        #expect(outcome.classification == .effectNotVerified)
        #expect(outcome.failureDomain == .web)
        #expect(outcome.webAXEchoRisk)
    }

    @Test func webAXEchoSyntheticKeystrokeDeliveryIsNotDowngraded() {
        var v = ActionVerification()
        v.beforeValuePreview = ""
        v.afterValuePreview = "hello"
        v.targetStateChanged = true
        v.renderedTextChanged = true
        v.targetInWebArea = true
        v.independentElementChanged = false
        let outcome = ActionVerifier.reduce(
            family: .type, intent: .insertText("hello"), verification: v,
            rereadFailed: false, dispatchSucceeded: true, deliveryTier: droppableTier, hasTargetElement: true)
        #expect(outcome.classification == .success)
        #expect(!outcome.webAXEchoRisk)
    }

    @Test func focusedWebAXTypeWindowChangeWithoutIndependentDiffIsDowngraded() {
        var v = ActionVerification()
        v.renderedTextChanged = true
        v.targetInWebArea = true
        v.independentElementChanged = false
        let outcome = ActionVerifier.reduce(
            family: .type, intent: .insertText("hello"), verification: v,
            rereadFailed: false, dispatchSucceeded: true, deliveryTier: attrTier, hasTargetElement: false)
        #expect(outcome.classification == .effectNotVerified)
        #expect(outcome.failureDomain == .web)
        #expect(outcome.webAXEchoRisk)
    }

    @Test func webAXEchoTextMatchingIndependentDiffEarnsSuccess() {
        var v = ActionVerification()
        v.beforeValuePreview = ""
        v.afterValuePreview = "hello"
        v.targetStateChanged = true
        v.renderedTextChanged = true
        v.targetInWebArea = true
        v.independentElementChanged = true
        let outcome = ActionVerifier.reduce(
            family: .type, intent: .insertText("hello"), verification: v,
            rereadFailed: false, dispatchSucceeded: true, deliveryTier: attrTier, hasTargetElement: true)
        #expect(outcome.classification == .success)
        #expect(!outcome.webAXEchoRisk)
    }

    @Test func webAXEchoNonMatchingIndependentChurnIsDowngraded() {
        var v = ActionVerification()
        v.beforeValuePreview = ""
        v.afterValuePreview = "hello"
        v.targetStateChanged = true
        v.renderedTextChanged = true
        v.targetInWebArea = true
        v.independentElementChanged = false
        let outcome = ActionVerifier.reduce(
            family: .type, intent: .insertText("hello"), verification: v,
            rereadFailed: false, dispatchSucceeded: true, deliveryTier: attrTier, hasTargetElement: true)
        #expect(outcome.classification == .effectNotVerified)
        #expect(outcome.failureDomain == .web)
        #expect(outcome.webAXEchoRisk)
    }

    @Test func nonWebAXValueEchoIsNotDowngraded() {
        var v = ActionVerification()
        v.beforeValuePreview = ""
        v.afterValuePreview = "hello"
        v.targetStateChanged = true
        v.renderedTextChanged = true
        v.targetInWebArea = false
        v.independentElementChanged = false
        let outcome = ActionVerifier.reduce(
            family: .type, intent: .insertText("hello"), verification: v,
            rereadFailed: false, dispatchSucceeded: true, deliveryTier: attrTier, hasTargetElement: true)
        #expect(outcome.classification == .success)
        #expect(!outcome.webAXEchoRisk)
    }

    @Test func secureFieldTypeIsAmbiguous() {
        var v = ActionVerification()
        v.afterValuePreview = nil  // never read a secure field
        v.renderedTextChanged = false
        let outcome = ActionVerifier.reduce(
            family: .type, intent: .insertText("pw"), verification: v,
            rereadFailed: false, dispatchSucceeded: true, deliveryTier: attrTier, hasTargetElement: true)
        #expect(outcome.classification == .verifierAmbiguous)
    }

    // MARK: set_value

    @Test func sliderInRangeIsSuccess() {
        var v = ActionVerification()
        v.afterValuePreview = "50"
        let outcome = ActionVerifier.reduce(
            family: .setValue, intent: .setNumber(50), verification: v,
            rereadFailed: false, dispatchSucceeded: true, deliveryTier: attrTier, hasTargetElement: true)
        #expect(outcome.classification == .success)
        #expect(outcome.failureDomain == nil)
    }

    @Test func sliderSnapToStepIsAppSpecificSemantics() {
        var v = ActionVerification()
        v.afterValuePreview = "49.6"
        let outcome = ActionVerifier.reduce(
            family: .setValue, intent: .setNumber(50), verification: v,
            rereadFailed: false, dispatchSucceeded: true, deliveryTier: attrTier, hasTargetElement: true)
        #expect(outcome.classification == .success)
        #expect(outcome.failureDomain == .appSpecificSemantics)
    }

    @Test func setValueRejectedIsEffectNotVerified() {
        var v = ActionVerification()
        v.beforeValuePreview = "bar"
        v.afterValuePreview = "bar"
        let outcome = ActionVerifier.reduce(
            family: .setValue, intent: .setText("foo"), verification: v,
            rereadFailed: false, dispatchSucceeded: true, deliveryTier: attrTier, hasTargetElement: true)
        #expect(outcome.classification == .effectNotVerified)
        #expect(outcome.failureDomain == .verification)
    }

    @Test func webAXEchoBareSetValueIsEffectNotVerifiedWeb() {
        var v = ActionVerification()
        v.beforeValuePreview = "old"
        v.afterValuePreview = "new"
        v.targetStateChanged = true
        v.renderedTextChanged = true
        v.targetInWebArea = true
        v.independentElementChanged = false
        let outcome = ActionVerifier.reduce(
            family: .setValue, intent: .setText("new"), verification: v,
            rereadFailed: false, dispatchSucceeded: true, deliveryTier: attrTier, hasTargetElement: true)
        #expect(outcome.classification == .effectNotVerified)
        #expect(outcome.failureDomain == .web)
        #expect(outcome.webAXEchoRisk)
    }

    @Test func checkboxSetValueAlreadyInStateIsSuccess() {
        var v = ActionVerification()
        v.beforeSelected = true
        #expect(ActionIntent.toggle(true).alreadySatisfied(by: v))
        let outcome = ActionVerifier.reduce(
            family: .setValue, intent: .toggle(true), verification: v,
            rereadFailed: false, dispatchSucceeded: true, deliveryTier: axTier, hasTargetElement: true)
        #expect(outcome.classification == .success)
    }

    // MARK: scroll

    @Test func scrollMovesContentIsSuccess() {
        var v = ActionVerification()
        v.scrollPositionChanged = true
        let outcome = ActionVerifier.reduce(
            family: .scroll, intent: .scrollContent, verification: v,
            rereadFailed: false, dispatchSucceeded: true, deliveryTier: droppableTier, hasTargetElement: false)
        #expect(outcome.classification == .success)
    }

    @Test func scrollVisibleContentMovementIsSuccess() {
        var v = ActionVerification()
        v.scrollPositionChanged = false
        v.scrollContentChanged = true
        let outcome = ActionVerifier.reduce(
            family: .scroll, intent: .scrollContent, verification: v,
            rereadFailed: false, dispatchSucceeded: true, deliveryTier: droppableTier, hasTargetElement: false)
        #expect(outcome.classification == .success)
    }

    @Test func scrollUnrelatedWindowChangeIsNotSuccess() {
        var v = ActionVerification()
        v.renderedTextChanged = true
        v.scrollPositionChanged = false
        v.scrollContentChanged = false
        let outcome = ActionVerifier.reduce(
            family: .scroll, intent: .scrollContent, verification: v,
            rereadFailed: false, dispatchSucceeded: true, deliveryTier: droppableTier, hasTargetElement: false)
        #expect(outcome.classification == .effectNotVerified)
        #expect(outcome.failureDomain == .transport)
    }

    @Test func scrollAtExtentIsSuccess() {
        var v = ActionVerification()
        v.scrollPositionChanged = false
        v.renderedTextChanged = false
        v.scrollAtExtent = true
        let outcome = ActionVerifier.reduce(
            family: .scroll, intent: .scrollContent, verification: v,
            rereadFailed: false, dispatchSucceeded: true, deliveryTier: droppableTier, hasTargetElement: false)
        #expect(outcome.classification == .success)
    }

    @Test func scrollDroppedIsTransport() {
        var v = ActionVerification()
        v.scrollPositionChanged = false
        v.renderedTextChanged = false
        v.scrollAtExtent = false
        let outcome = ActionVerifier.reduce(
            family: .scroll, intent: .scrollContent, verification: v,
            rereadFailed: false, dispatchSucceeded: true, deliveryTier: droppableTier, hasTargetElement: false)
        #expect(outcome.classification == .effectNotVerified)
        #expect(outcome.failureDomain == .transport)
        #expect(outcome.summary.contains("no content movement was observed"))
        #expect(outcome.summary.contains("PageDown/PageUp"))
    }

    // MARK: manage_window

    @Test func windowResizeClampedIsAppSpecificSemantics() {
        let outcome = ActionVerifier.windowOutcome(
            action: "resize", requestedWidth: 2000, requestedHeight: 2000,
            requestedX: nil, requestedY: nil,
            before: CGRect(x: 0, y: 0, width: 800, height: 600),
            after: CGRect(x: 0, y: 0, width: 1200, height: 760))
        #expect(outcome.classification == .success)
        #expect(outcome.failureDomain == .appSpecificSemantics)
    }

    @Test func windowResizeReachedRequestIsCleanSuccess() {
        let outcome = ActionVerifier.windowOutcome(
            action: "resize", requestedWidth: 800, requestedHeight: 700,
            requestedX: nil, requestedY: nil,
            before: CGRect(x: 0, y: 0, width: 400, height: 400),
            after: CGRect(x: 0, y: 0, width: 800, height: 700))
        #expect(outcome.classification == .success)
        #expect(outcome.failureDomain == nil)
    }

    @Test func windowDidNotResizeIsEffectNotVerified() {
        let outcome = ActionVerifier.windowOutcome(
            action: "resize", requestedWidth: 2000, requestedHeight: 2000,
            requestedX: nil, requestedY: nil,
            before: CGRect(x: 0, y: 0, width: 500, height: 500),
            after: CGRect(x: 0, y: 0, width: 500, height: 500))
        #expect(outcome.classification == .effectNotVerified)
        #expect(outcome.failureDomain == .verification)
    }

    // MARK: menu

    @Test func menuWindowChangeIsSuccess() {
        var v = ActionVerification()
        v.renderedTextChanged = true
        let outcome = ActionVerifier.reduce(
            family: .menu, intent: .openMenu, verification: v,
            rereadFailed: false, dispatchSucceeded: true, deliveryTier: axTier, hasTargetElement: false)
        #expect(outcome.classification == .success)
    }

    @Test func menuNoObservableChangeIsAmbiguous() {
        let v = ActionVerification()
        let outcome = ActionVerifier.reduce(
            family: .menu, intent: .openMenu, verification: v,
            rereadFailed: false, dispatchSucceeded: true, deliveryTier: axTier, hasTargetElement: false)
        #expect(outcome.classification == .verifierAmbiguous)
    }

    // MARK: serialization

    @Test func outcomeSerializesClassificationDomainAndVerification() {
        var v = ActionVerification()
        v.beforeSelected = false
        v.afterSelected = true
        v.targetStateChanged = true
        let outcome = ActionOutcome.success("Toggled on.", v)
        guard case let .object(fields) = outcome.value else {
            Issue.record("expected object")
            return
        }
        #expect(fields["classification"]?.stringValue == "success")
        #expect(fields["failure_domain"] == nil)  // omitted when nil
        #expect(fields["summary"]?.stringValue == "Toggled on.")
        guard case let .object(verification)? = fields["verification"] else {
            Issue.record("expected verification object")
            return
        }
        #expect(verification["before_selected"]?.boolValue == false)
        #expect(verification["after_selected"]?.boolValue == true)
        // nil fields are omitted, not serialized as false.
        #expect(verification["before_focused"] == nil)
    }

    @Test func effectNotVerifiedSerializesFailureDomain() {
        let outcome = ActionOutcome.effectNotVerified(.transport, "dropped")
        guard case let .object(fields) = outcome.value else {
            Issue.record("expected object")
            return
        }
        #expect(fields["classification"]?.stringValue == "effect_not_verified")
        #expect(fields["failure_domain"]?.stringValue == "transport")
    }

    @Test func webAXEchoRiskSerializesAtOutcomeTopLevel() {
        let outcome = ActionOutcome(
            classification: .effectNotVerified,
            failureDomain: .web,
            summary: "web echo",
            verification: nil,
            webAXEchoRisk: true)
        guard case let .object(fields) = outcome.value else {
            Issue.record("expected object")
            return
        }
        #expect(fields["failure_domain"]?.stringValue == "web")
        #expect(fields["web_ax_echo_risk"]?.boolValue == true)
    }

    @Test func withActionOutcomeAttachesMetaBlock() {
        let outcome = ActionOutcome.success("ok")
        let result = CallTool.Result.text("done").withActionOutcome(outcome)
        #expect(result._meta?["computer-use-mcp/outcome"] != nil)
    }

    @Test func nonSuccessOutcomeHasHumanSentenceSuccessDoesNot() {
        #expect(ActionOutcome.success("fine").humanSentence == nil)
        #expect(ActionOutcome.effectNotVerified(.verification, "no change").humanSentence == "no change")
    }
}
