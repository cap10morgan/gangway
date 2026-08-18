import XCTest
import AppKit
@testable import StationInput
@testable import StationKit

/// Uses a private pasteboard so the tests never touch the user's real clipboard.
final class ClipboardMonitorTests: XCTestCase {

    private var pasteboard: NSPasteboard!
    private var monitor: ClipboardMonitor!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("com.station.tests.\(UUID().uuidString)"))
        monitor = ClipboardMonitor(pasteboard: pasteboard)
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        super.tearDown()
    }

    func testReadsPlainText() throws {
        pasteboard.clearContents()
        pasteboard.setString("hello station", forType: .string)

        let content = try XCTUnwrap(monitor.readLocal())
        XCTAssertEqual(content.items.count, 1)
        let text = try XCTUnwrap(content.items[0].representations[NSPasteboard.PasteboardType.string.rawValue])
        XCTAssertEqual(String(data: text, encoding: .utf8), "hello station")
    }

    func testCarriesMultipleRepresentationsTogether() throws {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data("plain".utf8), forType: .string)
        item.setData(Data("<b>rich</b>".utf8), forType: .html)
        pasteboard.writeObjects([item])

        let content = try XCTUnwrap(monitor.readLocal())
        let reps = content.items[0].representations
        XCTAssertNotNil(reps[NSPasteboard.PasteboardType.string.rawValue])
        XCTAssertNotNil(reps[NSPasteboard.PasteboardType.html.rawValue],
                        "dropping rich representations would silently degrade the paste")
    }

    /// Password managers mark items concealed so clipboard tools ignore them. Syncing
    /// one over the network would be exactly the leak that marking exists to prevent.
    func testRefusesConcealedItems() {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data("hunter2".utf8), forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.writeObjects([item])

        nonisolated(unsafe) var skipped: String?
        monitor.onSkipped = { skipped = $0 }
        XCTAssertNil(monitor.readLocal(), "a concealed item must never be shared")
        XCTAssertNotNil(skipped)
    }

    func testRefusesTransientItems() {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data("temp".utf8), forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.writeObjects([item])
        XCTAssertNil(monitor.readLocal())
    }

    func testApplyWritesContentToPasteboard() throws {
        let content = ClipboardContent(items: [
            ClipboardItem(representations: [
                NSPasteboard.PasteboardType.string.rawValue: Data("from the other Mac".utf8),
            ]),
        ])
        monitor.apply(content)
        XCTAssertEqual(pasteboard.string(forType: .string), "from the other Mac")
    }

    /// Applying remote content bumps changeCount. If that were read as a fresh local
    /// copy the two Macs would ping-pong the same clipboard forever.
    func testApplyingRemoteContentDoesNotLoopBack() throws {
        nonisolated(unsafe) var broadcasts = 0
        monitor.onLocalChange = { _ in broadcasts += 1 }
        monitor.start(interval: 0.05)
        defer { monitor.stop() }

        monitor.apply(ClipboardContent(items: [
            ClipboardItem(representations: [
                NSPasteboard.PasteboardType.string.rawValue: Data("remote".utf8),
            ]),
        ]))

        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(broadcasts, 0, "remote content must not be echoed back")
    }

    func testLocalChangeIsBroadcast() throws {
        nonisolated(unsafe) var received: ClipboardContent?
        monitor.onLocalChange = { received = $0 }
        monitor.start(interval: 0.05)
        defer { monitor.stop() }

        pasteboard.clearContents()
        pasteboard.setString("typed locally", forType: .string)

        let deadline = Date().addingTimeInterval(2)
        while received == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let content = try XCTUnwrap(received, "a local copy should be broadcast")
        let data = try XCTUnwrap(content.items[0].representations[NSPasteboard.PasteboardType.string.rawValue])
        XCTAssertEqual(String(data: data, encoding: .utf8), "typed locally")
    }

    func testEmptyPasteboardProducesNothing() {
        pasteboard.clearContents()
        XCTAssertNil(monitor.readLocal())
    }
}
