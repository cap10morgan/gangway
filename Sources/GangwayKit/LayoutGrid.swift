import Foundation

/// A Mac's stable identity: the hex of its long-term public key. Not a UUID, because
/// the identity a peer proves during the handshake is the thing an arrangement must
/// refer to; anything else could drift out of step with who is actually connected.
public typealias DeviceID = String

/// Where a Mac sits in the arrangement. Column increases to the right, row downward,
/// matching the screen coordinate convention used everywhere else in Gangway.
public struct GridPosition: Hashable, Codable, Sendable {
    public var column: Int
    public var row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }

    public func neighbour(_ edge: ScreenEdge) -> GridPosition {
        switch edge {
        case .left:   return GridPosition(column: column - 1, row: row)
        case .right:  return GridPosition(column: column + 1, row: row)
        case .top:    return GridPosition(column: column, row: row - 1)
        case .bottom: return GridPosition(column: column, row: row + 1)
        }
    }
}

/// The arrangement of Macs, as a sparse grid.
///
/// Replaces the earlier "peer is on my left/right" model, which could describe only two
/// Macs and had no way to express, say, a laptop below a desktop that is itself to the
/// right of a third machine. Edges are *derived* from adjacency rather than stored, so
/// the arrangement cannot contradict itself: a peer that is to my right necessarily has
/// me on its left.
public struct ScreenLayoutGrid: Codable, Sendable, Equatable {

    public struct Placement: Codable, Sendable, Equatable, Identifiable {
        public var id: DeviceID
        public var position: GridPosition
        /// Shown in the editor; the identity is the UUID.
        public var name: String

        public init(id: DeviceID, position: GridPosition, name: String) {
            self.id = id
            self.position = position
            self.name = name
        }
    }

    public private(set) var placements: [Placement]

    /// When this arrangement was last edited. An arrangement describes where the Macs
    /// sit relative to each other, which is the same fact on every Mac, so they share
    /// one and the most recently edited copy wins.
    public private(set) var updatedAt: Date

    public init(placements: [Placement] = [], updatedAt: Date = .distantPast) {
        self.placements = placements
        self.updatedAt = updatedAt
    }

    /// True when `other` describes a newer arrangement than this one.
    public func isSuperseded(by other: ScreenLayoutGrid) -> Bool {
        other.updatedAt > updatedAt
    }

    private mutating func touch() {
        updatedAt = Date()
    }

    // MARK: - Lookup

    public func placement(of id: DeviceID) -> Placement? {
        placements.first { $0.id == id }
    }

    public func placement(at position: GridPosition) -> Placement? {
        placements.first { $0.position == position }
    }

    public func position(of id: DeviceID) -> GridPosition? {
        placement(of: id)?.position
    }

    /// The Mac immediately beyond `edge` from `id`, if any.
    public func neighbour(of id: DeviceID, edge: ScreenEdge) -> DeviceID? {
        guard let from = position(of: id) else { return nil }
        return placement(at: from.neighbour(edge))?.id
    }

    /// The edge of `from` that leads to `to`, or nil when they are not adjacent.
    ///
    /// Only orthogonal adjacency counts. Diagonal neighbours are deliberately not
    /// reachable: a pointer leaving a corner has no unambiguous destination, and
    /// guessing produces transitions the user did not ask for.
    public func edge(from: DeviceID, to: DeviceID) -> ScreenEdge? {
        guard let a = position(of: from), let b = position(of: to) else { return nil }
        for edge in ScreenEdge.allCases where a.neighbour(edge) == b {
            return edge
        }
        return nil
    }

    /// The edge-keyed layout `EdgeDetector` needs, as seen from `id`.
    public func layout(for id: DeviceID) -> Layout {
        var edges: [ScreenEdge: DeviceID] = [:]
        for edge in ScreenEdge.allCases {
            if let peer = neighbour(of: id, edge: edge) { edges[edge] = peer }
        }
        return Layout(placements: edges)
    }

    // MARK: - Editing

    /// Place a Mac, moving it if already present. A cell holds one Mac, so placing onto
    /// an occupied cell swaps the two rather than silently discarding one.
    public mutating func place(_ id: DeviceID, name: String, at position: GridPosition) {
        let existing = placement(of: id)
        if let occupant = placement(at: position), occupant.id != id {
            if let previous = existing?.position {
                setPosition(previous, for: occupant.id)
            } else {
                remove(occupant.id)
            }
        }
        if existing != nil {
            setPosition(position, for: id)
        } else {
            placements.append(Placement(id: id, position: position, name: name))
        }
        touch()
    }

    private mutating func setPosition(_ position: GridPosition, for id: DeviceID) {
        guard let index = placements.firstIndex(where: { $0.id == id }) else { return }
        placements[index].position = position
    }

    public mutating func remove(_ id: DeviceID) {
        placements.removeAll { $0.id == id }
        touch()
    }

    public mutating func rename(_ id: DeviceID, to name: String) {
        guard let index = placements.firstIndex(where: { $0.id == id }) else { return }
        placements[index].name = name
    }

    /// Smallest rectangle containing every placed Mac, for laying out the editor.
    public var extent: (columns: ClosedRange<Int>, rows: ClosedRange<Int>) {
        guard let first = placements.first else { return (0...0, 0...0) }
        var minC = first.position.column, maxC = minC
        var minR = first.position.row, maxR = minR
        for p in placements.dropFirst() {
            minC = min(minC, p.position.column); maxC = max(maxC, p.position.column)
            minR = min(minR, p.position.row);    maxR = max(maxR, p.position.row)
        }
        return (minC...maxC, minR...maxR)
    }

    /// Cells a Mac could be dragged to: every free cell orthogonally touching an
    /// occupied one. Offering the whole plane would let a user strand a Mac with no
    /// path to it, which reads as the arrangement being broken.
    public var availableCells: Set<GridPosition> {
        var cells: Set<GridPosition> = []
        for placement in placements {
            for edge in ScreenEdge.allCases {
                let candidate = placement.position.neighbour(edge)
                if self.placement(at: candidate) == nil { cells.insert(candidate) }
            }
        }
        return cells
    }

    /// True when every Mac is reachable from `id` by walking orthogonal neighbours.
    /// A disconnected arrangement is legal to store but means some Mac cannot be
    /// reached with the pointer.
    public func isConnected(from id: DeviceID) -> Bool {
        guard placement(of: id) != nil else { return placements.isEmpty }
        var seen: Set<DeviceID> = [id]
        var queue = [id]
        while let current = queue.popLast() {
            for edge in ScreenEdge.allCases {
                guard let next = neighbour(of: current, edge: edge), !seen.contains(next) else { continue }
                seen.insert(next)
                queue.append(next)
            }
        }
        return seen.count == placements.count
    }
}
