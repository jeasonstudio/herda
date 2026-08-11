import XCTest
@testable import HerdrKit

final class ScrollAccumulatorTests: XCTestCase {
    private func accumulator() -> ScrollAccumulator {
        ScrollAccumulator(threshold: 17)
    }

    func testZeroDeltaProducesNothing() {
        var subject = accumulator()
        XCTAssertEqual(subject.steps(delta: 0, precise: true), 0)
    }

    /// The bug this exists for: a trackpad reports a delta per frame and keeps
    /// reporting through momentum, so one step per event sends dozens per flick.
    func testTravelBelowOneCellProducesNothing() {
        var subject = accumulator()
        XCTAssertEqual(subject.steps(delta: 4, precise: true), 0)
        XCTAssertEqual(subject.steps(delta: 4, precise: true), 0)
        XCTAssertEqual(subject.steps(delta: 4, precise: true), 0)
    }

    func testAccumulatedTravelEventuallyStepsOnce() {
        var subject = accumulator()
        var total = 0
        for _ in 0 ..< 5 { total += subject.steps(delta: 4, precise: true) }
        XCTAssertEqual(total, 1, "20 points of travel is one 17-point cell")
    }

    func testRemainderCarriesToTheNextEvent() {
        var subject = accumulator()
        XCTAssertEqual(subject.steps(delta: 20, precise: true), 1)
        // 3 points carried over, so 14 more completes the second cell.
        XCTAssertEqual(subject.steps(delta: 14, precise: true), 1)
    }

    func testOneLargeDeltaProducesProportionalSteps() {
        var subject = accumulator()
        XCTAssertEqual(subject.steps(delta: 17 * 4, precise: true), 4)
    }

    func testDirectionIsCarriedBySign() {
        var subject = accumulator()
        XCTAssertEqual(subject.steps(delta: -34, precise: true), -2)
    }

    /// A remainder held over from the opposite direction would otherwise swallow
    /// the first step of the reversal.
    func testReversalDiscardsTheOppositeRemainder() {
        var subject = accumulator()
        _ = subject.steps(delta: 16, precise: true) // 16 points pending, no step
        XCTAssertEqual(subject.steps(delta: -17, precise: true), -1)
    }

    func testResetDropsPartialTravel() {
        var subject = accumulator()
        _ = subject.steps(delta: 16, precise: true)
        subject.reset()
        XCTAssertEqual(subject.steps(delta: 4, precise: true), 0)
    }

    // MARK: - Wheels

    func testAWheelNotchIsNotAccumulated() {
        var subject = accumulator()
        XCTAssertEqual(subject.steps(delta: 1, precise: false), ScrollAccumulator.stepsPerNotch)
    }

    func testWheelDirectionIsCarriedBySign() {
        var subject = accumulator()
        XCTAssertEqual(subject.steps(delta: -1, precise: false), -ScrollAccumulator.stepsPerNotch)
    }

    func testMultipleNotchesInOneEventScale() {
        var subject = accumulator()
        XCTAssertEqual(subject.steps(delta: 3, precise: false), 3 * ScrollAccumulator.stepsPerNotch)
    }

    func testWheelDiscardsAnyContinuousRemainder() {
        var subject = accumulator()
        _ = subject.steps(delta: 16, precise: true)
        _ = subject.steps(delta: 1, precise: false)
        XCTAssertEqual(subject.steps(delta: 4, precise: true), 0, "remainder should have been cleared")
    }

    func testThresholdIsNeverZero() {
        var subject = ScrollAccumulator(threshold: 0)
        XCTAssertEqual(subject.steps(delta: 1, precise: true), 1)
    }
}
