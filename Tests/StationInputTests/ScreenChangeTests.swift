import XCTest
@testable import StationInput
@testable import StationKit

/// Keeping pointer positions valid when the display arrangement changes.
final class ScreenChangeTests: XCTestCase {

    private let margin = 20.0

    func testAPointOnARemovedDisplayMovesIntoTheRemainingArea() {
        // A monitor to the right of a 1728-wide built-in display is unplugged.
        let builtIn = Rect(x: 0, y: 0, width: 1728, height: 1117)
        let parkedOnExternal = CGPoint(x: 2600, y: 400)

        let moved = EventCapture.point(parkedOnExternal, inside: builtIn, margin: margin)

        XCTAssertEqual(moved, CGPoint(x: 1728 - 1 - margin, y: 400))
    }

    func testAPointAlreadyWellInsideIsLeftAlone() {
        let area = Rect(x: -1920, y: 0, width: 3648, height: 1117)
        let inside = CGPoint(x: -500, y: 600)

        XCTAssertEqual(EventCapture.point(inside, inside: area, margin: margin), inside)
    }

    func testACornerPointOnARemovedDisplayIsPulledInOnBothAxes() {
        let area = Rect(x: 0, y: 0, width: 1728, height: 1117)

        let moved = EventCapture.point(CGPoint(x: -3000, y: -900), inside: area, margin: margin)

        XCTAssertEqual(moved, CGPoint(x: margin, y: margin))
    }
}
