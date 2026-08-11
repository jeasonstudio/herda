import CoreGraphics

/// Turns one axis of AppKit scroll deltas into discrete terminal scroll steps.
///
/// A trackpad reports continuous deltas and keeps reporting them through the
/// momentum phase, so emitting one scroll step per event sends dozens of steps
/// for a single flick and the pane shoots past whatever the user was reading.
/// Accumulating until a full cell of travel has passed makes the gesture move
/// the content roughly as far as the finger moved it.
public struct ScrollAccumulator {
    /// Points of continuous travel that make one step. A cell height means one
    /// row of content per row of movement.
    public let threshold: CGFloat
    /// A wheel notch is already a discrete intent, so it is not accumulated.
    /// Three lines matches what terminals conventionally do with one notch.
    public static let stepsPerNotch = 3

    private var pending: CGFloat = 0

    public init(threshold: CGFloat) {
        self.threshold = max(1, threshold)
    }

    /// Steps to emit for this event. The sign follows `delta`.
    public mutating func steps(delta: CGFloat, precise: Bool) -> Int {
        guard delta != 0 else { return 0 }

        guard precise else {
            // Mixing a leftover continuous remainder into a notch would make
            // the notch land early or late.
            pending = 0
            let notches = max(1, Int(abs(delta).rounded()))
            return (delta > 0 ? 1 : -1) * notches * ScrollAccumulator.stepsPerNotch
        }

        // A remainder held over from the opposite direction would otherwise
        // swallow the first step of the reversal.
        if (pending > 0) != (delta > 0) { pending = 0 }

        pending += delta
        let steps = Int((pending / threshold).rounded(.towardZero))
        pending -= CGFloat(steps) * threshold
        return steps
    }

    /// Drops any partial travel — used when the pane changes under the cursor.
    public mutating func reset() {
        pending = 0
    }
}
