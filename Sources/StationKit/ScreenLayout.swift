import Foundation
import CoreGraphics

/// Which edge of the local display arrangement leads to a peer.
public enum Edge: String, Codable, Sendable, CaseIterable {
    case left, right, top, bottom

    public var opposite: Edge {
        switch self {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }
}

/// Where each peer sits relative to this Mac.
public struct Layout: Codable, Sendable, Equatable {
    public var placements: [Edge: UUID]
    public init(placements: [Edge: UUID] = [:]) { self.placements = placements }

    public func peer(at edge: Edge) -> UUID? { placements[edge] }
    public func edge(of peer: UUID) -> Edge? {
        placements.first { $0.value == peer }?.key
    }
}

/// A position expressed as 0...1 within a peer's screen bounds, so that differing
/// resolutions and Retina scale factors map correctly between machines.
public struct NormalizedPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func clamped() -> NormalizedPoint {
        NormalizedPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    public func absolute(in bounds: Rect) -> CGPoint {
        CGPoint(x: bounds.minX + x * bounds.width,
                y: bounds.minY + y * bounds.height)
    }

    public static func of(_ point: CGPoint, in bounds: Rect) -> NormalizedPoint {
        guard bounds.width > 0, bounds.height > 0 else { return NormalizedPoint(x: 0, y: 0) }
        return NormalizedPoint(x: (point.x - bounds.minX) / bounds.width,
                               y: (point.y - bounds.minY) / bounds.height)
    }
}

/// Decides when the cursor leaves this Mac for a peer.
///
/// All coordinates are in the global display space that `CGEvent` uses: origin at the
/// top-left of the main display, y increasing downward. This is *not* AppKit's
/// bottom-left convention, and mixing the two is an easy way to invert vertical edges.
public struct EdgeDetector: Sendable {
    public var bounds: Rect
    public var layout: Layout

    /// How close to the edge counts as touching it. The cursor stops exactly at
    /// `maxX - 1` in practice, so a 1px band is required, not just equality.
    public static let edgeBand: Double = 1.0

    public init(bounds: Rect, layout: Layout) {
        self.bounds = bounds
        self.layout = layout
    }

    public struct Crossing: Sendable, Equatable {
        public let peer: UUID
        public let edge: Edge
        /// Where the cursor should appear on the peer, in the peer's normalized space.
        public let entry: NormalizedPoint
    }

    /// - Parameters:
    ///   - cursor: current cursor position in global display coordinates.
    ///   - delta: motion that produced this position. Direction matters: sitting on an
    ///     edge must not transition, only pushing *through* it.
    public func crossing(cursor: CGPoint, delta: CGPoint) -> Crossing? {
        let band = Self.edgeBand

        // The cursor enters the peer on the opposite edge, keeping the axis it did not
        // cross so the pointer appears to continue in a straight line.
        if cursor.x <= bounds.minX + band, delta.x < 0, let peer = layout.peer(at: .left) {
            return Crossing(peer: peer, edge: .left,
                            entry: NormalizedPoint(x: 1.0, y: normalizedY(cursor)))
        }
        if cursor.x >= bounds.maxX - band, delta.x > 0, let peer = layout.peer(at: .right) {
            return Crossing(peer: peer, edge: .right,
                            entry: NormalizedPoint(x: 0.0, y: normalizedY(cursor)))
        }
        if cursor.y <= bounds.minY + band, delta.y < 0, let peer = layout.peer(at: .top) {
            return Crossing(peer: peer, edge: .top,
                            entry: NormalizedPoint(x: normalizedX(cursor), y: 1.0))
        }
        if cursor.y >= bounds.maxY - band, delta.y > 0, let peer = layout.peer(at: .bottom) {
            return Crossing(peer: peer, edge: .bottom,
                            entry: NormalizedPoint(x: normalizedX(cursor), y: 0.0))
        }
        return nil
    }

    private func normalizedX(_ p: CGPoint) -> Double {
        guard bounds.width > 0 else { return 0 }
        return min(max((p.x - bounds.minX) / bounds.width, 0), 1)
    }
    private func normalizedY(_ p: CGPoint) -> Double {
        guard bounds.height > 0 else { return 0 }
        return min(max((p.y - bounds.minY) / bounds.height, 0), 1)
    }
}

/// Tracks the cursor while it is on a remote Mac.
///
/// The primary's real cursor is parked and decoupled, so this is the only record of
/// where the pointer actually is. Motion arrives as pixel deltas from the primary's
/// trackpad and is scaled into the peer's normalized space, which is what makes a
/// 1440p peer and a Retina primary behave consistently.
public struct RemoteCursor: Sendable, Equatable {
    public private(set) var position: NormalizedPoint
    public var peerBounds: Rect

    public init(entry: NormalizedPoint, peerBounds: Rect) {
        self.position = entry.clamped()
        self.peerBounds = peerBounds
    }

    /// Result of applying motion: either the cursor stays, or it leaves the peer.
    public enum Motion: Sendable, Equatable {
        case moved(NormalizedPoint)
        /// The cursor ran off the peer on this edge and control returns to the primary.
        case exited(Edge, NormalizedPoint)
    }

    public mutating func apply(deltaX: Double, deltaY: Double) -> Motion {
        guard peerBounds.width > 0, peerBounds.height > 0 else {
            return .moved(position)
        }
        let nextX = position.x + deltaX / peerBounds.width
        let nextY = position.y + deltaY / peerBounds.height

        // Check horizontal exit before vertical so a diagonal overshoot resolves
        // deterministically rather than depending on evaluation order.
        if nextX < 0 {
            return .exited(.left, NormalizedPoint(x: 0, y: min(max(nextY, 0), 1)))
        }
        if nextX > 1 {
            return .exited(.right, NormalizedPoint(x: 1, y: min(max(nextY, 0), 1)))
        }
        if nextY < 0 {
            return .exited(.top, NormalizedPoint(x: min(max(nextX, 0), 1), y: 0))
        }
        if nextY > 1 {
            return .exited(.bottom, NormalizedPoint(x: min(max(nextX, 0), 1), y: 1))
        }
        position = NormalizedPoint(x: nextX, y: nextY)
        return .moved(position)
    }
}
