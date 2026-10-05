import Foundation

/// Wire protocol for Gangway.
///
/// Design note: the hot path (`.input`) carries the *opaque* serialized bytes of a
/// `CGEvent`. We deliberately do not parse, interpret, or re-encode the event's
/// contents. That is what makes full trackpad-gesture forwarding possible: a
/// magnify/rotate/swipe event's multitouch payload lives in private fields that we
/// would otherwise have to reverse-engineer and keep working across macOS releases.
/// By treating it as a blob, gesture support costs us nothing and cannot rot.
public enum MessageType: UInt8, Sendable {
    // Control plane (JSON payloads) - infrequent, readability wins.
    case hello       = 0x01
    case pairRequest = 0x02
    case pairResult  = 0x03
    case heartbeat   = 0x04
    case screens     = 0x05
    /// Whether the sending Mac's keyboard is being withheld by Secure Event Input, so
    /// the Mac being driven can say why nothing is typing. Sent only while forwarding.
    case keyboardState = 0x06

    // Data plane (binary payloads) - high frequency, compactness wins.
    case input       = 0x10
    case enterScreen = 0x11
    case leaveScreen = 0x12
    /// One chunk of a clipboard transfer. Clipboard payloads routinely exceed a single
    /// frame, so they are always chunked rather than special-cased by size.
    case clipboard   = 0x20
    /// The shared screen arrangement. One arrangement describes every Mac, so editing
    /// it anywhere should be reflected everywhere.
    case layout      = 0x21

    // Handshake. These are the only frames sent outside the encrypted channel;
    // everything else is wrapped in `.encrypted`.
    case hsEphemeral = 0x60
    case hsIdentity  = 0x61
    case encrypted   = 0x62
    /// Sent by the Mac that was asked, once a person there has authorised the pairing.
    /// Processed even while the receiver has not itself confirmed, since it is what
    /// tells the initiating Mac the pairing was accepted.
    case pairingApproved = 0x63
}

public let gangwayProtocolVersion = 1

/// Stamped into every event Gangway injects, and skipped by every capture.
///
/// Required once any Mac can control any other. Each Mac runs a capture tap *and* an
/// injector, so injected pointer motion is seen by the receiving Mac's own tap. Without
/// a marker that motion trips its edge detector and it tries to seize control back,
/// which reads to the user as the pointer fighting itself.
public let gangwayEventMarker: Int64 = 0x5354_4154_494F_4E01

// MARK: - Control-plane messages

public struct Hello: Codable, Sendable {
    public var protocolVersion: Int
    public var deviceID: UUID
    public var deviceName: String
    public var role: Role
    public init(protocolVersion: Int = gangwayProtocolVersion, deviceID: UUID, deviceName: String, role: Role) {
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.role = role
    }
}

public enum Role: String, Codable, Sendable {
    case primary    // owns the physical keyboard/trackpad
    case secondary  // receives forwarded input
}

public struct PairRequest: Codable, Sendable {
    public var deviceName: String
    public init(deviceName: String) { self.deviceName = deviceName }
}

public struct PairResult: Codable, Sendable {
    public var accepted: Bool
    public var reason: String?
    public init(accepted: Bool, reason: String? = nil) {
        self.accepted = accepted
        self.reason = reason
    }
}

/// A physical display on a peer, in that peer's global coordinate space.
public struct ScreenInfo: Codable, Sendable, Equatable {
    public var displayID: UInt32
    public var frame: Rect
    public var isMain: Bool
    public var backingScale: Double
    public init(displayID: UInt32, frame: Rect, isMain: Bool, backingScale: Double) {
        self.displayID = displayID
        self.frame = frame
        self.isMain = isMain
        self.backingScale = backingScale
    }
}

public struct Rect: Codable, Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

/// Sent by the forwarding Mac when Secure Event Input starts or stops withholding its
/// keyboard. No holder name: macOS does not say who holds it, and the guess was worth
/// less than the confusion it caused.
public struct KeyboardState: Codable, Sendable, Equatable {
    public var blocked: Bool
    public init(blocked: Bool) { self.blocked = blocked }
}

public struct ScreenSet: Codable, Sendable {
    public var screens: [ScreenInfo]
    public init(screens: [ScreenInfo]) { self.screens = screens }

    /// Union of all displays, used to normalize cursor positions across peers.
    public var bounds: Rect {
        guard let first = screens.first else { return Rect(x: 0, y: 0, width: 0, height: 0) }
        var minX = first.frame.minX, minY = first.frame.minY
        var maxX = first.frame.maxX, maxY = first.frame.maxY
        for s in screens.dropFirst() {
            minX = min(minX, s.frame.minX); minY = min(minY, s.frame.minY)
            maxX = max(maxX, s.frame.maxX); maxY = max(maxY, s.frame.maxY)
        }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - Data-plane messages

/// A forwarded input event.
///
/// `eventData` is an opaque `CGEvent` serialization. `position` is normalized to
/// 0...1 within the *destination* peer's screen bounds so that differing resolutions
/// and Retina scale factors resolve correctly. Deltas are carried separately because
/// relative-motion consumers (games, 3D apps) need sub-pixel precision that a
/// normalized absolute position would quantize away.
public struct InputEvent: Sendable, Equatable {
    public var eventType: UInt32
    public var normalizedX: Double
    public var normalizedY: Double
    public var deltaX: Double
    public var deltaY: Double
    public var eventData: Data

    public init(eventType: UInt32, normalizedX: Double, normalizedY: Double,
                deltaX: Double, deltaY: Double, eventData: Data) {
        self.eventType = eventType
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.eventData = eventData
    }

    public func encode() -> Data {
        var out = Data(capacity: eventData.count + 36)
        out.appendLE(eventType)
        out.appendLE(normalizedX)
        out.appendLE(normalizedY)
        out.appendLE(deltaX)
        out.appendLE(deltaY)
        out.append(eventData)
        return out
    }

    public static func decode(_ data: Data) -> InputEvent? {
        guard data.count >= 36 else { return nil }
        var c = Cursor(data)
        guard let t: UInt32 = c.readLE(), let nx: Double = c.readLE(),
              let ny: Double = c.readLE(), let dx: Double = c.readLE(),
              let dy: Double = c.readLE() else { return nil }
        return InputEvent(eventType: t, normalizedX: nx, normalizedY: ny,
                          deltaX: dx, deltaY: dy, eventData: c.rest())
    }
}

/// Sent when the primary hands control to this peer, carrying the entry point so the
/// cursor appears exactly where it left the previous screen's edge.
public struct EnterScreen: Sendable, Equatable {
    public var normalizedX: Double
    public var normalizedY: Double
    public init(normalizedX: Double, normalizedY: Double) {
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
    }
    public func encode() -> Data {
        var out = Data(capacity: 16)
        out.appendLE(normalizedX); out.appendLE(normalizedY)
        return out
    }
    public static func decode(_ data: Data) -> EnterScreen? {
        var c = Cursor(data)
        guard let x: Double = c.readLE(), let y: Double = c.readLE() else { return nil }
        return EnterScreen(normalizedX: x, normalizedY: y)
    }
}
