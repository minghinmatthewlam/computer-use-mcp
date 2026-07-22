#if os(macOS)
import SwiftUI
import WebKit

// A WKWebView loading a self-contained local HTML page: a heading, a link, a
// button that mutates the DOM (so a read-act-read verifier can confirm the web
// AX value changed), and a long scrollable article. Exercises web-AX exposure
// and progressive skeleton traversal into web content. The HTML is embedded as
// a string (loadHTMLString) so the fixture needs no bundled resource files and
// stays byte-for-byte deterministic.
struct WebPane: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.setAccessibilityLabel("web-pane")
        webView.loadHTMLString(Self.html, baseURL: URL(string: "https://fixture.local/"))
        return webView
    }
    func updateNSView(_ webView: WKWebView, context: Context) {}

    static let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Fixture Web Pane</title>
          <style>
            body { font: 15px -apple-system, system-ui, sans-serif; margin: 16px; color: #222; }
            h1 { font-size: 20px; }
            #mutable { padding: 6px; border: 1px solid #ccc; border-radius: 4px; }
            button { margin: 8px 0; padding: 6px 10px; }
            p { line-height: 1.5; }
          </style>
        </head>
        <body>
          <h1 id="web-heading">Fixture Web Heading</h1>
          <p><a id="web-link" href="https://fixture.local/target">Fixture Web Link</a></p>
          <button id="web-mutate-button" onclick="document.getElementById('mutable').textContent = 'mutated';">
            Mutate DOM
          </button>
          <p id="mutable">unmutated</p>
          <p><input id="web-text-field" type="text" placeholder="web text field" aria-label="web-text-field"></p>
          <article id="web-article">
            \(Array(1...40).map { "<p>Article paragraph \($0). Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.</p>" }.joined(separator: "\n"))
          </article>
        </body>
        </html>
        """
}
#endif
