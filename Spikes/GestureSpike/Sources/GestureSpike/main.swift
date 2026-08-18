import Foundation
import CoreGraphics
import AppKit

// Spike: can we capture high-level trackpad gesture events and faithfully
// replay them on another Mac using only public CGEvent serialization?

func typeName(_ t: UInt32) -> String {
    switch t {
    case 1: return "leftMouseDown";  case 2: return "leftMouseUp"
    case 3: return "rightMouseDown"; case 4: return "rightMouseUp"
    case 5: return "mouseMoved";     case 6: return "leftMouseDragged"
    case 7: return "rightMouseDragged"
    case 10: return "keyDown";       case 11: return "keyUp"
    case 12: return "flagsChanged";  case 13: return "appKitDefined"
    case 14: return "systemDefined"
    case 18: return "rotate";        case 19: return "beginGesture"
    case 20: return "endGesture";    case 22: return "scrollWheel"
    case 25: return "otherMouseDown";case 26: return "otherMouseUp"
    case 27: return "otherMouseDragged"
    case 29: return "gesture";       case 30: return "magnify"
    case 31: return "swipe";         case 32: return "smartMagnify"
    case 33: return "quickLook";     case 34: return "pressure"
    case 37: return "directTouch";   case 38: return "changeMode"
    default: return "type(\(t))"
    }
}

// The gesture family: everything a trackpad emits that is NOT plain mouse/key.
let gestureTypes: Set<UInt32> = [18, 19, 20, 29, 30, 31, 32, 33, 34, 37, 38]
// Only these accept -touchesMatchingPhase:inView:; others raise an ObjC assertion.
let touchCapableTypes: Set<UInt32> = [18, 19, 20, 29, 30, 31, 32, 37]

func describe(_ event: CGEvent, _ type: CGEventType) -> String {
    let raw = type.rawValue
    var parts: [String] = [typeName(raw)]
    if raw == 22 {
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        parts.append(String(format: "d=(%.1f,%.1f) phase=%d momentum=%d", dx, dy, phase, momentum))
    }
    if let ns = NSEvent(cgEvent: event) {
        if touchCapableTypes.contains(raw) {
            let touches = ns.touches(matching: .touching, in: nil)
            if !touches.isEmpty { parts.append("touches=\(touches.count)") }
        }
        if raw == 30 { parts.append(String(format: "magnification=%.4f", ns.magnification)) }
        if raw == 18 { parts.append(String(format: "rotation=%.2f", ns.rotation)) }
        if raw == 29 || raw == 31 {
            parts.append(String(format: "delta=(%.2f,%.2f)", ns.deltaX, ns.deltaY))
        }
        if raw == 13 || raw == 14 { parts.append("subtype=\(ns.subtype.rawValue)") }
    }
    return parts.joined(separator: " ")
}

/// Round-trip an event through public CGEvent serialization and report fidelity.
func roundTripReport(_ event: CGEvent) -> String {
    guard let data = event.data else { return "SERIALIZE-FAILED" }
    guard let restored = CGEvent(withDataAllocator: nil, data: data) else {
        return "DESERIALIZE-FAILED (\((data as Data).count) bytes)"
    }
    guard let data2 = restored.data else { return "RESERIALIZE-FAILED" }
    let identical = CFEqual(data, data2)
    var notes = ["\((data as Data).count)B", identical ? "byte-identical" : "DIFFERS"]

    // Did the multitouch payload survive?
    if touchCapableTypes.contains(event.type.rawValue) {
        let origTouches = NSEvent(cgEvent: event)?.touches(matching: .touching, in: nil).count ?? -1
        let newTouches = NSEvent(cgEvent: restored)?.touches(matching: .touching, in: nil).count ?? -1
        notes.append("touches \(origTouches)->\(newTouches)")
    }
    if event.type.rawValue == 30 {
        let a = NSEvent(cgEvent: event)?.magnification ?? .nan
        let b = NSEvent(cgEvent: restored)?.magnification ?? .nan
        notes.append(String(format: "mag %.4f->%.4f", a, b))
    }
    return notes.joined(separator: " ")
}

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "observe"

print("=== GestureSpike: \(mode) ===")
print("AXIsProcessTrusted (Accessibility): \(AXIsProcessTrusted())")
print("CGPreflightListenEventAccess (Input Monitoring): \(CGPreflightListenEventAccess())")
print("")

let consumed: Set<UInt32> = [18, 19, 20, 22, 29, 30, 31, 32]
nonisolated(unsafe) var seen: [UInt32: Int] = [:]
nonisolated(unsafe) var recorded: [(UInt32, Data, Double)] = []
let recordPath = ProcessInfo.processInfo.environment["STATION_CAPTURE"]
    ?? "/tmp/claude-501/-Users-wmorgan-dev-station/gesture-capture.bin"

func makeTap(onlyGestures: Bool, record: Bool) -> CFMachPort? {
    let mask: CGEventMask = ~0  // every event type, including undocumented gesture types
    let callback: CGEventTapCallBack = { _, type, event, _ in
        let raw = type.rawValue
        if raw == UInt32.max || raw == UInt32.max - 1 {
            print("!! tap disabled (timeout/user input)")
            return Unmanaged.passUnretained(event)
        }
        if gestureTypes.contains(raw) || raw == 22 {
            if let d = event.data as Data? {
                recorded.append((raw, d, Date().timeIntervalSince1970))
            }
        }
        return Unmanaged.passUnretained(event)  // listen-only: never swallow input
    }
    return CGEvent.tapCreate(tap: .cghidEventTap,
                             place: .headInsertEventTap,
                             options: .listenOnly,
                             eventsOfInterest: mask,
                             callback: callback,
                             userInfo: nil)
}

switch mode {
case "observe", "record":
    guard let tap = makeTap(onlyGestures: true, record: mode == "record") else {
        print("FAILED to create event tap — missing Input Monitoring/Accessibility permission.")
        exit(1)
    }
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    let seconds = args.count > 2 ? Double(args[2]) ?? 10 : 10
    print(">>> Tap live. Use the trackpad now (pinch, rotate, 2-finger scroll, 3/4-finger swipe).")
    print(">>> Listening \(Int(seconds))s...\n")
    CFRunLoopRunInMode(.defaultMode, seconds, false)
    print("\n--- captured \(recorded.count) gesture/scroll events ---")
    var byType: [UInt32: Int] = [:]
    for (t, _, _) in recorded { byType[t, default: 0] += 1 }
    print("by type: " + byType.map { "\(typeName($0.key))=\($0.value)" }.sorted().joined(separator: " "))
    print("")
    var shown: [UInt32: Int] = [:]
    var rtOK = 0, rtFail = 0
    for (t, d, _) in recorded {
        guard let ev = CGEvent(withDataAllocator: nil, data: d as CFData) else {
            rtFail += 1; continue
        }
        rtOK += 1
        shown[t, default: 0] += 1
        if shown[t]! <= 2 {   // a couple of samples per gesture type
            print("\(describe(ev, ev.type))")
            print("   round-trip: \(roundTripReport(ev))")
        }
    }
    print("")
    print("ROUND-TRIP: \(rtOK) rehydrated OK, \(rtFail) failed")
    if mode == "record" {
        var blob = Data()
        for (t, d, ts) in recorded {
            var type = t
            var len = UInt32(d.count)
            var time = ts
            blob.append(Data(bytes: &type, count: 4))
            blob.append(Data(bytes: &len, count: 4))
            blob.append(Data(bytes: &time, count: 8))
            blob.append(d)
        }
        try? blob.write(to: URL(fileURLWithPath: recordPath))
        print("wrote \(blob.count) bytes to \(recordPath)")
    }

case "replay":
    guard let blob = try? Data(contentsOf: URL(fileURLWithPath: recordPath)) else {
        print("no recording at \(recordPath) — run 'record' first"); exit(1)
    }
    var events: [(UInt32, CGEvent, Double)] = []
    var off = 0
    while off + 16 <= blob.count {
        let type = blob.subdata(in: off..<off+4).withUnsafeBytes { $0.load(as: UInt32.self) }
        let len = Int(blob.subdata(in: off+4..<off+8).withUnsafeBytes { $0.load(as: UInt32.self) })
        let ts = blob.subdata(in: off+8..<off+16).withUnsafeBytes { $0.load(as: Double.self) }
        off += 16
        guard off + len <= blob.count else { break }
        let d = blob.subdata(in: off..<off+len)
        off += len
        if let ev = CGEvent(withDataAllocator: nil, data: d as CFData) {
            events.append((type, ev, ts))
        } else {
            print("deserialize failed for \(typeName(type))")
        }
    }
    print("loaded \(events.count) events; replaying in 3s. Put a zoomable window in front.")
    Thread.sleep(forTimeInterval: 3)
    let base = events.first?.2 ?? 0
    var last = base
    for (type, ev, ts) in events {
        let gap = ts - last
        if gap > 0.001 { Thread.sleep(forTimeInterval: min(gap, 0.05)) }
        last = ts
        ev.post(tap: .cghidEventTap)
        print("posted \(typeName(type))")
    }
    print("replay done")

case "selftest":
    // Verify the capture+inject loop mechanically, with no user input required.
    let cb: CGEventTapCallBack = { _, type, event, _ in
        seen[type.rawValue, default: 0] += 1
        return Unmanaged.passUnretained(event)
    }
    guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                      options: .listenOnly, eventsOfInterest: ~0,
                                      callback: cb, userInfo: nil) else {
        print("TAP CREATION FAILED"); exit(1)
    }
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    let here = CGEvent(source: nil)?.location ?? .zero
    print("cursor at \(here) — posting 5 no-op mouseMoved events there")
    for _ in 0..<5 {
        if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                           mouseCursorPosition: here, mouseButton: .left) {
            e.post(tap: .cghidEventTap)
        }
        CFRunLoopRunInMode(.defaultMode, 0.05, false)
    }
    CFRunLoopRunInMode(.defaultMode, 0.5, false)
    print("tap observed: \(seen.map { "\(typeName($0.key))=\($0.value)" }.sorted().joined(separator: " "))")
    print(seen.isEmpty ? "RESULT: tap sees NOTHING (sandboxed or blocked)" : "RESULT: capture+inject loop WORKS")

case "analyze":
    guard let blob = try? Data(contentsOf: URL(fileURLWithPath: recordPath)) else {
        print("no recording at \(recordPath)"); exit(1)
    }
    var off = 0
    var byType: [UInt32: Int] = [:]
    var rtOK = 0, rtFail = 0, rtIdentical = 0
    var touchSurvived = 0, touchLost = 0, touchTotalOrig = 0
    var samples: [UInt32: Int] = [:]
    var failedTypes: [UInt32: Int] = [:]
    while off + 16 <= blob.count {
        let type = blob.subdata(in: off..<off+4).withUnsafeBytes { $0.load(as: UInt32.self) }
        let len = Int(blob.subdata(in: off+4..<off+8).withUnsafeBytes { $0.load(as: UInt32.self) })
        off += 16
        guard off + len <= blob.count else { break }
        let d = blob.subdata(in: off..<off+len); off += len
        byType[type, default: 0] += 1

        guard let ev = CGEvent(withDataAllocator: nil, data: d as CFData) else {
            rtFail += 1; failedTypes[type, default: 0] += 1; continue
        }
        rtOK += 1
        if let d2 = ev.data as Data?, d2 == d { rtIdentical += 1 }

        if touchCapableTypes.contains(type) {
            let orig = NSEvent(cgEvent: ev)?.touches(matching: .touching, in: nil).count ?? 0
            if orig > 0 {
                touchTotalOrig += 1
                // re-serialize then rehydrate again: does touch data survive a full hop?
                if let d2 = ev.data, let ev2 = CGEvent(withDataAllocator: nil, data: d2),
                   let n2 = NSEvent(cgEvent: ev2)?.touches(matching: .touching, in: nil).count, n2 == orig {
                    touchSurvived += 1
                } else { touchLost += 1 }
            }
        }
        samples[type, default: 0] += 1
        if samples[type]! <= 1 {
            print("SAMPLE \(describe(ev, ev.type))")
            print("       round-trip: \(roundTripReport(ev))")
        }
    }
    print("")
    print("events by type: " + byType.map { "\(typeName($0.key))=\($0.value)" }.sorted().joined(separator: " "))
    print("")
    print("rehydrated OK      : \(rtOK)")
    print("rehydrate FAILED   : \(rtFail) \(failedTypes.isEmpty ? "" : failedTypes.map { "\(typeName($0.key))=\($0.value)" }.joined(separator: " "))")
    print("byte-identical     : \(rtIdentical) / \(rtOK)")
    print("")
    // Which types fail to re-serialize identically, and where exactly do they differ?
    var identicalByType: [UInt32: (ok: Int, total: Int)] = [:]
    var firstDiff: (UInt32, Data, Data)?
    off = 0
    while off + 16 <= blob.count {
        let type = blob.subdata(in: off..<off+4).withUnsafeBytes { $0.load(as: UInt32.self) }
        let len = Int(blob.subdata(in: off+4..<off+8).withUnsafeBytes { $0.load(as: UInt32.self) })
        off += 16
        guard off + len <= blob.count else { break }
        let d = blob.subdata(in: off..<off+len); off += len
        guard let ev = CGEvent(withDataAllocator: nil, data: d as CFData),
              let d2 = ev.data as Data? else { continue }
        var e = identicalByType[type] ?? (0, 0)
        e.total += 1
        if d2 == d { e.ok += 1 } else if firstDiff == nil { firstDiff = (type, d, d2) }
        identicalByType[type] = e
    }
    for (t, e) in identicalByType.sorted(by: { $0.key < $1.key }) {
        print("  \(typeName(t)): \(e.ok)/\(e.total) byte-identical")
    }
    if let (t, a, b) = firstDiff {
        print("")
        print("first differing \(typeName(t)): \(a.count)B vs \(b.count)B")
        if a.count == b.count {
            let diffs = zip(a, b).enumerated().filter { $0.element.0 != $0.element.1 }
            print("differing byte offsets: \(diffs.prefix(24).map { $0.offset })"
                  + (diffs.count > 24 ? " ...(\(diffs.count) total)" : " (\(diffs.count) total)"))
            for (off, pair) in diffs.prefix(8) {
                print(String(format: "  @%4d: %02x -> %02x", off, pair.0, pair.1))
            }
        }
        // Does the difference change observable behaviour, or is it bookkeeping?
        if let ea = CGEvent(withDataAllocator: nil, data: a as CFData),
           let eb = CGEvent(withDataAllocator: nil, data: b as CFData) {
            print("  timestamp: \(ea.timestamp) -> \(eb.timestamp)")
            print("  location : \(ea.location) -> \(eb.location)")
            print("  flags    : \(ea.flags.rawValue) -> \(eb.flags.rawValue)")
        }
    }
    print("events with touches: \(touchTotalOrig)")
    print("  touch preserved  : \(touchSurvived)")
    print("  touch LOST       : \(touchLost)")

case "primary":
    // Simulates what the primary Mac must do: observe the full gesture stream AND
    // swallow it locally, so the primary does not act on gestures it forwards.
    //
    // SAFETY: only scroll and gesture events are consumed. Keyboard, clicks and
    // pointer motion pass through untouched, so the machine stays fully usable and
    // you can always abort. The tap disables itself after the time limit.
    let cb2: CGEventTapCallBack = { _, type, event, _ in
        let raw = type.rawValue
        if raw == UInt32.max || raw == UInt32.max - 1 { return Unmanaged.passUnretained(event) }
        if consumed.contains(raw) {
            seen[raw, default: 0] += 1
            if let d = event.data as Data? {
                recorded.append((raw, d, Date().timeIntervalSince1970))
            }
            return nil   // swallow locally
        }
        return Unmanaged.passUnretained(event)
    }
    guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                      options: .defaultTap, eventsOfInterest: ~0,
                                      callback: cb2, userInfo: nil) else {
        print("TAP CREATION FAILED"); exit(1)
    }
    let src2 = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src2, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    let dur = args.count > 2 ? Double(args[2]) ?? 12 : 12
    print("""
    >>> For the next \(Int(dur))s, scroll and gesture events are being SWALLOWED.
    >>> Try: two-finger scroll, pinch, rotate, THREE-finger swipe left/right,
    >>>      FOUR-finger swipe up (Mission Control).
    >>> Nothing should visibly happen. Keyboard and clicking still work normally.
    """)
    CFRunLoopRunInMode(.defaultMode, dur, false)
    CGEvent.tapEnable(tap: tap, enable: false)
    print("\n>>> Tap disabled. Input back to normal.")
    print("captured: " + seen.map { "\(typeName($0.key))=\($0.value)" }.sorted().joined(separator: " "))
    var blob = Data()
    for (t, d, ts) in recorded {
        var type = t; var len = UInt32(d.count); var time = ts
        blob.append(Data(bytes: &type, count: 4))
        blob.append(Data(bytes: &len, count: 4))
        blob.append(Data(bytes: &time, count: 8))
        blob.append(d)
    }
    try? blob.write(to: URL(fileURLWithPath: recordPath))
    print("wrote \(blob.count) bytes to \(recordPath)")
    print("\nDID THE SCREEN REACT? If nothing scrolled/zoomed/switched Spaces,")
    print("suppression works and the primary can forward without acting locally.")

case "suppress":
    // Can a consuming tap swallow input so the primary does not also act on what it
    // forwards? Post synthetic mouse moves through a tap that returns nil and check
    // whether the cursor actually moved.
    let cb: CGEventTapCallBack = { _, type, event, _ in
        seen[type.rawValue, default: 0] += 1
        return nil   // consume: event must not reach the system
    }
    guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                      options: .defaultTap, eventsOfInterest: ~0,
                                      callback: cb, userInfo: nil) else {
        print("TAP CREATION FAILED (consuming taps need Accessibility)"); exit(1)
    }
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    let origin = CGEvent(source: nil)?.location ?? .zero
    print("cursor before: \(origin)")
    let decoy = CGPoint(x: origin.x + 200, y: origin.y + 150)
    for _ in 0..<5 {
        if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                           mouseCursorPosition: decoy, mouseButton: .left) {
            e.post(tap: .cghidEventTap)
        }
        CFRunLoopRunInMode(.defaultMode, 0.05, false)
    }
    CFRunLoopRunInMode(.defaultMode, 0.4, false)
    let after = CGEvent(source: nil)?.location ?? .zero
    print("cursor after : \(after)  (decoy target was \(decoy))")
    print("tap saw: \(seen.map { "\(typeName($0.key))=\($0.value)" }.sorted().joined(separator: " "))")
    let moved = abs(after.x - origin.x) > 1 || abs(after.y - origin.y) > 1
    print(moved ? "RESULT: events NOT suppressed (cursor moved)"
                : "RESULT: SUPPRESSION WORKS - tap saw the events, system did not")

default:
    print("usage: GestureSpike [observe|record|replay|selftest] [seconds]")
}
