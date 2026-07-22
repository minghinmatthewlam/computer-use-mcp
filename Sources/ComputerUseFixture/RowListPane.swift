#if os(macOS)
import AppKit
import SwiftUI

// A virtualized list of 500 rows, backed by a real AppKit NSScrollView +
// NSTableView bridged into SwiftUI. SwiftUI's own List (used previously) is an
// NSTableView-in-a-ScrollView whose AXScrollDownByPage is advertised but a
// no-op in the background, so a background agent could route a scroll correctly
// yet move nothing. A plain NSScrollView honors the AX page-scroll actions, so
// the truth suite can prove tier-1 AX-action scrolling actually moves the list.
//
// NSTableView still virtualizes — only rows in (or near) the viewport are
// realized — so the AX tree exposes a small windowed subset at any scroll
// position (the dense-collection viewport-windowing case), and it natively
// exposes AXRows / AXVisibleRows. Row values are zero-padded ("Row 001" ..
// "Row 500") so ordering is lexicographically stable and each row is uniquely
// addressable. The table is AX-labeled "row-list" (role AXTable).
struct RowListPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Virtualized List (500 rows)").font(.headline)
            AppKitRowList()
                .frame(width: 300, height: 300)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
    }
}

private let rowCount = 500
private let cellIdentifier = NSUserInterfaceItemIdentifier("row-cell")

struct AppKitRowList: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.width = 260
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.setAccessibilityLabel("row-list")
        table.setAccessibilityIdentifier("row-list")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = false
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let label = String(format: "Row %03d", row + 1)
            let field =
                tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? NSTextField
                ?? {
                    let made = NSTextField(labelWithString: "")
                    made.identifier = cellIdentifier
                    return made
                }()
            field.stringValue = label
            field.setAccessibilityLabel(label)
            return field
        }
    }
}
#endif
