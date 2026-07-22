#if os(macOS)
import AppKit
import SwiftUI

// Shared chrome and readouts. A StatusReadout exposes its live state as the
// accessibility *value* of a labelled element, so the truth suite reads the
// real outcome (read-act-read) instead of trusting a command's self-report.

struct StatusReadout: View {
    let name: String
    let value: String
    var body: some View {
        Text("\(name): \(value)")
            .font(.system(.body, design: .monospaced))
            .accessibilityLabel(name)
            .accessibilityValue(value)
    }
}

struct Card<Content: View>: View {
    let title: String
    var width: CGFloat = 300
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
        .padding(12)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
    }
}

// MARK: - Known-liar button (custom AX element)

// A button whose AX Press action reports success but deliberately mutates no
// state. Backed by a raw NSView so accessibilityPerformPress() is fully under
// our control — SwiftUI would route a real action closure. The paired readout
// never changes, so a read-act-read verifier classifies a "successful" press
// as effect_not_verified. This is the canonical ground-truth liar.
struct LiarButton: NSViewRepresentable {
    func makeNSView(context: Context) -> LiarButtonView { LiarButtonView() }
    func updateNSView(_ view: LiarButtonView, context: Context) {}
}

final class LiarButtonView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("liar-button")
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "liar-button" }

    // KNOWN LIAR: advertise AXPress, return success, change nothing.
    override func accessibilityPerformPress() -> Bool { true }

    override func accessibilityFrame() -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    // A real mouse click is also inert — the lie holds on every input path.
    override func mouseDown(with event: NSEvent) {}

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let label = "Liar Button" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 13),
        ]
        let size = label.size(withAttributes: attrs)
        label.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attrs)
    }
}
#endif
