 #if os(macOS)
import Foundation
#if os(macOS)
import AppKit
#endif
import Testing

@testable import computer_use_mcp

@Suite struct TextExtractionTests {
    // MARK: helpers

    private func plain(_ text: String) -> NSAttributedString { NSAttributedString(string: text) }

    private func bold(_ text: String) -> NSAttributedString {
        let font = NSFontManager.shared.convert(
            NSFont.systemFont(ofSize: 12), toHaveTrait: .boldFontMask)
        return NSAttributedString(string: text, attributes: [.font: font])
    }

    private func italic(_ text: String) -> NSAttributedString {
        let font = NSFontManager.shared.convert(
            NSFont.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
        return NSAttributedString(string: text, attributes: [.font: font])
    }

    private func boldItalic(_ text: String) -> NSAttributedString {
        var font = NSFontManager.shared.convert(
            NSFont.systemFont(ofSize: 12), toHaveTrait: .boldFontMask)
        font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        return NSAttributedString(string: text, attributes: [.font: font])
    }

    private func link(_ text: String, _ url: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.link: URL(string: url)!])
    }

    // MARK: renderer

    @Test func plainTextRoundTrips() {
        #expect(attributedStringToMarkdown(plain("hello world")) == "hello world")
    }

    @Test func emptyStringIsEmpty() {
        #expect(attributedStringToMarkdown(plain("")) == "")
    }

    @Test func boldRunGetsDoubleStars() {
        #expect(attributedStringToMarkdown(bold("strong")) == "**strong**")
    }

    @Test func italicRunGetsSingleStar() {
        #expect(attributedStringToMarkdown(italic("slanted")) == "*slanted*")
    }

    @Test func boldItalicRunGetsTripleStars() {
        #expect(attributedStringToMarkdown(boldItalic("both")) == "***both***")
    }

    @Test func linkRunRendersAsMarkdownLink() {
        #expect(
            attributedStringToMarkdown(link("Fixture Web Link", "https://example.com/"))
                == "[Fixture Web Link](https://example.com/)")
    }

    @Test func stringValuedLinkAttributeIsAccepted() {
        let attributed = NSAttributedString(
            string: "click", attributes: [.link: "https://str.example/"])
        #expect(attributedStringToMarkdown(attributed) == "[click](https://str.example/)")
    }

    @Test func mixedRunsConcatenateInOrder() {
        let combined = NSMutableAttributedString()
        combined.append(plain("See the "))
        combined.append(link("docs", "https://docs.example/"))
        combined.append(plain(" for "))
        combined.append(bold("details"))
        combined.append(plain("."))
        #expect(
            attributedStringToMarkdown(combined)
                == "See the [docs](https://docs.example/) for **details**.")
    }

    @Test func surroundingWhitespaceStaysOutsideMarkers() {
        // A bold run that includes leading/trailing spaces must not emit the
        // invalid `** bold **`.
        #expect(attributedStringToMarkdown(bold(" bold ")) == " **bold** ")
    }

    @Test func whitespaceOnlyRunIsUndecorated() {
        #expect(attributedStringToMarkdown(bold("   ")) == "   ")
    }

    @Test func attachmentPlaceholderIsStripped() {
        // Web attachments (an embedded control or image) arrive as U+FFFC with
        // no text; they must not leak into the markdown as stray glyphs.
        let combined = NSMutableAttributedString()
        combined.append(plain("before "))
        combined.append(plain("\u{FFFC}"))
        combined.append(plain("after"))
        #expect(attributedStringToMarkdown(combined) == "before after")
    }

    @Test func linkWrapsEmphasis() {
        let attributed = NSMutableAttributedString(
            string: "x",
            attributes: [
                .link: URL(string: "https://e.example/")!,
                .font: NSFontManager.shared.convert(
                    NSFont.systemFont(ofSize: 12), toHaveTrait: .boldFontMask),
            ])
        #expect(attributedStringToMarkdown(attributed) == "[**x**](https://e.example/)")
    }

    // MARK: runStyle

    @Test func axFontNameSignalsBold() {
        let style = runStyle(from: [NSAttributedString.Key("AXFont"): ["AXFontName": "Helvetica-Bold"]])
        #expect(style.bold)
        #expect(!style.italic)
    }

    @Test func axFontNameSignalsItalic() {
        let style = runStyle(from: [NSAttributedString.Key("AXFont"): ["AXFontName": "Helvetica-Oblique"]])
        #expect(style.italic)
    }

    @Test func plainRunHasNoStyle() {
        #expect(runStyle(from: [:]) == RunStyle())
    }
}
#endif
