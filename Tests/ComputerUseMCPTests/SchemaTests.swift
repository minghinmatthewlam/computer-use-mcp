import MCP
import Testing

@testable import computer_use_mcp

private func toolSpec(_ name: String) throws -> ToolSpec {
    guard let spec = toolCatalog.first(where: { $0.name == name }) else {
        throw ToolError.failed("Missing tool spec \(name).")
    }
    return spec
}

private func objectValue(_ value: Value) throws -> [String: Value] {
    guard case let .object(object) = value else {
        throw ToolError.failed("Expected object value.")
    }
    return object
}

private func schemaProperty(_ property: String, in toolName: String) throws -> Value {
    let schema = try objectValue(try toolSpec(toolName).inputSchema)
    let properties = try objectValue(schema["properties"] ?? .object([:]))
    guard let value = properties[property] else {
        throw ToolError.failed("\(toolName) schema is missing \(property).")
    }
    return value
}

private func schemaType(_ value: Value) throws -> String {
    let object = try objectValue(value)
    guard let type = object["type"]?.stringValue else {
        throw ToolError.failed("Schema property is missing type.")
    }
    return type
}

private func schemaEnum(_ value: Value) throws -> [String] {
    let object = try objectValue(value)
    guard case let .array(values)? = object["enum"] else {
        throw ToolError.failed("Schema property is missing enum values.")
    }
    return values.compactMap(\.stringValue)
}

private func requiredProperties(for toolName: String) throws -> [String] {
    let schema = try objectValue(try toolSpec(toolName).inputSchema)
    guard case let .array(required)? = schema["required"] else {
        return []
    }
    return required.compactMap(\.stringValue)
}

@Suite struct SchemaTests {
    @Test func everyRegisteredToolHasAnnotations() {
        #expect(!toolCatalog.isEmpty)
        for spec in toolCatalog {
            #expect(!spec.annotations.isEmpty, "\(spec.name) is missing MCP tool annotations")
            #expect(spec.tool.annotations == spec.annotations)
        }
    }

    @Test func toolAnnotationsCoverInterestingClassifications() throws {
        let getAppState = try toolSpec("get_app_state").annotations
        #expect(getAppState.readOnlyHint == true)
        #expect(getAppState.destructiveHint == false)
        #expect(getAppState.idempotentHint == true)
        #expect(getAppState.openWorldHint == true)

        let click = try toolSpec("click").annotations
        #expect(click.readOnlyHint == false)
        #expect(click.destructiveHint == true)
        #expect(click.idempotentHint == false)
        #expect(click.openWorldHint == true)

        let setValue = try toolSpec("set_value").annotations
        #expect(setValue.readOnlyHint == false)
        #expect(setValue.idempotentHint == false)

        let openApp = try toolSpec("open_app").annotations
        #expect(openApp.readOnlyHint == false)
        #expect(openApp.destructiveHint == false)
        #expect(openApp.idempotentHint == true)
        #expect(openApp.openWorldHint == true)

        let openURL = try toolSpec("open_url").annotations
        #expect(openURL.readOnlyHint == false)
        #expect(openURL.idempotentHint == false)
        #expect(openURL.openWorldHint == true)

        let deleteSkill = try toolSpec("delete_skill").annotations
        #expect(deleteSkill.readOnlyHint == false)
        #expect(deleteSkill.destructiveHint == true)
        #expect(deleteSkill.idempotentHint == false)
        #expect(deleteSkill.openWorldHint == false)
    }

    @Test func secondaryActionAcceptsConfirmArgument() throws {
        #expect(try schemaType(schemaProperty("confirm", in: "perform_secondary_action")) == "boolean")
    }

    @Test func manageWindowAcceptsConfirmArgument() throws {
        #expect(try schemaType(schemaProperty("confirm", in: "manage_window")) == "boolean")
    }

    @Test func systemToolsExposeConfirmArgument() throws {
        #expect(try schemaType(schemaProperty("confirm", in: "open_app")) == "boolean")
        #expect(try schemaType(schemaProperty("confirm", in: "write_clipboard")) == "boolean")
    }

    @Test func getAppStateExposesScreenshotOptOut() throws {
        #expect(try schemaType(schemaProperty("include_screenshot", in: "get_app_state")) == "boolean")
    }

    @Test func stateReturningMutationToolsExposeResponseMode() throws {
        for toolName in stateResponseModeToolNames.sorted() {
            #expect(
                try schemaEnum(schemaProperty("state_response_mode", in: toolName))
                    == ["auto", "full"],
                "\(toolName) must expose the shared state response mode enum")
        }
    }

    @Test func manageWindowKeepsRequiredContractNarrow() throws {
        #expect(try requiredProperties(for: "manage_window") == ["app", "action"])
    }

    @Test func clickExposesFocusChangeOptInForGlobalCursorEscalation() throws {
        #expect(try schemaType(schemaProperty("allow_global_cursor", in: "click")) == "boolean")
        #expect(try schemaType(schemaProperty("allow_focus_change", in: "click")) == "boolean")
    }

    @Test func pressKeyExposesFocusChangeOptInForGlobalKeyboardEscalation() throws {
        #expect(try schemaType(schemaProperty("allow_global_keyboard", in: "press_key")) == "boolean")
        #expect(try schemaType(schemaProperty("allow_global_cursor", in: "press_key")) == "boolean")
        #expect(try schemaType(schemaProperty("allow_focus_change", in: "press_key")) == "boolean")
    }

    @Test func saveSkillStepEnumerationIncludesReadText() throws {
        let steps = try objectValue(try schemaProperty("steps", in: "save_skill"))
        let description = steps["description"]?.stringValue ?? ""
        #expect(description.contains("read_text"))
        for name in skillStepToolNames.sorted() {
            #expect(description.contains(name), "save_skill steps should list \(name)")
        }
    }

    @Test func batchActionsItemsExposeToolProperty() throws {
        let actions = try objectValue(try schemaProperty("actions", in: "batch"))
        let items = try objectValue(actions["items"] ?? .null)
        #expect(try schemaType(.object(items)) == "object")
        let properties = try objectValue(items["properties"] ?? .object([:]))
        #expect(properties["tool"] != nil)
        #expect(items["description"]?.stringValue?.contains("tool") == true)
        guard case let .array(required)? = items["required"] else {
            throw ToolError.failed("batch actions.items is missing required")
        }
        #expect(required.compactMap(\.stringValue) == ["tool"])
    }

    @Test func pageToolExposesSelectorActionAndVerificationArguments() throws {
        #expect(try schemaType(schemaProperty("selector", in: "page")) == "string")
        #expect(try schemaType(schemaProperty("action", in: "page")) == "string")
        #expect(try schemaType(schemaProperty("verify_selector", in: "page")) == "string")
        #expect(try schemaType(schemaProperty("cdp_port", in: "page")) == "integer")
        #expect(try requiredProperties(for: "page") == ["app", "selector"])
    }

    @Test func focusMutatingSystemToolsExposeFocusChangeOptIn() throws {
        #expect(try schemaType(schemaProperty("allow_focus_change", in: "open_url")) == "boolean")
        #expect(try schemaType(schemaProperty("allow_focus_change", in: "manage_window")) == "boolean")
    }
}
