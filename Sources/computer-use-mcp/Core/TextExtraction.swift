 #if os(macOS)
// Visible-range and rich-text extraction for read_text.
//
// A large text surface (a long article, an editor buffer) can hold far more
// text than fits on screen. Reading its whole kAXValue is expensive and buries
// what the user is actually looking at. The visible-range path instead pulls
// only the characters currently scrolled into view — via the parameterized AX
// attributes kAXVisibleCharacterRange + kAX{String,AttributedString}ForRange —
// and renders the attributed runs to lightweight markdown so links and
// emphasis survive as text (BCU-style extraction).

import Foundation
#if os(macOS)
import AppKit
import ApplicationServices
#endif

enum TextExtraction {
    /// Character count above which read_text auto-switches to the visible-range
    /// path (unless the caller passed an explicit offset/length window or
    /// visible_only:false). Tunable via COMPUTER_USE_MCP_READ_TEXT_VISIBLE_THRESHOLD.
    static var largeValueThreshold: Int {
        Config.double("read_text_visible_threshold").map(Int.init) ?? 50_000
    }

    /// The on-screen slice of a text element, rendered to markdown.
    struct VisibleText {
        var markdown: String
        var range: CFRange
    }

    /// Pull the visible character range and render it. Prefers the attributed
    /// string (keeps links/emphasis); falls back to the plain string. nil when
    /// the element exposes neither parameterized attribute — the caller then
    /// tries the web-area path, then the classic full-value read.
    static func visibleText(of element: AXUIElement) -> VisibleText? {
        guard let range = axVisibleCharacterRange(element), range.length > 0 else { return nil }
        if let attributed = axAttributedStringForRange(element, range: range), attributed.length > 0 {
            return VisibleText(markdown: attributedStringToMarkdown(attributed), range: range)
        }
        if let plain = axStringForRange(element, range: range), !plain.isEmpty {
            return VisibleText(markdown: plain, range: range)
        }
        return nil
    }

    /// Rich text of a WKWebView web area, rendered to markdown. Web content
    /// carries no character range, so this pulls the whole realized attributed
    /// string via text markers — the visible-range equivalent for a web area,
    /// whose AX tree only realizes on-screen (plus nearby) content. nil when
    /// the element is not web content or exposes no marker range.
    static func webAreaMarkdown(of element: AXUIElement) -> String? {
        guard let attributed = axWebAreaAttributedString(element), attributed.length > 0 else {
            return nil
        }
        return attributedStringToMarkdown(attributed)
    }
}

// MARK: - Attributed string → markdown (pure)

/// Render an accessibility attributed string to lightweight markdown: links as
/// `[text](url)`, bold as `**text**`, italic as `*text*`, both as `***text***`.
/// Pure and deterministic — the unit tests drive it directly. Unknown
/// attributes pass through as plain text.
func attributedStringToMarkdown(_ attributed: NSAttributedString) -> String {
    let full = attributed.string as NSString
    var out = ""
    attributed.enumerateAttributes(
        in: NSRange(location: 0, length: attributed.length), options: []
    ) { attributes, range, _ in
        out += markdownForRun(full.substring(with: range), attributes: attributes)
    }
    return out
}

/// The bold/italic/link styling carried by one attributed run.
struct RunStyle: Equatable {
    var bold = false
    var italic = false
    var link: String?
}

private func markdownForRun(_ text: String, attributes: [NSAttributedString.Key: Any]) -> String {
    // Attachment runs (images, embedded controls) surface as U+FFFC object
    // replacement characters with no text; drop them so they don't litter the
    // markdown with stray placeholder glyphs.
    let text = text.replacingOccurrences(of: "\u{FFFC}", with: "")
    guard !text.isEmpty else { return text }
    // Keep surrounding whitespace outside the markers so we never emit the
    // invalid `** text **`; a whitespace-only run stays undecorated.
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return text }
    let leading = String(text.prefix(while: { $0.isWhitespace }))
    let trailing = String(text.reversed().prefix(while: { $0.isWhitespace }).reversed())

    let style = runStyle(from: attributes)
    var core = trimmed
    if style.bold && style.italic {
        core = "***\(core)***"
    } else if style.bold {
        core = "**\(core)**"
    } else if style.italic {
        core = "*\(core)*"
    }
    if let link = style.link, !link.isEmpty {
        core = "[\(core)](\(link))"
    }
    return leading + core + trailing
}

/// Extract styling from a run's attributes. Reads both AppKit-native keys
/// (NSFont traits, NSLink) and the accessibility keys ("AXFont", "AXLink")
/// that web content produces, so the same renderer serves tests and live AX.
func runStyle(from attributes: [NSAttributedString.Key: Any]) -> RunStyle {
    var style = RunStyle()

    if let font = attributes[.font] as? NSFont {
        let traits = font.fontDescriptor.symbolicTraits
        style.bold = traits.contains(.bold)
        style.italic = traits.contains(.italic)
    }
    // Accessibility font runs carry a dictionary, not an NSFont; the family
    // name is the only reliable trait signal there.
    if let axFont = attributes[NSAttributedString.Key("AXFont")] as? [String: Any],
        let name = (axFont["AXFontName"] as? String)?.lowercased()
    {
        if name.contains("bold") { style.bold = true }
        if name.contains("italic") || name.contains("oblique") { style.italic = true }
    }

    style.link = linkURL(from: attributes)
    return style
}

private func linkURL(from attributes: [NSAttributedString.Key: Any]) -> String? {
    if let link = attributes[.link] {
        if let url = link as? URL { return url.absoluteString }
        if let string = link as? String, !string.isEmpty { return string }
    }
    // AX link runs point at the link UI element; the URL hangs off it.
    if let value = attributes[NSAttributedString.Key("AXLink")] {
        let ref = value as CFTypeRef
        if CFGetTypeID(ref) == AXUIElementGetTypeID() {
            let element = ref as! AXUIElement
            if let url = axString(element, kAXURLAttribute), !url.isEmpty { return url }
        }
    if let url = value as? URL { return url.absoluteString }
    if let string = value as? String, !string.isEmpty { return string }
    }
    return nil
}
#endif
