#if os(macOS)
import AppKit
import SwiftUI

// ComputerUseFixture — a deterministic GUI fixture for the computer-use-mcp
// "truth suite". Every interactive control writes its outcome into an
// independently AX-readable readout, so a verifier can observe the *real*
// effect instead of trusting a command's ok:true. Some controls are
// deliberate KNOWN LIARS (they report AX success while mutating nothing) so
// the verifier-first outcome contract can be tested against ground truth
// rather than whatever a real app happens to render. See docs/fixture-app.md
// for the control -> truth-suite scenario map.

// Window content-size clamp, documented in docs/fixture-app.md. manage_window
// resize writes are clamped to these bounds. Expressed as a SwiftUI root-view
// frame (below) so SwiftUI itself maintains the window's contentMin/MaxSize —
// a delegate-set constraint gets overridden by SwiftUI's layout pass.
enum WindowClamp {
    static let minWidth: CGFloat = 720
    static let minHeight: CGFloat = 540
    static let maxWidth: CGFloat = 1200
    static let maxHeight: CGFloat = 900
    static let idealWidth: CGFloat = 960
    static let idealHeight: CGFloat = 720
}

@main
struct ComputerUseFixtureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("ComputerUse Fixture") {
            ContentView()
                .frame(
                    minWidth: WindowClamp.minWidth, idealWidth: WindowClamp.idealWidth,
                    maxWidth: WindowClamp.maxWidth,
                    minHeight: WindowClamp.minHeight, idealHeight: WindowClamp.idealHeight,
                    maxHeight: WindowClamp.maxHeight)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Default: launch in the background so the fixture window never pops over
    // whoever is frontmost while a worker runs live tests. The server drives
    // the window in the background by design, so it must still be visible,
    // orderable, AX-readable, SCK-capturable, and hit-testable — just not
    // key/front and the app not activated. Set COMPUTER_USE_FIXTURE_FOREGROUND=1
    // to restore a normal activated, front window (needed for occlusion-proof
    // scenarios where a worker deliberately arranges windows).
    private var foregroundRequested: Bool {
        ProcessInfo.processInfo.environment["COMPUTER_USE_FIXTURE_FOREGROUND"] == "1"
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Decide the activation policy *before* SwiftUI shows the window.
        // .accessory keeps the app out of the Dock/menu bar and, with the
        // orderBack + deactivate below, keeps it from stealing focus on launch.
        NSApp.setActivationPolicy(foregroundRequested ? .regular : .accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let window = NSApp.windows.first else { return }
        window.title = "ComputerUse Fixture"
        placeWindow(window)

        if foregroundRequested {
            // Explicit opt-out: genuinely come to the front (occlusion-proof
            // scenarios need the window actually frontmost), so steal focus.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            // Show on-screen but behind the frontmost app, never key, and hand
            // activation back to whoever was frontmost.
            window.orderBack(nil)
            window.resignKey()
            deactivateToBackground()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Pin the window to a consistent modest position (near the top-left of the
    // main screen's visible area) instead of SwiftUI's centered splash, so its
    // frame is deterministic across launches.
    private func placeWindow(_ window: NSWindow) {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 80, y: visible.maxY - 80))
    }

    // Return activation to the previously-frontmost app. SwiftUI may activate
    // this app when it first shows the window; deactivating on the next runloop
    // tick as well makes the hand-back robust against that late activation.
    private func deactivateToBackground() {
        NSApp.deactivate()
        DispatchQueue.main.async { NSApp.deactivate() }
    }
}
#else
import Foundation

@main
struct ComputerUseFixtureApp {
    static func main() {}
}
#endif
