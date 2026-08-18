import XCTest
import CoreGraphics
@testable import StationKit

final class EdgeDetectorTests: XCTestCase {

    private let laptop = Rect(x: 0, y: 0, width: 1440, height: 900)
    private let peerID = UUID()

    private func detector(_ edge: ScreenEdge) -> EdgeDetector {
        EdgeDetector(bounds: laptop, layout: Layout(placements: [edge: peerID]))
    }

    func testCrossesRightEdgeWhenPushingOutward() throws {
        let crossing = try XCTUnwrap(detector(.right).crossing(
            cursor: CGPoint(x: 1439, y: 450), delta: CGPoint(x: 5, y: 0)))
        XCTAssertEqual(crossing.peer, peerID)
        XCTAssertEqual(crossing.edge, .right)
        // Enters on the peer's LEFT edge, at the same relative height.
        XCTAssertEqual(crossing.entry.x, 0.0)
        XCTAssertEqual(crossing.entry.y, 0.5, accuracy: 0.001)
    }

    /// Resting against an edge must not transition, or the cursor would escape as soon
    /// as the user parks the pointer at the side of the screen.
    func testRestingOnEdgeDoesNotCross() {
        XCTAssertNil(detector(.right).crossing(
            cursor: CGPoint(x: 1439, y: 450), delta: CGPoint(x: 0, y: 0)))
    }

    func testMovingInwardFromEdgeDoesNotCross() {
        XCTAssertNil(detector(.right).crossing(
            cursor: CGPoint(x: 1439, y: 450), delta: CGPoint(x: -5, y: 0)))
    }

    func testNoCrossingWhenNoPeerOnThatEdge() {
        // Peer is on the left; pushing right must not transition anywhere.
        XCTAssertNil(detector(.left).crossing(
            cursor: CGPoint(x: 1439, y: 450), delta: CGPoint(x: 5, y: 0)))
    }

    func testCrossesLeftEdgeEnteringOnPeerRight() throws {
        let crossing = try XCTUnwrap(detector(.left).crossing(
            cursor: CGPoint(x: 0, y: 225), delta: CGPoint(x: -3, y: 0)))
        XCTAssertEqual(crossing.entry.x, 1.0)
        XCTAssertEqual(crossing.entry.y, 0.25, accuracy: 0.001)
    }

    /// Global display space has y increasing downward, so the top edge is minY.
    /// Getting this backwards silently inverts vertical transitions.
    func testCrossesTopEdgeEnteringOnPeerBottom() throws {
        let crossing = try XCTUnwrap(detector(.top).crossing(
            cursor: CGPoint(x: 720, y: 0), delta: CGPoint(x: 0, y: -4)))
        XCTAssertEqual(crossing.edge, .top)
        XCTAssertEqual(crossing.entry.y, 1.0)
        XCTAssertEqual(crossing.entry.x, 0.5, accuracy: 0.001)
    }

    func testCrossesBottomEdgeEnteringOnPeerTop() throws {
        let crossing = try XCTUnwrap(detector(.bottom).crossing(
            cursor: CGPoint(x: 360, y: 899), delta: CGPoint(x: 0, y: 6)))
        XCTAssertEqual(crossing.entry.y, 0.0)
        XCTAssertEqual(crossing.entry.x, 0.25, accuracy: 0.001)
    }

    /// A display arrangement whose origin is not zero (external monitor left of the
    /// laptop) must still normalize correctly.
    func testHandlesNegativeOriginBounds() throws {
        let shifted = EdgeDetector(bounds: Rect(x: -2560, y: -300, width: 2560, height: 1440),
                                   layout: Layout(placements: [.right: peerID]))
        let crossing = try XCTUnwrap(shifted.crossing(
            cursor: CGPoint(x: -1, y: 420), delta: CGPoint(x: 2, y: 0)))
        XCTAssertEqual(crossing.entry.y, (420.0 - -300.0) / 1440.0, accuracy: 0.001)
    }
}

final class RemoteCursorTests: XCTestCase {

    private let peer = Rect(x: 0, y: 0, width: 2560, height: 1440)

    func testMotionMovesWithinPeer() {
        var cursor = RemoteCursor(entry: NormalizedPoint(x: 0, y: 0.5), peerBounds: peer)
        guard case .moved(let p) = cursor.apply(deltaX: 256, deltaY: 0) else {
            return XCTFail("expected movement, not an exit")
        }
        XCTAssertEqual(p.x, 0.1, accuracy: 0.0001)
        XCTAssertEqual(p.y, 0.5, accuracy: 0.0001)
    }

    func testExitsBackAcrossEntryEdge() {
        var cursor = RemoteCursor(entry: NormalizedPoint(x: 0, y: 0.5), peerBounds: peer)
        // Must clear the hysteresis margin; a smaller nudge intentionally does nothing.
        let push = -(RemoteCursor.exitMarginPixels + 5)
        guard case .exited(let edge, let at) = cursor.apply(deltaX: push, deltaY: 0) else {
            return XCTFail("expected an exit")
        }
        XCTAssertEqual(edge, .left)
        XCTAssertEqual(at.y, 0.5, accuracy: 0.0001)
    }

    func testExitsOffFarSide() {
        var cursor = RemoteCursor(entry: NormalizedPoint(x: 0.99, y: 0.2), peerBounds: peer)
        guard case .exited(let edge, _) = cursor.apply(deltaX: 500, deltaY: 0) else {
            return XCTFail("expected an exit")
        }
        XCTAssertEqual(edge, .right)
    }

    func testVerticalExitUsesDownwardPositiveConvention() {
        var cursor = RemoteCursor(entry: NormalizedPoint(x: 0.5, y: 0.01), peerBounds: peer)
        guard case .exited(let edge, _) = cursor.apply(deltaX: 0, deltaY: -100) else {
            return XCTFail("expected an exit")
        }
        XCTAssertEqual(edge, .top, "negative y must exit via the top edge")
    }

    /// The same pixel delta must travel proportionally further on a smaller peer, which
    /// is what keeps pointer speed feeling consistent across mismatched displays.
    func testDeltaScalesByPeerResolution() {
        var small = RemoteCursor(entry: NormalizedPoint(x: 0, y: 0.5),
                                 peerBounds: Rect(x: 0, y: 0, width: 1280, height: 720))
        var large = RemoteCursor(entry: NormalizedPoint(x: 0, y: 0.5), peerBounds: peer)
        guard case .moved(let sp) = small.apply(deltaX: 128, deltaY: 0),
              case .moved(let lp) = large.apply(deltaX: 128, deltaY: 0) else {
            return XCTFail("expected movement")
        }
        XCTAssertEqual(sp.x, 0.1, accuracy: 0.0001)
        XCTAssertEqual(lp.x, 0.05, accuracy: 0.0001)
    }

    /// Regression: entering at exactly 0.0 and jittering backwards must NOT hand
    /// control straight back. Without a margin, control oscillates between the two
    /// Macs and the primary's cursor appears to keep moving on its own.
    func testJitterAtEntryEdgeDoesNotExit() {
        var cursor = RemoteCursor(entry: NormalizedPoint(x: 0, y: 0.5), peerBounds: peer)
        for _ in 0..<20 {
            guard case .moved = cursor.apply(deltaX: -1, deltaY: 0) else {
                return XCTFail("a single pixel of jitter must not end remote control")
            }
        }
        XCTAssertEqual(cursor.position.x, 0, "pointer should pin to the edge")
    }

    /// A deliberate push past the margin still exits.
    func testPushPastMarginExits() {
        var cursor = RemoteCursor(entry: NormalizedPoint(x: 0, y: 0.5), peerBounds: peer)
        let push = -(RemoteCursor.exitMarginPixels + 2)
        guard case .exited(let edge, _) = cursor.apply(deltaX: push, deltaY: 0) else {
            return XCTFail("expected an exit once past the margin")
        }
        XCTAssertEqual(edge, .left)
    }

    /// The margin is in peer pixels, so it must not become huge on a small display.
    func testMarginIsPixelBasedNotProportional() {
        var small = RemoteCursor(entry: NormalizedPoint(x: 0, y: 0.5),
                                 peerBounds: Rect(x: 0, y: 0, width: 800, height: 600))
        let push = -(RemoteCursor.exitMarginPixels + 2)
        guard case .exited = small.apply(deltaX: push, deltaY: 0) else {
            return XCTFail("same pixel push must exit on a small display too")
        }
    }

    /// A diagonal overshoot must resolve deterministically rather than depending on
    /// which comparison happens to run first.
    func testDiagonalOvershootPrefersHorizontalExit() {
        var cursor = RemoteCursor(entry: NormalizedPoint(x: 0.5, y: 0.5), peerBounds: peer)
        guard case .exited(let edge, _) = cursor.apply(deltaX: -5000, deltaY: -5000) else {
            return XCTFail("expected an exit")
        }
        XCTAssertEqual(edge, .left)
    }

    func testZeroSizedPeerDoesNotDivideByZero() {
        var cursor = RemoteCursor(entry: NormalizedPoint(x: 0.5, y: 0.5),
                                  peerBounds: Rect(x: 0, y: 0, width: 0, height: 0))
        guard case .moved(let p) = cursor.apply(deltaX: 100, deltaY: 100) else {
            return XCTFail("expected a no-op move")
        }
        XCTAssertEqual(p.x, 0.5)
    }
}

final class NormalizedPointTests: XCTestCase {

    func testRoundTripsThroughAbsoluteCoordinates() {
        let bounds = Rect(x: -100, y: 50, width: 1600, height: 1000)
        let original = NormalizedPoint(x: 0.3, y: 0.7)
        let back = NormalizedPoint.of(original.absolute(in: bounds), in: bounds)
        XCTAssertEqual(back.x, original.x, accuracy: 0.0001)
        XCTAssertEqual(back.y, original.y, accuracy: 0.0001)
    }

    func testClampsOutOfRangeValues() {
        let p = NormalizedPoint(x: -0.5, y: 1.8).clamped()
        XCTAssertEqual(p.x, 0)
        XCTAssertEqual(p.y, 1)
    }

    func testLayoutFindsEdgeOfPeer() {
        let peer = UUID()
        let layout = Layout(placements: [.right: peer])
        XCTAssertEqual(layout.edge(of: peer), .right)
        XCTAssertNil(layout.edge(of: UUID()))
    }
}
