import AppKit
import CoreGraphics

// End-to-end proof: do REHYDRATED gesture events, posted with CGEventPost, actually
// drive real gesture handling in a real app? Byte-fidelity is not enough - macOS must
// accept the synthesized event and route it to NSResponder gesture callbacks.
//
// This process hosts the receiving view AND replays the events, so focus is guaranteed.

let recordPath = ProcessInfo.processInfo.environment["STATION_CAPTURE"]
    ?? "/tmp/claude-501/-Users-wmorgan-dev-station/gesture-capture.bin"

final class ReceiverView: NSView {
    var magnifyCount = 0
    var rotateCount = 0
    var swipeCount = 0
    var scrollCount = 0
    var totalMagnification = 0.0

    override var acceptsFirstResponder: Bool { true }

    override func magnify(with event: NSEvent) {
        magnifyCount += 1
        totalMagnification += event.magnification
    }
    override func rotate(with event: NSEvent) { rotateCount += 1 }
    override func swipe(with event: NSEvent) { swipeCount += 1 }
    override func scrollWheel(with event: NSEvent) { scrollCount += 1 }

    var summary: String {
        String(format: "magnify=%d (total magnification %.4f)  rotate=%d  swipe=%d  scroll=%d",
               magnifyCount, totalMagnification, rotateCount, swipeCount, scrollCount)
    }
}

func loadEvents() -> [(UInt32, CGEvent)] {
    guard let blob = try? Data(contentsOf: URL(fileURLWithPath: recordPath)) else { return [] }
    var out: [(UInt32, CGEvent)] = []
    var off = 0
    while off + 16 <= blob.count {
        let type = blob.subdata(in: off..<off+4).withUnsafeBytes { $0.load(as: UInt32.self) }
        let len = Int(blob.subdata(in: off+4..<off+8).withUnsafeBytes { $0.load(as: UInt32.self) })
        off += 16
        guard off + len <= blob.count else { break }
        let d = blob.subdata(in: off..<off+len); off += len
        if let ev = CGEvent(withDataAllocator: nil, data: d as CFData) { out.append((type, ev)) }
    }
    return out
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 420),
                      styleMask: [.titled], backing: .buffered, defer: false)
window.title = "Station gesture proof"
let view = ReceiverView(frame: window.contentRect(forFrameRect: window.frame))
window.contentView = view
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(view)
app.activate(ignoringOtherApps: true)

let all = loadEvents()
// Which event types to replay, e.g. "30" for magnify, "22" for scroll (the control),
// "29,30" to send the generic gesture wrapper alongside magnify.
let wanted: Set<UInt32> = Set((CommandLine.arguments.dropFirst().first ?? "30")
    .split(separator: ",").compactMap { UInt32($0) })
let setLocation = !CommandLine.arguments.contains("--keep-location")
let selected = all.filter { wanted.contains($0.0) }
print("loaded \(all.count) events; replaying \(selected.count) of types \(wanted.sorted())"
      + (setLocation ? " (retargeted)" : " (original location)"))

let target = CGPoint(x: window.frame.midX,
                     y: (NSScreen.main?.frame.height ?? 900) - window.frame.midY)
// Scroll and gesture events route by hit-testing the ACTUAL cursor location, not the
// event's location field. The cursor must physically be over the receiving window.
CGWarpMouseCursorPosition(target)
print("warped cursor to \(target); window frame \(window.frame)")
var pending = selected[...]

// Post from a timer so the main run loop keeps pumping and the app can actually
// dequeue what we send. Posting in a tight loop starves its own receiver.
@MainActor func pump() {
    guard let (_, ev) = pending.first else {
        print("")
        print("RECEIVER SAW: \(view.summary)")
        let ok = view.magnifyCount + view.rotateCount + view.swipeCount + view.scrollCount > 0
        print(ok ? "*** DELIVERED ***" : "*** NOT DELIVERED ***")
        app.terminate(nil)
        return
    }
    pending = pending.dropFirst()
    if setLocation { ev.location = target }
    ev.post(tap: .cghidEventTap)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.004, execute: pump)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: pump)

app.run()
