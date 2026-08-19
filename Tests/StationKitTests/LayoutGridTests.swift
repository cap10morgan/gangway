import XCTest
@testable import StationKit

final class ScreenLayoutGridTests: XCTestCase {

    private let local: DeviceID = "aa00"
    private let peerA: DeviceID = "bb11"
    private let peerB: DeviceID = "cc22"

    private func grid(_ entries: [(DeviceID, Int, Int)]) -> ScreenLayoutGrid {
        var grid = ScreenLayoutGrid()
        for (id, column, row) in entries {
            grid.place(id, name: id, at: GridPosition(column: column, row: row))
        }
        return grid
    }

    // MARK: - Adjacency

    func testDerivesEdgeFromAdjacency() {
        let g = grid([(local, 0, 0), (peerA, 1, 0)])
        XCTAssertEqual(g.edge(from: local, to: peerA), .right)
        // Derived, so it cannot contradict itself.
        XCTAssertEqual(g.edge(from: peerA, to: local), .left)
    }

    func testVerticalAdjacencyUsesDownwardPositiveRows() {
        let g = grid([(local, 0, 0), (peerA, 0, 1)])
        XCTAssertEqual(g.edge(from: local, to: peerA), .bottom)
        XCTAssertEqual(g.edge(from: peerA, to: local), .top)
    }

    /// A pointer leaving a corner has no unambiguous destination, so diagonals must not
    /// be treated as adjacent.
    func testDiagonalIsNotAdjacent() {
        let g = grid([(local, 0, 0), (peerA, 1, 1)])
        XCTAssertNil(g.edge(from: local, to: peerA))
        XCTAssertNil(g.neighbour(of: local, edge: .right))
    }

    func testDistantMacsAreNotAdjacent() {
        let g = grid([(local, 0, 0), (peerA, 3, 0)])
        XCTAssertNil(g.edge(from: local, to: peerA))
    }

    func testLayoutForEdgeDetectorCoversEveryNeighbour() {
        let g = grid([(local, 1, 1), (peerA, 2, 1), (peerB, 1, 0)])
        let layout = g.layout(for: local)
        XCTAssertEqual(layout.peer(at: .right), peerA)
        XCTAssertEqual(layout.peer(at: .top), peerB)
        XCTAssertNil(layout.peer(at: .left))
        XCTAssertNil(layout.peer(at: .bottom))
    }

    func testLayoutIsRelativeToTheMacAsking() {
        let g = grid([(local, 0, 0), (peerA, 1, 0)])
        XCTAssertEqual(g.layout(for: peerA).peer(at: .left), local)
        XCTAssertNil(g.layout(for: peerA).peer(at: .right))
    }

    // MARK: - Editing

    func testPlacingMovesRatherThanDuplicates() {
        var g = grid([(local, 0, 0), (peerA, 1, 0)])
        g.place(peerA, name: "A", at: GridPosition(column: 0, row: 1))
        XCTAssertEqual(g.placements.count, 2)
        XCTAssertEqual(g.position(of: peerA), GridPosition(column: 0, row: 1))
        XCTAssertNil(g.neighbour(of: local, edge: .right))
        XCTAssertEqual(g.neighbour(of: local, edge: .bottom), peerA)
    }

    /// Dropping onto an occupied cell swaps, rather than silently discarding a Mac.
    func testPlacingOntoOccupiedCellSwaps() {
        var g = grid([(local, 0, 0), (peerA, 1, 0)])
        g.place(peerA, name: "A", at: GridPosition(column: 0, row: 0))
        XCTAssertEqual(g.placements.count, 2)
        XCTAssertEqual(g.position(of: peerA), GridPosition(column: 0, row: 0))
        XCTAssertEqual(g.position(of: local), GridPosition(column: 1, row: 0))
    }

    func testRemovingAMac() {
        var g = grid([(local, 0, 0), (peerA, 1, 0)])
        g.remove(peerA)
        XCTAssertNil(g.position(of: peerA))
        XCTAssertNil(g.neighbour(of: local, edge: .right))
    }

    func testRenaming() {
        var g = grid([(local, 0, 0)])
        g.rename(local, to: "Studio")
        XCTAssertEqual(g.placement(of: local)?.name, "Studio")
    }

    // MARK: - Editor support

    func testAvailableCellsTouchAnOccupiedCell() {
        let g = grid([(local, 0, 0)])
        let cells = g.availableCells
        XCTAssertEqual(cells.count, 4)
        XCTAssertTrue(cells.contains(GridPosition(column: 1, row: 0)))
        XCTAssertTrue(cells.contains(GridPosition(column: 0, row: -1)))
        XCTAssertFalse(cells.contains(GridPosition(column: 0, row: 0)), "occupied")
        XCTAssertFalse(cells.contains(GridPosition(column: 5, row: 5)), "stranded")
    }

    func testExtentSpansAllPlacements() {
        let g = grid([(local, 0, 0), (peerA, 2, 0), (peerB, 0, -1)])
        let extent = g.extent
        XCTAssertEqual(extent.columns, 0...2)
        XCTAssertEqual(extent.rows, -1...0)
    }

    func testConnectedArrangement() {
        XCTAssertTrue(grid([(local, 0, 0), (peerA, 1, 0), (peerB, 2, 0)]).isConnected(from: local))
    }

    /// A Mac with no orthogonal path from the local one cannot be reached by pointer.
    func testDisconnectedArrangementIsDetected() {
        var g = grid([(local, 0, 0), (peerA, 1, 0)])
        g.place(peerB, name: "B", at: GridPosition(column: 9, row: 9))
        XCTAssertFalse(g.isConnected(from: local))
    }

    func testEmptyGridEdgeCases() {
        let g = ScreenLayoutGrid()
        XCTAssertNil(g.position(of: local))
        XCTAssertTrue(g.availableCells.isEmpty)
        XCTAssertTrue(g.isConnected(from: local))
    }

    func testRoundTripsThroughCodable() throws {
        let g = grid([(local, 0, 0), (peerA, 1, 0), (peerB, 1, 1)])
        let data = try JSONEncoder().encode(g)
        XCTAssertEqual(try JSONDecoder().decode(ScreenLayoutGrid.self, from: data), g)
    }
}

final class LayoutSharingTests: XCTestCase {

    private let a: DeviceID = "aa00"
    private let b: DeviceID = "bb11"

    /// An arrangement describes the same fact on every Mac, so the most recently
    /// edited copy should win rather than each Mac keeping its own view.
    func testNewerArrangementSupersedesOlder() {
        var old = ScreenLayoutGrid()
        old.place(a, name: "A", at: GridPosition(column: 0, row: 0))

        var new = ScreenLayoutGrid()
        new.place(a, name: "A", at: GridPosition(column: 0, row: 0))
        new.place(b, name: "B", at: GridPosition(column: 1, row: 0))

        XCTAssertTrue(old.isSuperseded(by: new))
        XCTAssertFalse(new.isSuperseded(by: old))
    }

    /// An unedited arrangement must never win over an edited one, or a Mac that has
    /// never been arranged would wipe out everyone else's layout on connect.
    func testUntouchedArrangementNeverSupersedes() {
        var edited = ScreenLayoutGrid()
        edited.place(a, name: "A", at: GridPosition(column: 0, row: 0))
        XCTAssertFalse(edited.isSuperseded(by: ScreenLayoutGrid()))
    }

    func testEditingUpdatesTheTimestamp() {
        var grid = ScreenLayoutGrid()
        grid.place(a, name: "A", at: GridPosition(column: 0, row: 0))
        let first = grid.updatedAt
        grid.place(b, name: "B", at: GridPosition(column: 1, row: 0))
        XCTAssertGreaterThan(grid.updatedAt, first)
    }

    func testRemovalCountsAsAnEdit() {
        var grid = ScreenLayoutGrid()
        grid.place(a, name: "A", at: GridPosition(column: 0, row: 0))
        let before = grid.updatedAt
        grid.remove(a)
        XCTAssertGreaterThan(grid.updatedAt, before)
    }

    /// The arrangement travels verbatim, so it must survive the wire unchanged.
    func testSurvivesEncodingForTransport() throws {
        var grid = ScreenLayoutGrid()
        grid.place(a, name: "A", at: GridPosition(column: 0, row: 0))
        grid.place(b, name: "B", at: GridPosition(column: 0, row: 1))
        let decoded = try JSONDecoder().decode(ScreenLayoutGrid.self,
                                               from: JSONEncoder().encode(grid))
        XCTAssertEqual(decoded, grid)
        XCTAssertEqual(decoded.layout(for: a).peer(at: .bottom), b)
    }
}
