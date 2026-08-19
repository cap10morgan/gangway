import Foundation
import CoreGraphics
import StationKit

/// Replays forwarded input on the secondary Mac.
///
/// Two non-obvious requirements, both established by measurement (FINDINGS.md):
///
/// 1. Events are rehydrated from opaque bytes with `CGEventCreateFromData` and posted
///    unmodified apart from their location. We never rebuild a gesture from parsed
///    fields, so no private field layout is depended on.
///
/// 2. Scroll and gesture events route by hit-testing the *real* cursor position, not
///    the event's `location` field. The cursor must physically be where the event is
///    meant to land, or the event is delivered nowhere.
/// Threading contract: drive from a single queue, normally the link's receive queue,
/// so injected events keep the order the primary sent them in. Reordering input is
/// visible to the user as dropped modifiers and stuttering gestures.
public final class EventInjection: @unchecked Sendable {

    private var bounds: Rect
    /// Where we believe the cursor is, so we can avoid redundant warps on the hot path.
    private var lastWarped: CGPoint?

    /// Event types that move the pointer themselves when posted, so warping first is
    /// unnecessary.
    private static let pointerMovingTypes: Set<UInt32> = [
        5,  // mouseMoved
        6,  // leftMouseDragged
        7,  // rightMouseDragged
        27, // otherMouseDragged
    ]

    public init(bounds: Rect = ScreenGeometry.globalBounds) {
        self.bounds = bounds
    }

    public func refreshScreens() {
        bounds = ScreenGeometry.globalBounds
    }

    /// Place the cursor when control arrives from the primary.
    public func enter(at point: NormalizedPoint) {
        let target = point.clamped().pixelPosition(in: bounds)
        CGWarpMouseCursorPosition(target)
        // Warping leaves the mouse decoupled on some paths; re-associate so local
        // input still works if the peer disconnects mid-session.
        CGAssociateMouseAndMouseCursorPosition(1)
        lastWarped = target
    }

    public func leave() {
        lastWarped = nil
    }

    /// Rehydrate and post one forwarded event.
    @discardableResult
    public func inject(_ event: InputEvent) -> Bool {
        guard let cgEvent = CGEvent(withDataAllocator: nil, data: event.eventData as CFData) else {
            return false
        }
        // Pixel mapping, not the continuous one: an event located one past the last row
        // is off-screen for hit-testing, which silently disables edge behaviours such as
        // revealing an auto-hidden Dock.
        let target = NormalizedPoint(x: event.normalizedX, y: event.normalizedY)
            .clamped()
            .pixelPosition(in: bounds)

        if Self.pointerMovingTypes.contains(event.eventType) {
            // Posting the event moves the cursor, so setting location is enough.
            cgEvent.location = target
            lastWarped = target
        } else {
            // Gesture, scroll, and click events are routed by cursor hit-test, so the
            // cursor has to actually be there first.
            if lastWarped.map({ $0 != target }) ?? true {
                CGWarpMouseCursorPosition(target)
                lastWarped = target
            }
            cgEvent.location = target
        }

        // Mark it as ours so this Mac's own capture skips it.
        cgEvent.setIntegerValueField(.eventSourceUserData, value: stationEventMarker)
        cgEvent.post(tap: .cghidEventTap)
        return true
    }
}
