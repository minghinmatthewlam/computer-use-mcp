#if os(macOS)
import CoreGraphics
#endif
import Foundation
import Testing

@testable import computer_use_mcp

@Suite struct DragGuardTests {
    @Test func completedDragReleasesAtDestination() {
        let from = CGPoint(x: 10, y: 20)
        let to = CGPoint(x: 300, y: 400)
        #expect(dragReleasePoint(from: from, to: to, aborted: false) == to)
    }

    @Test func abortedDragReleasesAtOrigin() {
        let from = CGPoint(x: 10, y: 20)
        let to = CGPoint(x: 300, y: 400)
        #expect(dragReleasePoint(from: from, to: to, aborted: true) == from)
    }
}
