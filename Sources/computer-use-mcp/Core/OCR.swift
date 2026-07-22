// OCR fallback via the Vision framework: reads on-screen text (with
// screenshot-pixel boxes) out of a window capture, for apps whose
// accessibility tree is missing or empty — custom-drawn UIs, games,
// remote-desktop and virtualization windows.

import Foundation
#if os(macOS)
import CoreGraphics
import Vision
#endif

struct OCRLine: Sendable {
    let text: String
    /// x, y, w, h in screenshot pixels (top-left origin).
    let box: [Int]
}

 #if os(macOS)
func recognizeText(inPNG pngData: Data, pixelWidth: Int, pixelHeight: Int) async throws -> [OCRLine] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    let handler = VNImageRequestHandler(data: pngData)
    // Vision's perform is synchronous CPU work; keep it off the caller.
    return try await Task.detached(priority: .userInitiated) {
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRLine(
                text: candidate.string,
                box: pixelBox(normalized: observation.boundingBox, width: pixelWidth, height: pixelHeight)
            )
        }
    }.value
}
#else
func recognizeText(inPNG pngData: Data, pixelWidth: Int, pixelHeight: Int) async throws -> [OCRLine] {
    throw ToolError.notImplemented("OCR is unsupported on Linux.")
}
#endif

/// Vision boxes are normalized with a bottom-left origin; screenshots use
/// top-left pixel coordinates.
func pixelBox(normalized: CGRect, width: Int, height: Int) -> [Int] {
    [
        safeRoundedInt(normalized.minX * Double(width)) ?? 0,
        safeRoundedInt((1 - normalized.maxY) * Double(height)) ?? 0,
        safeRoundedInt(normalized.width * Double(width)) ?? 0,
        safeRoundedInt(normalized.height * Double(height)) ?? 0,
    ]
}
