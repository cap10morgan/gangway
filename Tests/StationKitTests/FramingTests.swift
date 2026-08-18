import XCTest
@testable import StationKit

final class FramingTests: XCTestCase {

    func testRoundTripsASingleFrame() throws {
        let payload = Data([1, 2, 3, 4, 5])
        var decoder = FrameDecoder()
        decoder.append(Framing.frame(.input, payload))

        let frame = try XCTUnwrap(try decoder.next())
        XCTAssertEqual(frame.type, .input)
        XCTAssertEqual(frame.payload, payload)
        XCTAssertNil(try decoder.next())
    }

    /// A single TCP read can contain several frames; all must be drained.
    func testDrainsMultipleFramesFromOneRead() throws {
        var stream = Data()
        stream.append(Framing.frame(.input, Data([0xAA])))
        stream.append(Framing.frame(.heartbeat, Data()))
        stream.append(Framing.frame(.leaveScreen, Data([0xBB, 0xCC])))

        var decoder = FrameDecoder()
        decoder.append(stream)

        XCTAssertEqual(try decoder.next()?.type, .input)
        XCTAssertEqual(try decoder.next()?.type, .heartbeat)
        let third = try XCTUnwrap(try decoder.next())
        XCTAssertEqual(third.type, .leaveScreen)
        XCTAssertEqual(third.payload, Data([0xBB, 0xCC]))
        XCTAssertNil(try decoder.next())
    }

    /// The important case: a frame split across reads, one byte at a time.
    func testReassemblesFrameDeliveredByteByByte() throws {
        let payload = Data(repeating: 0x5A, count: 300)
        let framed = Framing.frame(.input, payload)

        var decoder = FrameDecoder()
        for (index, byte) in framed.enumerated() {
            decoder.append(Data([byte]))
            if index < framed.count - 1 {
                XCTAssertNil(try decoder.next(), "yielded a frame after only \(index + 1) bytes")
            }
        }
        let frame = try XCTUnwrap(try decoder.next())
        XCTAssertEqual(frame.payload, payload)
    }

    func testEmptyPayloadIsAValidFrame() throws {
        var decoder = FrameDecoder()
        decoder.append(Framing.frame(.heartbeat, Data()))
        let frame = try XCTUnwrap(try decoder.next())
        XCTAssertEqual(frame.type, .heartbeat)
        XCTAssertTrue(frame.payload.isEmpty)
    }

    /// A hostile length prefix must not cause a huge allocation.
    func testRejectsOversizedFrame() {
        var hostile = Data()
        hostile.appendLE(UInt32(Framing.maxFrameSize + 1))
        hostile.append(MessageType.input.rawValue)

        var decoder = FrameDecoder()
        decoder.append(hostile)
        XCTAssertThrowsError(try decoder.next()) { error in
            XCTAssertEqual(error as? FramingError, .frameTooLarge(Framing.maxFrameSize + 1))
        }
    }

    /// An unknown type must be skipped, and the stream must stay usable afterwards.
    func testUnknownMessageTypeIsSkippedWithoutWedgingStream() throws {
        var stream = Data()
        stream.appendLE(UInt32(2))
        stream.append(0xEE)                 // not a MessageType
        stream.append(contentsOf: [0, 0])
        stream.append(Framing.frame(.heartbeat, Data()))

        var decoder = FrameDecoder()
        decoder.append(stream)

        XCTAssertThrowsError(try decoder.next()) { error in
            XCTAssertEqual(error as? FramingError, .unknownMessageType(0xEE))
        }
        XCTAssertEqual(try decoder.next()?.type, .heartbeat)
    }
}

final class InputEventTests: XCTestCase {

    func testRoundTripsPreservingOpaqueEventBytes() throws {
        // Stand-in for a serialized CGEvent: we must never alter these bytes.
        let opaque = Data((0..<260).map { UInt8($0 % 256) })
        let event = InputEvent(eventType: 30, normalizedX: 0.25, normalizedY: 0.75,
                               deltaX: -3.5, deltaY: 12.25, eventData: opaque)

        let decoded = try XCTUnwrap(InputEvent.decode(event.encode()))
        XCTAssertEqual(decoded, event)
        XCTAssertEqual(decoded.eventData, opaque, "gesture payload must survive byte-for-byte")
    }

    func testRoundTripsWithEmptyEventData() throws {
        let event = InputEvent(eventType: 5, normalizedX: 0, normalizedY: 1,
                               deltaX: 0, deltaY: 0, eventData: Data())
        XCTAssertEqual(InputEvent.decode(event.encode()), event)
    }

    func testRejectsTruncatedBuffer() {
        let event = InputEvent(eventType: 30, normalizedX: 0.5, normalizedY: 0.5,
                               deltaX: 0, deltaY: 0, eventData: Data([1, 2, 3]))
        let truncated = event.encode().prefix(20)
        XCTAssertNil(InputEvent.decode(Data(truncated)))
    }

    func testEnterScreenRoundTrips() throws {
        let msg = EnterScreen(normalizedX: 0.125, normalizedY: 0.875)
        XCTAssertEqual(EnterScreen.decode(msg.encode()), msg)
    }
}

final class ScreenSetTests: XCTestCase {

    func testBoundsSpansAllDisplays() {
        let set = ScreenSet(screens: [
            ScreenInfo(displayID: 1, frame: Rect(x: 0, y: 0, width: 1920, height: 1080),
                       isMain: true, backingScale: 2),
            ScreenInfo(displayID: 2, frame: Rect(x: 1920, y: -200, width: 2560, height: 1440),
                       isMain: false, backingScale: 2),
        ])
        let bounds = set.bounds
        XCTAssertEqual(bounds.minX, 0)
        XCTAssertEqual(bounds.minY, -200)
        XCTAssertEqual(bounds.maxX, 4480)
        XCTAssertEqual(bounds.maxY, 1240)
    }

    func testBoundsOfEmptySetIsZero() {
        XCTAssertEqual(ScreenSet(screens: []).bounds, Rect(x: 0, y: 0, width: 0, height: 0))
    }
}
