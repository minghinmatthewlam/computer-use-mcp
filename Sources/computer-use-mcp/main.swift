// computer-use-mcp — entry point.

import Foundation
#if os(macOS)
import CoreGraphics
#endif

// Establish the window-server connection on the main thread before any
// CoreGraphics/ScreenCaptureKit call runs on a worker thread; without this,
// CG asserts (CGS_REQUIRE_INIT) in headless CLI processes.
_ = CGMainDisplayID()

// Cap how long any single accessibility message may block (the system default
// is 6s — a frozen app would stall every AX call in a tree walk for that
// long). Setting the system-wide element changes this process's default.
configureAXMessagingTimeout()

// A broken pipe to a child (e.g. a dead overlay helper) must yield EPIPE, not
// terminate the server with SIGPIPE.
signal(SIGPIPE, SIG_IGN)

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "serve":
    await runServe()
case "daemon":
    await runDaemon()
case "call":
    await runCall(Array(arguments.dropFirst()))
case "doctor":
    await runDoctor(prompt: arguments.contains("--prompt"))
case "health_report":
    await runHealthReport(json: arguments.contains("--json"), probeCaptureService: arguments.contains("--probe-capture"))
case "overlay":
    runOverlay()
case "version", "--version", "-v":
    print("computer-use-mcp \(version)")
case "help", "--help", "-h", .none:
    printUsage()
case .some(let unknown):
    FileHandle.standardError.write(Data("Unknown command: \(unknown)\n\n".utf8))
    printUsage()
    exit(2)
}

func printUsage() {
    print(
        """
        computer-use-mcp \(version)
        Expose macOS computer use to any AI agent, over MCP.

        USAGE:
          computer-use-mcp serve                 Run the MCP server over stdio
          computer-use-mcp daemon                Run the shared engine daemon (spawned on demand)
          computer-use-mcp call <tool> [<json>]  Invoke a single tool (dev harness)
          computer-use-mcp doctor [--prompt]     Check required macOS permissions
          computer-use-mcp health_report [--json] [--probe-capture]
                                                 Report identity, permissions, capture, and daemon diagnostics
          computer-use-mcp version               Print version
          computer-use-mcp help                  Show this help
        """
    )
}
