// The tool catalog: the public, model-facing surface of computer-use-mcp.
//
// Conventions shared by every interaction tool:
// - `app` targets a running app by name or bundle identifier (app-scoped control).
// - Elements are addressed by `element_id` from the latest get_app_state result.
// - Coordinate parameters (`x`, `y`, ...) are pixel coordinates in the most recent
//   screenshot returned for that app, used as the fallback when an element is not
//   exposed in the accessibility tree.
// - Every interaction returns fresh app state (accessibility tree + screenshot) so
//   the agent can verify the effect of its action before acting again.

import MCP

private let appParam = stringParam(
    "Target app, by name (e.g. \"Notes\") or bundle identifier (e.g. \"com.apple.Notes\")."
)

private let elementIDParam = stringParam(
    "Element id from the latest get_app_state result. Prefer this over coordinates."
)

private let allowGlobalCursorParam = boolParam(
    "Escape hatch (default false). When true, uses the real system cursor to deliver "
        + "the action — this MOVES the pointer and may change focus. Only set it if "
        + "background delivery did not land for a stubborn app. Requires allow_focus_change:true."
)

private let allowFocusChangeParam = boolParam(
    "Default false. Set true only when you explicitly allow this call to change "
        + "the user's foreground app/focus. The result metadata reports whether focus changed."
)

private let allowGlobalKeyboardParam = boolParam(
    "Escape hatch (default false). When true, allows global keyboard delivery only "
        + "when the target app is already foreground. Use only if per-app delivery "
        + "did not land for a stubborn app. Requires allow_focus_change:true because "
        + "global shortcuts can change foreground focus. Preferred name: "
        + "allow_global_keyboard (allow_global_cursor is accepted as a wire-compat alias)."
)

private let allowGlobalKeyboardAliasParam = boolParam(
    "Preferred escape hatch for press_key global delivery (default false). Same meaning "
        + "as allow_global_cursor on this tool. Requires allow_focus_change:true."
)

private let confirmParam = boolParam(
    "Set true to confirm a potentially destructive or irreversible action (e.g. a "
        + "Delete button, typing into a password field, or an app on the confirmation "
        + "list). Required only when the server flags the action; the error says so."
)

private let includeScreenshotParam = boolParam(
    "Default true. Set false to omit the screenshot from the returned state — faster "
        + "and cheaper. The accessibility tree is always returned; call get_app_state "
        + "when you need full-resolution pixels again."
)

private let includeStateParam = boolParam(
    "Default true. Set false to return only a confirmation note — no tree, no screenshot. "
        + "The fastest mode for chained actions; call get_app_state when you need state again."
)

private let stateResponseModeParam = enumParam(
    ["auto", "full"],
    "Controls returned state text only. auto (default) returns unchanged, compact diff, or full tree "
        + "using normal selection; full always returns the full tree. Screenshot capture and state "
        + "generation are unchanged. Cannot be used with include_state:false."
)

private let readOnlyLocalAnnotations = Tool.Annotations(
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: false
)

private let readOnlyAppAnnotations = Tool.Annotations(
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: true
)

private let nondestructiveAppActionAnnotations = Tool.Annotations(
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: false,
    openWorldHint: true
)

private let destructiveAppActionAnnotations = Tool.Annotations(
    readOnlyHint: false,
    destructiveHint: true,
    idempotentHint: false,
    openWorldHint: true
)

private let openAppAnnotations = Tool.Annotations(
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: true
)

private let openURLAnnotations = Tool.Annotations(
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: false,
    openWorldHint: true
)

private let writeClipboardAnnotations = Tool.Annotations(
    readOnlyHint: false,
    destructiveHint: true,
    idempotentHint: true,
    openWorldHint: false
)

private let skillWriteAnnotations = Tool.Annotations(
    readOnlyHint: false,
    destructiveHint: true,
    idempotentHint: false,
    openWorldHint: false
)

private let recorderAnnotations = Tool.Annotations(
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: false,
    openWorldHint: true
)

let toolCatalog: [ToolSpec] = [
    ToolSpec(
        name: "list_apps",
        description: """
            List the currently-running apps that can be controlled, plus installed apps \
            for reference. Only running apps can be controlled — an installed app must be \
            opened first. Call this first when the target app is unknown or ambiguous.
            """,
        inputSchema: objectSchema([:]),
        annotations: readOnlyAppAnnotations,
        handler: { args in try await listApps(args) }
    ),
    ToolSpec(
        name: "get_app_state",
        description: """
            Get the current state of an app: its accessibility tree (elements with ids, \
            roles, labels, values, and pixel bounding boxes) plus a screenshot of its \
            front window. You MUST call this before interacting with an app, and use the \
            element ids and screenshot coordinates it returns. State changes after every \
            action, so never reuse ids or coordinates from before an action.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "window_title": stringParam(
                    "Optional window title to target a specific window. Defaults to the app's front window."
                ),
                "scope_element_id": stringParam(
                    "Optional container element id: return the tree for just that subtree, with the "
                        + "full element budget. Use when the whole-window tree was truncated."
                ),
                "max_elements": integerParam(
                    "Maximum elements in the returned tree (default 500, cap 5000). Raise for large windows."
                ),
                "skeleton": boolParam(
                    "Default false. Set true for a shallow overview of a large or unfamiliar window: "
                        + "deep containers are collapsed to a single line with children_count and stay "
                        + "drill targets — pass one such container's id as scope_element_id to expand it. "
                        + "Cuts tokens on big trees; ignored when scope_element_id is set."
                ),
                "ocr": boolParam(
                    "Default false. Set true to also OCR the screenshot and return recognized text "
                        + "with pixel boxes — the fallback for apps whose accessibility tree is "
                        + "missing or sparse (custom-drawn UIs, games, remote desktops)."
                ),
                "include_screenshot": boolParam(
                    "Default true. Set false for a tree-only read — faster and cheaper when "
                        + "pixels are not needed."
                ),
            ],
            required: ["app"]
        ),
        annotations: readOnlyAppAnnotations,
        handler: { args in try await getAppState(args) }
    ),
    ToolSpec(
        name: "find",
        description: """
            Search a window's accessibility tree for elements matching a text query — \
            the fast way to locate a control without reading the whole tree. Searches \
            deeper than get_app_state returns (up to 5000 elements) and matches labels, \
            values, and roles, case-insensitively. Returned element ids are fresh and \
            directly usable in action tools.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "query": stringParam("Substring to search for in element labels, values, and roles."),
                "role": stringParam("Optional exact role filter, e.g. \"AXButton\"."),
                "max_results": integerParam("Maximum matches to return (default 20, cap 100)."),
                "window_title": stringParam(
                    "Optional window title to target a specific window. Defaults to the app's front window."
                ),
            ],
            required: ["app", "query"]
        ),
        annotations: readOnlyAppAnnotations,
        handler: { args in try await find(args) }
    ),
    ToolSpec(
        name: "click",
        description: """
            Click an element by id, or by screenshot pixel coordinates when the target \
            is not in the accessibility tree. Runs in the background: the user's real \
            cursor and focus are not disturbed. Returns fresh app state.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "element_id": elementIDParam,
                "x": numberParam("X pixel coordinate in the latest screenshot (fallback when no element_id)."),
                "y": numberParam("Y pixel coordinate in the latest screenshot (fallback when no element_id)."),
                "click_count": integerParam(
                    "Number of clicks: 1 (default) or \(ArgumentBounds.maxClickCount) for double-click."
                ),
                "mouse_button": enumParam(["left", "right", "middle"], "Mouse button. Defaults to left."),
                "allow_global_cursor": allowGlobalCursorParam,
                "allow_focus_change": allowFocusChangeParam,
                "include_screenshot": includeScreenshotParam,
                "include_state": includeStateParam,
                "state_response_mode": stateResponseModeParam,
                "confirm": confirmParam,
            ],
            required: ["app"]
        ),
        annotations: destructiveAppActionAnnotations,
        handler: { args in try await click(args) }
    ),
    ToolSpec(
        name: "type_text",
        description: """
            Type literal text into an editable element (by id), or into the app's \
            focused field when no element is given. Inserts at the current selection. \
            Returns fresh app state — verify the field's new value in it.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "element_id": elementIDParam,
                "text": stringParam("Literal text to type. Maximum \(ArgumentBounds.maxTypeTextCharacters) characters."),
                "include_screenshot": includeScreenshotParam,
                "include_state": includeStateParam,
                "state_response_mode": stateResponseModeParam,
                "confirm": confirmParam,
            ],
            required: ["app", "text"]
        ),
        annotations: destructiveAppActionAnnotations,
        handler: { args in try await typeText(args) }
    ),
    ToolSpec(
        name: "press_key",
        description: """
            Press a key or key combination, using xdotool key syntax: a single key \
            (\"Return\", \"Tab\", \"Escape\", \"Up\", \"F5\", \"a\") or modifiers joined \
            with \"+\" (\"cmd+s\", \"cmd+shift+t\", \"ctrl+a\"). Use for shortcuts and \
            navigation; use type_text for entering text. Returns fresh app state.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "key": stringParam("Key or combination in xdotool syntax, e.g. \"Return\", \"cmd+n\"."),
                "allow_global_keyboard": allowGlobalKeyboardAliasParam,
                // Wire-compat alias: handlers accept allow_global_cursor with the same meaning.
                "allow_global_cursor": allowGlobalKeyboardParam,
                "allow_focus_change": allowFocusChangeParam,
                "include_screenshot": includeScreenshotParam,
                "include_state": includeStateParam,
                "state_response_mode": stateResponseModeParam,
                "confirm": confirmParam,
            ],
            required: ["app", "key"]
        ),
        annotations: destructiveAppActionAnnotations,
        handler: { args in try await pressKey(args) }
    ),
    ToolSpec(
        name: "scroll",
        description: """
            Scroll within a scrollable element (by id) or at screenshot coordinates. \
            Positive delta_y scrolls content up (wheel down). Returns fresh app state.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "element_id": elementIDParam,
                "x": numberParam("X pixel coordinate in the latest screenshot (fallback when no element_id)."),
                "y": numberParam("Y pixel coordinate in the latest screenshot (fallback when no element_id)."),
                "direction": enumParam(
                    ["up", "down", "left", "right"],
                    "Semantic scroll direction (sized from the element; combine with pages). "
                        + "Alternative to raw deltas."
                ),
                "pages": numberParam(
                    "How many element-heights/widths to scroll with direction (default 1, max \(Int(ArgumentBounds.maxScrollPages)))."
                ),
                "delta_x": integerParam(
                    "Horizontal scroll amount in pixels (alternative to direction, max +/-\(ArgumentBounds.maxScrollDelta))."
                ),
                "delta_y": integerParam(
                    "Vertical scroll amount in pixels (alternative to direction, max +/-\(ArgumentBounds.maxScrollDelta))."
                ),
                "include_screenshot": includeScreenshotParam,
                "include_state": includeStateParam,
                "state_response_mode": stateResponseModeParam,
                "confirm": confirmParam,
            ],
            required: ["app"]
        ),
        annotations: nondestructiveAppActionAnnotations,
        handler: { args in try await scroll(args) }
    ),
    ToolSpec(
        name: "drag",
        description: """
            Drag from one point to another, in screenshot pixel coordinates. Use for \
            sliders, reordering, selection rectangles, and drag-and-drop within an app. \
            Returns fresh app state.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "from_x": numberParam("Start X pixel coordinate in the latest screenshot."),
                "from_y": numberParam("Start Y pixel coordinate in the latest screenshot."),
                "to_x": numberParam("End X pixel coordinate in the latest screenshot."),
                "to_y": numberParam("End Y pixel coordinate in the latest screenshot."),
                "include_screenshot": includeScreenshotParam,
                "include_state": includeStateParam,
                "state_response_mode": stateResponseModeParam,
                "confirm": confirmParam,
            ],
            required: ["app", "from_x", "from_y", "to_x", "to_y"]
        ),
        annotations: destructiveAppActionAnnotations,
        handler: { args in try await drag(args) }
    ),
    ToolSpec(
        name: "set_value",
        description: """
            Set the complete value of an element directly (text fields, sliders, \
            checkboxes, pickers). Replaces the current value — faster and more reliable \
            than clicking and typing when the element supports it. Returns fresh app state.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "element_id": elementIDParam,
                "value": stringParam(
                    "New value. For checkboxes use \"true\"/\"false\"; for sliders a number. "
                        + "Maximum \(ArgumentBounds.maxSetValueCharacters) characters."
                ),
                "include_screenshot": includeScreenshotParam,
                "include_state": includeStateParam,
                "state_response_mode": stateResponseModeParam,
                "confirm": confirmParam,
            ],
            required: ["app", "element_id", "value"]
        ),
        annotations: destructiveAppActionAnnotations,
        handler: { args in try await setValue(args) }
    ),
    ToolSpec(
        name: "select_text",
        description: """
            Select a range of text inside a text element so it can be replaced, copied, \
            or styled. Provide the exact text to select as it appears in the element's \
            value in the accessibility tree. Returns fresh app state.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "element_id": elementIDParam,
                "text": stringParam("Exact text to select, as it appears in the element's current value."),
                "occurrence": integerParam("Which occurrence to select when the text appears multiple times (1-based, default 1)."),
                "position": enumParam(
                    ["select", "before", "after"],
                    "select the text (default), or collapse the cursor before/after it for inserting with type_text."
                ),
                "include_screenshot": includeScreenshotParam,
                "include_state": includeStateParam,
                "state_response_mode": stateResponseModeParam,
            ],
            required: ["app", "element_id", "text"]
        ),
        annotations: Tool.Annotations(
            readOnlyHint: false,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: true
        ),
        handler: { args in try await selectText(args) }
    ),
    ToolSpec(
        name: "perform_secondary_action",
        description: """
            Perform an element's secondary action: open its context menu \
            (right-click equivalent) or another accessibility action it exposes, such \
            as AXShowMenu, AXConfirm, AXIncrement, or AXDecrement. Returns fresh app state.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "element_id": elementIDParam,
                "action": stringParam(
                    "Accessibility action to perform. Defaults to AXShowMenu (context menu)."
                ),
                "include_screenshot": includeScreenshotParam,
                "include_state": includeStateParam,
                "state_response_mode": stateResponseModeParam,
                "confirm": confirmParam,
            ],
            required: ["app", "element_id"]
        ),
        annotations: destructiveAppActionAnnotations,
        handler: { args in try await performSecondaryAction(args) }
    ),
    ToolSpec(
        name: "open_app",
        description: """
            Open (launch) an app so it can be controlled, without stealing focus unless \
            activate is true. Accepts an app name, bundle id, or .app path. If the app is \
            already running this is a no-op (plus optional activation). Returns fresh app state.
            """,
        inputSchema: objectSchema(
            [
                "app": stringParam("App name (e.g. \"Notes\"), bundle id, or full .app path."),
                "activate": boolParam(
                    "Default false. When true, brings the app to the foreground — this changes the user's focus."
                ),
                "confirm": confirmParam,
            ],
            required: ["app"]
        ),
        annotations: openAppAnnotations,
        handler: { args in try await openApp(args) }
    ),
    ToolSpec(
        name: "open_url",
        description: """
            Open a URL or file path with its default handler (browser, document app, …). \
            Local files and non-http(s) schemes require confirm:true because they can \
            launch apps or trigger arbitrary handlers. Requires allow_focus_change:true \
            because LaunchServices may activate the handling app.
            """,
        inputSchema: objectSchema(
            [
                "url": stringParam("URL (https://…, file://…, app schemes) or an existing file path."),
                "allow_focus_change": allowFocusChangeParam,
                "confirm": confirmParam,
            ],
            required: ["url"]
        ),
        annotations: openURLAnnotations,
        handler: { args in try await openURL(args) }
    ),
    ToolSpec(
        name: "list_windows",
        description: """
            List every window of an app — including dialogs, floating panels, and \
            minimized windows — with titles, frames, and which one is focused. Use when an \
            app has multiple windows, a save dialog appeared, or get_app_state shows the \
            wrong window.
            """,
        inputSchema: objectSchema(["app": appParam], required: ["app"]),
        annotations: readOnlyAppAnnotations,
        handler: { args in try await listWindows(args) }
    ),
    ToolSpec(
        name: "manage_window",
        description: """
            Manage an app window: raise (bring to front within the app), minimize, \
            unminimize, move, resize, fullscreen, exit_fullscreen, or close. Targets the \
            front window unless window_title is given. Move/resize use global screen \
            points (not screenshot pixels). Geometry must be finite and within \
            server-enforced bounds. close requires confirm:true.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "action": enumParam(
                    ["raise", "minimize", "unminimize", "move", "resize", "fullscreen", "exit_fullscreen", "close"],
                    "What to do with the window."
                ),
                "window_title": stringParam("Optional window title; defaults to the front window."),
                "x": numberParam(
                    "Target X for move (global screen points, top-left origin, max +/-"
                        + "\(Int(ArgumentBounds.maxWindowCoordinateMagnitude)))."
                ),
                "y": numberParam(
                    "Target Y for move (global screen points, max +/-"
                        + "\(Int(ArgumentBounds.maxWindowCoordinateMagnitude)))."
                ),
                "width": numberParam(
                    "Target width for resize (points, "
                        + "\(Int(ArgumentBounds.minWindowDimension))..."
                        + "\(Int(ArgumentBounds.maxWindowDimension)))."
                ),
                "height": numberParam(
                    "Target height for resize (points, "
                        + "\(Int(ArgumentBounds.minWindowDimension))..."
                        + "\(Int(ArgumentBounds.maxWindowDimension)))."
                ),
                "allow_focus_change": allowFocusChangeParam,
                "confirm": confirmParam,
            ],
            required: ["app", "action"]
        ),
        annotations: destructiveAppActionAnnotations,
        handler: { args in try await manageWindow(args) }
    ),
    ToolSpec(
        name: "click_menu_item",
        description: """
            Select an item from the app's menu bar by path, e.g. \"File > Export As…\" or \
            \"Format > Font > Bold\". Works in the background without opening the menu \
            visually. Use for commands that have no on-screen button.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "path": stringParam("Menu path with \" > \" separators, e.g. \"File > Save\"."),
                "include_screenshot": includeScreenshotParam,
                "include_state": includeStateParam,
                "state_response_mode": stateResponseModeParam,
                "confirm": confirmParam,
            ],
            required: ["app", "path"]
        ),
        annotations: destructiveAppActionAnnotations,
        handler: { args in try await clickMenuItem(args) }
    ),
    ToolSpec(
        name: "page",
        description: """
            Act on web content by CSS selector when browser/webview accessibility ids are \
            unreliable. click evaluates getBoundingClientRect in the page, converts the \
            viewport point to screen coordinates, and clicks through the background input \
            ladder without moving the real cursor. set_text uses browser JavaScript Apple \
            Events, Electron CDP Input.insertText, or WKWebView AX fallback. DOM readback \
            is reported in _meta; AX-only fallback evidence is downgraded honestly.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "selector": stringParam("CSS selector for the page element, e.g. \"#submit\" or \"input[name=email]\"."),
                "action": enumParam(["click", "set_text"], "Action to perform. Defaults to click."),
                "text": stringParam("Text for action:set_text. Ignored for click."),
                "verify_selector": stringParam(
                    "Optional CSS selector to read back for DOM verification. Defaults to selector. "
                        + "For buttons that mutate another element, point this at the mutated element."
                ),
                "window_title": stringParam(
                    "Optional window title to target a specific window. Defaults to the app's front window."
                ),
                "cdp_port": integerParam(
                    "Electron only: Chrome DevTools Protocol port for Input.insertText / Runtime.evaluate."
                ),
                "target_url_contains": stringParam(
                    "Electron only: choose the CDP page target whose URL contains this substring."
                ),
                "include_screenshot": includeScreenshotParam,
                "include_state": includeStateParam,
                "state_response_mode": stateResponseModeParam,
                "confirm": confirmParam,
            ],
            required: ["app", "selector"]
        ),
        annotations: destructiveAppActionAnnotations,
        handler: { args in try await page(args) }
    ),
    ToolSpec(
        name: "read_clipboard",
        description: "Read the current text content of the system clipboard.",
        inputSchema: objectSchema([:]),
        annotations: readOnlyLocalAnnotations,
        handler: { args in try await readClipboard(args) }
    ),
    ToolSpec(
        name: "health_report",
        description: """
            Report this MCP server's runtime health: process identity, TCC permissions, \
            capture-service status, daemon files, and recent daemon telemetry. This is \
            read-only; degraded permissions or capture health are reported in structured \
            content and outcome metadata, not as a tool error.
            """,
        inputSchema: objectSchema([
            "probe_capture_service": boolParam(
                "Default false. Set true for a stronger local ScreenCaptureKit responsiveness "
                    + "probe; it enumerates shareable content but does not capture pixels."
            )
        ]),
        annotations: readOnlyLocalAnnotations,
        handler: { args in try await healthReport(args) }
    ),
    ToolSpec(
        name: "write_clipboard",
        description: """
            Replace the system clipboard with the given text, e.g. to paste a long value \
            with press_key cmd+v. Note: this overwrites whatever the user had copied.
            """,
        inputSchema: objectSchema(
            [
                "text": stringParam(
                    "Text to place on the clipboard. Maximum \(ArgumentBounds.maxClipboardCharacters) characters."
                ),
                "confirm": confirmParam,
            ],
            required: ["text"]
        ),
        annotations: writeClipboardAnnotations,
        handler: { args in try await writeClipboard(args) }
    ),
    ToolSpec(
        name: "wait_for",
        description: """
            Wait until an element appears (or disappears, with gone:true) in an app's \
            window, then return fresh state. Use after actions that trigger loading, \
            instead of polling get_app_state manually.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "label": stringParam("Match elements whose title/description contains this text (case-insensitive)."),
                "role": stringParam("Match elements with this exact AX role, e.g. AXButton."),
                "value_contains": stringParam("Match elements whose value contains this text."),
                "gone": boolParam("Default false. When true, wait for the match to disappear instead."),
                "timeout_seconds": numberParam("How long to wait (default 10, max 60)."),
                "window_title": stringParam("Optional window title; defaults to the front window."),
            ],
            required: ["app"]
        ),
        annotations: readOnlyAppAnnotations,
        handler: { args in try await waitFor(args) }
    ),
    ToolSpec(
        name: "read_text",
        description: """
            Read the full text value of an element — the tree truncates long values. \
            Supports offset/length chunking for very large documents. For a big text \
            surface (a long article, an editor buffer) pass visible_only to get just \
            the on-screen slice, rendered to markdown with links and emphasis.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "element_id": elementIDParam,
                "offset": integerParam("Character offset to start from (default 0)."),
                "length": integerParam(
                    "Maximum characters to return (default \(ArgumentBounds.maxReadTextCharacters), "
                        + "max \(ArgumentBounds.maxReadTextCharacters))."
                ),
                "visible_only": boolParam(
                    "Return only the characters currently scrolled into view, rendered to "
                        + "markdown (links as [text](url), bold/italic marked). Defaults on "
                        + "automatically for very large values; pass false to force the full value."
                ),
            ],
            required: ["app", "element_id"]
        ),
        annotations: readOnlyAppAnnotations,
        handler: { args in try await readText(args) }
    ),
    ToolSpec(
        name: "batch",
        description: """
            Run a short sequence of actions against one app in a single call — e.g. \
            click a field, type into it, press Return. Each step is one of the normal \
            action tools with its usual arguments (omit "app"; the batch's app applies \
            to every step). Steps run in order with per-step safety checks; the batch \
            stops at the first failure and reports which steps already ran. \
            Intermediate mutating steps recapture state without screenshots and must \
            return structured success before the next step runs. Tools outside the \
            documented intermediate set are final-only. \
            The final step returns fresh state as usual. Use only for sequences whose intermediate states you can \
            predict; when the next step depends on what appears, act step by step.
            """,
        inputSchema: objectSchema(
            [
                "app": appParam,
                "actions": .object([
                    "type": .string("array"),
                    "description": .string(
                        "1-\(maxBatchActions) steps, each an object with \"tool\" set to one of: "
                            + batchableToolNames.sorted().joined(separator: ", ")
                            + " — plus that tool's usual arguments (omit \"app\"; the batch app applies). "
                            + "Intermediate steps are limited to: "
                            + batchIntermediateToolNames.sorted().joined(separator: ", ") + "."
                    ),
                    "items": .object([
                        "type": .string("object"),
                        "description": .string(
                            "One batch step: {\"tool\": \"<name>\", ...that tool's usual arguments, "
                                + "omitting \"app\"}."
                        ),
                        "properties": .object([
                            "tool": stringParam(
                                "Batchable tool name: "
                                    + batchableToolNames.sorted().joined(separator: ", ") + "."
                            ),
                        ]),
                        "required": .array([.string("tool")]),
                        "additionalProperties": .bool(true),
                    ]),
                ]),
                "include_screenshot": includeScreenshotParam,
                "state_response_mode": stateResponseModeParam,
            ],
            required: ["app", "actions"]
        ),
        annotations: destructiveAppActionAnnotations,
        handler: { args in try await batch(args) }
    ),
    ToolSpec(
        name: "save_skill",
        description: """
            Save a repeatable task as a named skill after performing it once. Steps are \
            the normal action tools; element_id anchors are frozen into durable locators \
            (role + label + tree path) that re-resolve on every run, so the skill \
            survives app restarts. Prefer restart-durable primitives when teaching: \
            keyboard shortcuts (press_key) and menu commands (click_menu_item) over \
            positional clicks, set_value over click-then-type, and give steps an \
            "expect" so replay verifies each effect. A read_text step extracts data \
            into the replay result. Use {{param_name}} placeholders in any string \
            argument and declare them in params. Replay with run_skill.
            """,
        inputSchema: objectSchema(
            [
                "name": stringParam("Skill name: 1-64 lowercase letters, digits, hyphens."),
                "description": stringParam("One line: what the skill does, for list_skills."),
                "app": appParam,
                "params": .object([
                    "type": .string("array"),
                    "description": .string(
                        "Placeholders the skill takes, each {\"name\": \"invoice_number\", "
                            + "\"description\": …}. Reference them as {{name}} in step arguments."),
                    "items": .object(["type": .string("object")]),
                ]),
                "steps": .object([
                    "type": .string("array"),
                    "description": .string(
                        "1-\(maxSkillSteps) steps, each {\"tool\": one of "
                            + skillStepToolNames.sorted().joined(separator: ", ")
                            + ", plus that tool's usual arguments}. Element-targeted steps: pass "
                            + "\"element_id\" from the CURRENT state (frozen into a locator at save "
                            + "time) or an explicit \"locator\": {\"role\", \"label\"}. Optional "
                            + "\"expect\": {\"role\", \"label\", \"value_contains\", \"gone\", "
                            + "\"timeout_seconds\"} asserts the step's effect (wait_for terms)."),
                    "items": .object(["type": .string("object")]),
                ]),
                "overwrite": boolParam("Default false. Set true to replace an existing skill of the same name."),
            ],
            required: ["name", "description", "app", "steps"]
        ),
        annotations: skillWriteAnnotations,
        handler: { args in try await saveSkill(args) }
    ),
    ToolSpec(
        name: "run_skill",
        description: """
            Replay a saved skill deterministically: each step re-resolves its locator \
            against the live tree, runs through the normal per-step safety checks, and \
            verifies its expectation. Elements that moved are found by role+label and \
            their saved address self-heals. No reasoning happens between steps, so \
            replay is fast; if a step cannot resolve or its expectation fails, the run \
            stops with a report of exactly which step broke — fix that step, re-save, \
            and rerun with start_at_step to continue. Returns final app state plus any \
            read_text extracts.
            """,
        inputSchema: objectSchema(
            [
                "name": stringParam("Name of the saved skill (see list_skills)."),
                "params": .object([
                    "type": .string("object"),
                    "description": .string(
                        "Values for the skill's declared params, e.g. {\"week\": \"2026-W27\"}."),
                ]),
                "start_at_step": integerParam(
                    "Resume from this 1-based step, skipping earlier ones — for continuing "
                        + "after a repaired failure without redoing completed side effects."),
            ],
            required: ["name"]
        ),
        annotations: destructiveAppActionAnnotations,
        handler: { args in try await runSkill(args) }
    ),
    ToolSpec(
        name: "get_skill",
        description: """
            Show a saved skill's full JSON definition — the starting point for \
            repairing a failed step: edit the step and re-save with save_skill \
            overwrite:true.
            """,
        inputSchema: objectSchema(
            ["name": stringParam("Name of the saved skill (see list_skills).")],
            required: ["name"]
        ),
        annotations: readOnlyLocalAnnotations,
        handler: { args in try await getSkill(args) }
    ),
    ToolSpec(
        name: "list_skills",
        description: "List saved skills with their target app, step count, description, and params.",
        inputSchema: objectSchema([:]),
        annotations: readOnlyLocalAnnotations,
        handler: { args in try await listSkills(args) }
    ),
    ToolSpec(
        name: "delete_skill",
        description: "Delete a saved skill by name. Irreversible, so it requires confirm:true.",
        inputSchema: objectSchema(
            [
                "name": stringParam("Name of the skill to delete."),
                "confirm": confirmParam,
            ],
            required: ["name"]
        ),
        annotations: skillWriteAnnotations,
        handler: { args in try await deleteSkill(args) }
    ),
    ToolSpec(
        name: "record_skill_start",
        description: """
            Teach mode: start recording the USER's own demonstration of a task in an app, \
            instead of performing it yourself. A listen-only input monitor captures the \
            user's real clicks (mapped to the element under each), typing, and shortcuts \
            while the target app is frontmost; it pauses automatically during password \
            entry. Ask the user to do the task, then call record_skill_stop to get the \
            draft steps and refine them into save_skill. Needs the Input Monitoring \
            permission (macOS prompts on first use).
            """,
        inputSchema: objectSchema(
            ["app": appParam],
            required: ["app"]
        ),
        annotations: recorderAnnotations,
        handler: { args in try await recordSkillStart(args) }
    ),
    ToolSpec(
        name: "record_skill_stop",
        description: """
            Stop teach-mode recording and return the captured actions as draft skill \
            steps. Review them with the user (parameterize values that vary with \
            {{params}}, drop stray clicks, add expect assertions), then persist with \
            save_skill.
            """,
        inputSchema: objectSchema([:]),
        annotations: recorderAnnotations,
        handler: { args in try await recordSkillStop(args) }
    ),
]
