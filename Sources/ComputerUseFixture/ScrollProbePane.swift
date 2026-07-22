#if os(macOS)
import AppKit
import SwiftUI

struct ScrollProbePane: View {
    @State private var wheelCount = 0

    var body: some View {
        Card(title: "Scroll Contract Probe") {
            Text("Advertises a scroll area but intentionally consumes wheel events without moving content.")
                .font(.caption)
                .foregroundStyle(.secondary)
            InertScrollTarget { wheelCount += 1 }
                .frame(width: 260, height: 90)
            StatusReadout(name: "scroll-churn", value: String(wheelCount))
        }
    }
}

struct InertScrollTarget: NSViewRepresentable {
    var onWheel: () -> Void

    func makeNSView(context: Context) -> InertScrollTargetView {
        let view = InertScrollTargetView()
        view.onWheel = onWheel
        return view
    }

    func updateNSView(_ view: InertScrollTargetView, context: Context) {
        view.onWheel = onWheel
    }
}

final class InertScrollTargetView: NSView {
    var onWheel: () -> Void = {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setAccessibilityElement(true)
        setAccessibilityRole(.scrollArea)
        setAccessibilityLabel("inert-scroll-probe")
        setAccessibilityValue("Probe Row A; Probe Row B; Probe Row C")
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .scrollArea }
    override func accessibilityLabel() -> String? { "inert-scroll-probe" }
    override func accessibilityValue() -> Any? { "Probe Row A; Probe Row B; Probe Row C" }

    override func accessibilityFrame() -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    // The probe's purpose is to reproduce false-success scroll verification:
    // wheel delivery can be accepted by the view while content stays fixed.
    override func scrollWheel(with event: NSEvent) { onWheel() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        NSColor.systemBlue.withAlphaComponent(0.5).setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).stroke()

        let lines = ["Probe Row A", "Probe Row B", "Probe Row C"]
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        ]
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 12, y: bounds.height - 24 - CGFloat(index * 22)), withAttributes: attrs)
        }
    }
}
#endif
