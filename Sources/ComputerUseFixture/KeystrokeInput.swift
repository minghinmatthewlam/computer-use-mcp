#if os(macOS)
import AppKit
import SwiftUI

// A text input that is intentionally NOT AX-value-settable. It exposes a
// text-area role and a read-only accessibility value (the echoed text) but no
// value setter, so an AX set_value attempt must fail and type_text has to fall
// back to synthetic CGEvent keystrokes routed to the focused first responder.
// The echoed text is mirrored out through `onChange` into a StatusReadout, so
// the verifier can confirm the keystrokes actually landed.
struct KeystrokeInput: NSViewRepresentable {
    @Binding var echo: String
    func makeNSView(context: Context) -> KeystrokeView {
        let view = KeystrokeView()
        view.onChange = { echo = $0 }
        return view
    }
    func updateNSView(_ view: KeystrokeView, context: Context) {}
}

final class KeystrokeView: NSView {
    var onChange: ((String) -> Void)?
    private var typed = ""

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("keystroke-input")
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { "keystroke-input" }
    // Read-only: getter only, no setAccessibilityValue -> not AX-settable.
    override func accessibilityValue() -> Any? { typed }

    override func accessibilityFrame() -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 {  // delete/backspace
            if !typed.isEmpty { typed.removeLast() }
        } else if let chars = event.characters, !chars.isEmpty {
            typed += chars
        }
        onChange?(typed)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        let empty = typed.isEmpty
        let display = (empty ? "(click, then type)" : typed) as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: empty ? NSColor.placeholderTextColor : NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 13),
        ]
        display.draw(at: NSPoint(x: 6, y: (bounds.height - 18) / 2), withAttributes: attrs)
    }
}
#endif
