import XCTest
@testable import StationInput

/// When a Mac dials a paired peer it has no link to.
final class RedialTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    private func dials(hasLink: Bool = false, winsTieBreak: Bool,
                       lastDialAt: Date? = nil, unlinkedSince: Date?) -> Bool {
        SessionController.shouldDial(hasLink: hasLink, winsTieBreak: winsTieBreak,
                                     lastDialAt: lastDialAt, unlinkedSince: unlinkedSince,
                                     now: now)
    }

    func testNeverDialsAPeerItAlreadyHasALinkTo() {
        XCTAssertFalse(dials(hasLink: true, winsTieBreak: true, unlinkedSince: ago(60)))
    }

    func testTheTieBreakWinnerDialsAtOnce() {
        XCTAssertTrue(dials(winsTieBreak: true, unlinkedSince: ago(0)))
    }

    /// The Mac that loses the tie-break used to wait forever after launching, because
    /// it had never *lost* a link. Discovery now records when it first saw the peer
    /// unlinked, and from then on the ordinary delay applies.
    func testTheLoserDialsOnceThePeerHasBeenUnlinkedLongEnough() {
        let delay = SessionController.opposingRedialDelay
        XCTAssertFalse(dials(winsTieBreak: false, unlinkedSince: ago(delay - 1)))
        XCTAssertTrue(dials(winsTieBreak: false, unlinkedSince: ago(delay + 1)))
    }

    func testTheLoserWithNoRecordOfBeingUnlinkedHoldsOff() {
        XCTAssertFalse(dials(winsTieBreak: false, unlinkedSince: nil))
    }

    func testADialStillInFlightBlocksAnother() {
        let inFlight = ago(SessionController.dialCooldown - 1)
        XCTAssertFalse(dials(winsTieBreak: true, lastDialAt: inFlight, unlinkedSince: ago(60)))
    }

    /// A refused dial is over the moment it is refused. Its record is cleared then, so
    /// the next sweep tries again instead of sitting out the rest of a cooldown meant
    /// for dials that are still running.
    func testAFinishedDialDoesNotBlockTheNextSweep() {
        XCTAssertTrue(dials(winsTieBreak: true, lastDialAt: nil, unlinkedSince: ago(1)))
    }
}
