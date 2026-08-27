import Foundation
import CoreGraphics
import StationKit

/// Captures input on the primary Mac and decides when it belongs to a peer.
///
/// A single consuming tap at `.cghidEventTap` does both jobs. While control is local it
/// passes everything through and only watches for an edge crossing. While control is
/// remote it swallows every event so the primary does not act on input meant for the
/// peer, and hands the raw bytes to `onEvent`.
///
/// Verified by measurement: consuming does not degrade the gesture stream. See
/// FINDINGS.md section 6.
/// Threading contract: create, start, stop and mutate on the thread that runs the
/// run loop the tap is attached to. The tap callback fires on that same thread, so
/// state touched by `handle` needs no locking. Callers on other queues (network
/// callbacks) must hop to that thread first. `@unchecked` because the compiler cannot
/// express that contract for us.
public final class EventCapture: @unchecked Sendable {

    public enum Mode: Equatable, Sendable {
        case local
        case forwarding(peer: DeviceID)
    }

    /// Every event type we forward. Deliberately *not* a filtered subset: gesture
    /// events are inert on the far side without their type-29 companions, so filtering
    /// by "interesting" type is the bug that breaks gesture support. See FINDINGS.md.
    private static let allEvents: CGEventMask = ~0

    public private(set) var mode: Mode = .local

    /// Raw event ready to send. The `Data` is an opaque `CGEvent` serialization.
    public var onEvent: (@Sendable (InputEvent) -> Void)?
    /// Control just moved to a peer; the peer should place its cursor at this point.
    public var onEnterPeer: (@Sendable (DeviceID, NormalizedPoint) -> Void)?
    /// Control came back to this Mac.
    public var onReturnLocal: (@Sendable (ScreenEdge, NormalizedPoint) -> Void)?
    public var onTapDisabled: (@Sendable () -> Void)?
    /// Whether control may pass to this peer yet. A peer that has never been paired is
    /// not ready until somebody there has approved.
    public var isPeerReady: (@Sendable (DeviceID) -> Bool)?
    /// The pointer reached an edge leading to a peer that is not ready. Control stays
    /// here; this is the cue to connect and ask for approval.
    public var onPeerNotReady: (@Sendable (DeviceID, NormalizedPoint) -> Void)?

    /// Last time we reported a not-ready peer, so pushing at an edge does not ask
    /// repeatedly. Pointer motion produces events far faster than a person can approve.
    private var lastNotReadyReport: [DeviceID: Date] = [:]
    private static let notReadyReportInterval: TimeInterval = 3

    public var layout: Layout
    private var localBounds: Rect
    private var peerBounds: [DeviceID: Rect]
    private var remoteCursor: RemoteCursor?
    private var parkedCursor: CGPoint = .zero

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    public init(layout: Layout = Layout(), peerBounds: [DeviceID: Rect] = [:]) {
        self.layout = layout
        self.peerBounds = peerBounds
        self.localBounds = ScreenGeometry.globalBounds
    }

    public func setPeerBounds(_ bounds: Rect, for peer: DeviceID) {
        peerBounds[peer] = bounds
    }

    /// Re-read the display arrangement, e.g. after a monitor is attached.
    public func refreshScreens() {
        localBounds = ScreenGeometry.globalBounds
    }

    public enum CaptureError: LocalizedError {
        case tapCreationFailed

        public var errorDescription: String? {
            switch self {
            case .tapCreationFailed:
                return "Could not create the input tap. Station needs Accessibility and "
                     + "Input Monitoring permission in System Settings > Privacy & Security."
            }
        }
    }

    public func start() throws {
        guard tap == nil else { return }
        // Guarantee the cursor is restored on any exit path we can intercept.
        CursorControl.installSafetyNet()
        let context = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let capture = Unmanaged<EventCapture>.fromOpaque(userInfo).takeUnretainedValue()
            return capture.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: Self.allEvents,
                                          callback: callback,
                                          userInfo: context) else {
            throw CaptureError.tapCreationFailed
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        releaseCursor()
        tap = nil
        runLoopSource = nil
        mode = .local
    }

    /// Hand control back to this Mac, e.g. because the peer disconnected or the user
    /// pressed the escape hotkey. Must be safe to call when already local.
    public func returnControlLocally() {
        guard case .forwarding = mode else { return }
        releaseCursor()
        remoteCursor = nil
        mode = .local
        onEscapeHatch?()
    }

    /// Fired when the user forces control back with the escape hatch.
    public var onEscapeHatch: (@Sendable () -> Void)?

    // MARK: - Tap callback

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // A tap that takes too long is disabled by the system; re-arm it rather than
        // silently dying, which would leave the user with no input forwarding.
        if type.rawValue == UInt32.max || type.rawValue == UInt32.max - 1 {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            onTapDisabled?()
            return Unmanaged.passUnretained(event)
        }

        // Never react to our own injected input. Every Mac both captures and injects
        // now, so an unmarked injected event would be captured here and treated as the
        // user moving the pointer.
        if event.getIntegerValueField(.eventSourceUserData) == stationEventMarker {
            return Unmanaged.passUnretained(event)
        }

        switch mode {
        case .local:
            watchForCrossing(event)
            return Unmanaged.passUnretained(event)

        case .forwarding(let peer):
            // Escape hatch. While forwarding we swallow everything, so without a
            // guaranteed way out a peer that stops responding would leave the user
            // with a dead keyboard and mouse. Control-Option-Escape always returns
            // control locally, and is consumed so it never reaches the peer.
            if Self.isEscapeHatch(type: type, event: event) {
                returnControlLocally()
                return nil
            }
            forward(event, type: type, to: peer)
            return nil   // swallow locally
        }
    }

    /// Hand the pointer to a peer directly, once it has become ready.
    ///
    /// Used to complete a crossing that was blocked while waiting for approval, so the
    /// push that started it is honoured rather than needing to be repeated.
    public func beginForwarding(to peer: DeviceID, entry: NormalizedPoint) {
        guard mode == .local, let bounds = peerBounds[peer] else { return }
        guard let edge = layout.edge(of: peer) else { return }
        parkedCursor = ScreenGeometry.currentCursor
        remoteCursor = RemoteCursor(entry: entry, peerBounds: bounds,
                                    returnEdge: edge.opposite)
        mode = .forwarding(peer: peer)
        captureCursor()
        onEnterPeer?(peer, entry)
    }

    /// Control-Option-Escape.
    static func isEscapeHatch(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .keyDown else { return false }
        guard event.getIntegerValueField(.keyboardEventKeycode) == 53 else { return false }
        return event.flags.contains(.maskControl) && event.flags.contains(.maskAlternate)
    }

    private func watchForCrossing(_ event: CGEvent) {
        let delta = CGPoint(x: Double(event.getIntegerValueField(.mouseEventDeltaX)),
                            y: Double(event.getIntegerValueField(.mouseEventDeltaY)))
        guard delta != .zero else { return }

        let detector = EdgeDetector(bounds: localBounds, layout: layout)
        guard let crossing = detector.crossing(cursor: event.location, delta: delta) else {
            return
        }
        // A peer that has not approved yet, or whose geometry we have not learned,
        // cannot receive the pointer. Hold control here and say so, rather than
        // handing the pointer to a Mac that will drop it.
        guard let bounds = peerBounds[crossing.peer],
              isPeerReady?(crossing.peer) ?? true else {
            let now = Date()
            let last = lastNotReadyReport[crossing.peer] ?? .distantPast
            if now.timeIntervalSince(last) > Self.notReadyReportInterval {
                lastNotReadyReport[crossing.peer] = now
                onPeerNotReady?(crossing.peer, crossing.entry)
            }
            return
        }

        parkedCursor = event.location
        // Leaving this Mac by its right edge means arriving on the peer's left, so the
        // peer's left edge is the one that leads back here.
        remoteCursor = RemoteCursor(entry: crossing.entry, peerBounds: bounds,
                                    returnEdge: crossing.edge.opposite)
        mode = .forwarding(peer: crossing.peer)
        captureCursor()
        onEnterPeer?(crossing.peer, crossing.entry)
    }

    /// Event types that carry pointer motion, and so can drag the primary's cursor
    /// off its parked position if anything slips through.
    private static let pointerMovingTypes: Set<UInt32> = [5, 6, 7, 27]

    private func forward(_ event: CGEvent, type: CGEventType, to peer: DeviceID) {
        let deltaX = Double(event.getIntegerValueField(.mouseEventDeltaX))
        let deltaY = Double(event.getIntegerValueField(.mouseEventDeltaY))

        // Pin the local cursor. Disabling the mouse/cursor association is supposed to
        // be enough, but in practice the cursor still creeps: the association does not
        // reliably hold for a background process, and any event that slips through
        // while the tap is briefly disabled moves it. Warping back to the parked point
        // is cheap, generates no events, and makes the behaviour deterministic.
        if Self.pointerMovingTypes.contains(type.rawValue), event.location != parkedCursor {
            CGWarpMouseCursorPosition(parkedCursor)
        }

        // Track where the pointer is on the peer, and notice when it runs off.
        if deltaX != 0 || deltaY != 0, var cursor = remoteCursor {
            let motion = cursor.apply(deltaX: deltaX, deltaY: deltaY)
            remoteCursor = cursor
            if case .exited(let edge, let at) = motion {
                releaseCursor()
                remoteCursor = nil
                mode = .local
                onReturnLocal?(edge, at)
                return
            }
        }

        guard let data = event.data as Data? else { return }
        let position = remoteCursor?.position ?? NormalizedPoint(x: 0.5, y: 0.5)
        onEvent?(InputEvent(eventType: type.rawValue,
                            normalizedX: position.x,
                            normalizedY: position.y,
                            deltaX: deltaX,
                            deltaY: deltaY,
                            eventData: data))
    }

    // MARK: - Cursor capture

    /// Decouple the physical mouse from the on-screen cursor so the pointer stays put
    /// on the primary while deltas keep arriving. This is the same technique games use
    /// for relative mouse look.
    private func captureCursor() {
        CGAssociateMouseAndMouseCursorPosition(0)
        CursorControl.hide()
    }

    /// Order matters here, and getting it wrong strands the user with a live cursor
    /// that no mouse can move.
    ///
    /// `CGWarpMouseCursorPosition` opens a local-events suppression interval during
    /// which physical mouse deltas are discarded, and the documented way to end it
    /// early is to call `CGAssociateMouseAndMouseCursorPosition(true)` *after* the
    /// warp. Associating first and warping second leaves the suppression running, and
    /// if the process then exits -- which is exactly what the termination path does --
    /// nothing is left alive to clear it. The cursor stays visible, parked where it
    /// was left, and permanently deaf to the trackpad.
    private func releaseCursor() {
        CursorControl.show()
        if parkedCursor != .zero {
            CGWarpMouseCursorPosition(parkedCursor)
        }
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
