import XCTest
@testable import StationInput

/// Two links to the same peer must resolve to the same survivor on both Macs.
///
/// Each end only knows the order in which *it* learned about the links, and the two
/// orders can differ. Anything that depends on that order lets each end keep a
/// different connection and cancel the one the other is using.
final class DuplicateLinkTests: XCTestCase {

    /// A link, described only by what both ends agree on.
    private struct Link: Equatable { let name: String; let dialledByLowerID: Bool }

    /// The link one end keeps, given the order it saw them in.
    private func survivor(first: Link, then second: Link) -> Link {
        SessionController.keepsNewcomer(incumbentDialledByLowerID: first.dialledByLowerID,
                                        newcomerDialledByLowerID: second.dialledByLowerID)
            ? second : first
    }

    func testSimultaneousDialsResolveToTheSameLinkWhateverTheArrivalOrder() {
        let fromLower = Link(name: "dialled by lower", dialledByLowerID: true)
        let fromHigher = Link(name: "dialled by higher", dialledByLowerID: false)

        let oneEnd = survivor(first: fromLower, then: fromHigher)
        let otherEnd = survivor(first: fromHigher, then: fromLower)

        XCTAssertEqual(oneEnd, otherEnd, "the two Macs kept different connections")
        XCTAssertEqual(oneEnd, fromLower)
    }

    func testARedialFromTheSameMacReplacesTheLinkItGaveUpOn() {
        for lower in [true, false] {
            let abandoned = Link(name: "abandoned", dialledByLowerID: lower)
            let redial = Link(name: "redial", dialledByLowerID: lower)
            // Dials from one Mac are at least a cooldown apart, so both ends see this order.
            XCTAssertEqual(survivor(first: abandoned, then: redial), redial)
        }
    }
}
