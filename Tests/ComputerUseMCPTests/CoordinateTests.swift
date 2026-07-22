 #if os(macOS)
import CoreGraphics
#endif
import Foundation
import Testing

@testable import computer_use_mcp

private func makeSnapshot(
    pixelsPerPoint: Double = 2, windowSize: [Double]? = [460, 816]
) -> AppSnapshot {
    AppSnapshot(
        pid: 1, bundleIdentifier: "com.example.test", windowTitle: "Test",
        windowOrigin: [100, 50], pixelsPerPoint: pixelsPerPoint, windowSize: windowSize,
        createdAt: Date(timeIntervalSince1970: 0), generation: "s1",
        elements: [
            SnapshotElement(id: "e0@s1", role: "AXWindow", label: "Test", path: [], frame: [0, 0, 460, 816])
        ]
    )
}

@Suite struct CoordinateTests {
    @Test func pixelToPointConversion() {
        let snapshot = makeSnapshot()
        let point = snapshot.screenPoint(fromScreenshotX: 230, y: 408)
        // 230 px at 2x = 115 pt, plus the window origin.
        #expect(abs(point.x - 215.0) < 0.001)
        #expect(abs(point.y - 254.0) < 0.001)
    }

    @Test func boundsRejectEdgeAndBeyond() {
        let snapshot = makeSnapshot()
        #expect(throws: (any Error).self) { _ = try screenPoint(x: 460, y: 10, snapshot: snapshot) }
        #expect(throws: (any Error).self) { _ = try screenPoint(x: 10, y: 816, snapshot: snapshot) }
        #expect(throws: (any Error).self) { _ = try screenPoint(x: -1, y: 10, snapshot: snapshot) }
        #expect(throws: (any Error).self) { _ = try screenPoint(x: 9999, y: 10, snapshot: snapshot) }
    }

    @Test func boundsRejectNonFiniteCoordinatesAndSnapshotSize() {
        let snapshot = makeSnapshot()
        #expect(throws: (any Error).self) { _ = try screenPoint(x: .nan, y: 10, snapshot: snapshot) }
        #expect(throws: (any Error).self) { _ = try screenPoint(x: .infinity, y: 10, snapshot: snapshot) }
        #expect(throws: (any Error).self) { _ = try screenPoint(x: -.infinity, y: 10, snapshot: snapshot) }

        let badSize = makeSnapshot(windowSize: [.nan, 816])
        #expect(throws: (any Error).self) { _ = try screenPoint(x: 10, y: 10, snapshot: badSize) }
    }

    @Test func safeIntRejectsNonFiniteAndUnrepresentableValues() {
        #expect(safeInt(Double.nan) == nil)
        #expect(safeInt(Double.infinity) == nil)
        #expect(safeInt(-Double.infinity) == nil)
        #expect(safeInt(Double(Int.max)) == nil)
        #expect(safeInt(Double(Int.min)) == Int.min)
        #expect(safeInt(42.0) == 42)
    }

    @Test func boundsAcceptInterior() throws {
        let snapshot = makeSnapshot()
        let point = try screenPoint(x: 459, y: 815, snapshot: snapshot)
        #expect(point.x > 0)
    }

    @Test func decodesLegacySnapshotWithoutWindowSize() throws {
        // Old persisted snapshots predate windowSize; decoding must not fail
        // and bounds checks must fall back to the first element's box.
        var json = try String(data: JSONEncoder().encode(makeSnapshot()), encoding: .utf8)!
        json = json.replacingOccurrences(of: #""windowSize":[460,816],"#, with: "")
        json = json.replacingOccurrences(of: #","windowSize":[460,816]"#, with: "")
        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: Data(json.utf8))
        #expect(decoded.windowSize == nil)
        _ = try screenPoint(x: 10, y: 10, snapshot: decoded)
    }

    @Test func screenshotDetailScales() {
        #expect(ScreenshotDetail.full.scale(forDisplayScale: 2) == 2)
        #expect(ScreenshotDetail.full.scale(forDisplayScale: 3) == 3)
        #expect(ScreenshotDetail.full.scale(forDisplayScale: 1) == 2)  // headless misreport floor
        #expect(ScreenshotDetail.reduced.scale(forDisplayScale: 2) == 1)
        #expect(ScreenshotDetail.full.maxDimension == 1600)
        #expect(ScreenshotDetail.reduced.maxDimension == 1000)
    }

    @Test func treeFingerprintIgnoresIDsButNotContent() {
        let a = "e0@s1 AXWindow \"Test\" (0,0,10,10)\n\te1@s1 AXButton \"OK\" (1,1,2,2)"
        let b = "e0@s7 AXWindow \"Test\" (0,0,10,10)\n\te1@s7 AXButton \"OK\" (1,1,2,2)"
        let c = "e0@s8 AXWindow \"Test\" (0,0,10,10)\n\te1@s8 AXButton \"Cancel\" (1,1,2,2)"
        #expect(treeFingerprint(a) == treeFingerprint(b))
        #expect(treeFingerprint(a) != treeFingerprint(c))
    }

    @Test func visionBoxConvertsToTopLeftPixels() {
        // Vision: normalized, bottom-left origin. A box hugging the top-left
        // corner of the image must land at pixel (0,0).
        let top = pixelBox(normalized: CGRect(x: 0, y: 0.9, width: 0.5, height: 0.1), width: 1000, height: 800)
        #expect(top == [0, 0, 500, 80])
        let bottom = pixelBox(normalized: CGRect(x: 0.5, y: 0, width: 0.25, height: 0.5), width: 1000, height: 800)
        #expect(bottom == [500, 400, 250, 400])
    }

    @Test func visionBoxFallsBackToZeroForNonFiniteInput() {
        let box = pixelBox(normalized: CGRect(x: CGFloat.nan, y: 0, width: CGFloat.infinity, height: 0.5), width: 1000, height: 800)
        #expect(box == [0, 400, 0, 400])
    }

    @Test func locatorRoundTrip() throws {
        let path = [LocatorStep(role: "AXGroup", indexOfRole: 0), LocatorStep(role: "AXButton", indexOfRole: 3)]
        let data = try JSONEncoder().encode(path)
        let decoded = try JSONDecoder().decode([LocatorStep].self, from: data)
        #expect(decoded.count == 2)
        #expect(decoded[1].role == "AXButton")
        #expect(decoded[1].indexOfRole == 3)
    }
}
