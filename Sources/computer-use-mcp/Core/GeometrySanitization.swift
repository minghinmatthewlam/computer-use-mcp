
import Foundation

/// Geometry from AX/CoreGraphics/JavaScript can cross process boundaries with
/// NaN or infinite components. Swift traps when such values are converted to
/// Int, so centralize the finite/range checks before formatting or scaling.
func sanitizedRect(_ rect: CGRect) -> CGRect? {
    guard rect.origin.x.isFinite, rect.origin.y.isFinite,
        rect.size.width.isFinite, rect.size.height.isFinite
    else { return nil }
    return rect
}

func sanitizedPoint(_ point: CGPoint) -> CGPoint? {
    guard point.x.isFinite, point.y.isFinite else { return nil }
    return point
}

func safeInt(_ value: Double) -> Int? {
    // Double(Int.max) rounds up to 2^63 on 64-bit platforms, which is just
    // outside Int's range and would still trap. Require the upper bound to be
    // strictly below that rounded value; Int.min is exactly representable.
    guard value.isFinite, value >= Double(Int.min), value < Double(Int.max) else { return nil }
    return Int(value)
}

func safeInt(_ value: CGFloat) -> Int? {
    safeInt(Double(value))
}

func safeRoundedInt(_ value: Double) -> Int? {
    guard value.isFinite else { return nil }
    return safeInt(value.rounded())
}

func safeRoundedInt(_ value: CGFloat) -> Int? {
    safeRoundedInt(Double(value))
}

func integerDescription(_ value: Double) -> String {
    safeInt(value).map { String($0) } ?? "?"
}

func integerDescription(_ value: CGFloat) -> String {
    safeInt(value).map { String($0) } ?? "?"
}

func roundedIntegerDescription(_ value: Double) -> String {
    safeRoundedInt(value).map { String($0) } ?? "?"
}

func roundedIntegerDescription(_ value: CGFloat) -> String {
    safeRoundedInt(value).map { String($0) } ?? "?"
}
