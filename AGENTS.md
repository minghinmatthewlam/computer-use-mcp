# Agent Guidelines

This repo exposes live macOS computer-use capabilities. Treat runtime changes as
safety-sensitive even when they look like ordinary Swift edits.

## Safety Boundaries

- Do not run live GUI, TCC, app-control, clipboard, or global-cursor demos unless
  the user explicitly approves that run.
- Default to non-mutating verification: `swift build`, `swift test`, and CLI
  help/version smoke checks.
- Treat `scripts/e2e_demo.py`, `doctor --prompt`, `call`, `serve` against real
  apps, and any test using Accessibility, Screen Recording, clipboard, window
  management, or input delivery as mutating/local-only.
- Never disable safety gates (`COMPUTER_USE_MCP_NO_SAFETY=1`), app leases, or
  daemon isolation to make a test pass unless the task is specifically about
  those controls and the final result verifies the safe default path too.

## Command Discipline

- Run each shell command as a separate tool call. Do not chain with `&&`, `||`,
  `;`, or pipes unless that shell behavior is the thing being tested.
- Prefer `rg`/`rg --files` for discovery.
- Do not push, publish, rewrite history, delete user data, or kill unrelated
  processes without explicit permission.

## Ownership Map

- `Sources/computer-use-mcp/Core/`: capture, AX, input, targeting, policy, and
  config. Runtime or safety changes here require focused unit coverage plus a
  local real-surface verification plan.
- `Sources/computer-use-mcp/Tools/`: MCP tool handlers and catalog. Keep schemas
  stable and verify CLI/MCP smoke behavior when changing contracts.
- `Sources/computer-use-mcp/Daemon/`: shared engine process, socket protocol,
  and app leases. Verify multi-session and daemon fallback assumptions before
  claiming concurrency safety.
- `Sources/computer-use-mcp/Overlay/`: visible agent cursor. Keep it optional
  for headless/CI paths.
- `Sources/computer-use-mcp/ToolKit/`: schema/tool-spec plumbing. Prefer small,
  backwards-compatible changes.
- `Tests/ComputerUseMCPTests/`: pure unit tests only. Do not add live GUI/TCC
  tests to the default suite.
- `scripts/`: local demos and manual preflight helpers. Document required user
  consent and side effects.
- `.github/workflows/`: hosted CI. Keep it deterministic and avoid live GUI/TCC
  requirements on hosted runners.

## Verification Expectations

- Docs-only changes: inspect the rendered Markdown structure and run the
  non-mutating build/test/CLI smoke path when practical.
- Tool schema, handler, or CLI changes: run `swift test`, then `swift build`,
  then `.build/debug/computer-use-mcp version` and
  `.build/debug/computer-use-mcp help`.
- Runtime, input, daemon, overlay, or safety-policy changes: run the unit/CLI
  path and either perform an approved local live verification or explicitly
  report why live verification was not run.
- Safety-policy changes must include tests for both the gated path and the
 confirmed/recovery path.

## Cursor Cloud specific instructions

Cursor Cloud Agent VMs run **Linux (x86_64)**, but this project is **macOS-only**
(`Package.swift` declares `.macOS(.v14)`; every source target imports Apple
frameworks — `AppKit`, `ApplicationServices`, `CoreGraphics`, `ScreenCaptureKit`,
`Vision`, `Carbon`, `IOKit`, `WebKit`, `SwiftUI`). It therefore **cannot be built,
tested, or run on the Linux Cloud VM.** Hosted CI runs on `macos-15` (see
`.github/workflows/ci.yml`); full verification requires macOS 14+ with the Swift 6
toolchain (Xcode 16+).

What is and is not possible on the Linux VM:

- A Swift toolchain (Swift 6.x via `swiftly`, on `PATH` through `~/.profile`) is
 installed for editing, sourcekit-lsp, and SwiftPM dependency resolution only.
- `swift package resolve` works — the third-party deps (swift-nio, swift-log,
 MCP SDK, etc.) are cross-platform and compile fine.
- `swift build` / `swift test` **fail** on Linux with `no such module 'AppKit'`
 (fixture target) and `no such module 'CoreGraphics'` (main target). This is
 expected, not a misconfiguration — do not try to "fix" it by editing imports or
 platform gates.
- The live/CLI/demo paths (`serve`, `call`, `doctor`, `scripts/e2e_demo.py`,
 etc.) need macOS Accessibility/ScreenCaptureKit and cannot run here.

Practical guidance for a Cloud Agent on this repo: you can read, navigate, and
make source edits with LSP support, but you **cannot compile, test, or run** the
result on the VM. Any change that needs `swift build`/`swift test`/live
verification must be verified by the user (or CI) on a macOS host; state this
explicitly in the PR instead of claiming local verification.
