import Foundation
import CoreGraphics

/// Hides the pointer on the primary while control is on a peer.
///
/// `CGDisplayHideCursor` only takes effect while the calling application is frontmost.
/// Station is a menu bar utility and is never frontmost, so the plain call is a no-op —
/// measured directly: cursor stayed visible with it, and hid correctly once the
/// WindowServer connection was marked `SetsCursorInBackground`.
///
/// That property is private API, which is a deliberate and contained exception to the
/// rule that Station avoids private interfaces. The reasoning:
///
/// - It is one boolean on a connection, not a data format we have to keep parsing
///   correctly, so there is nothing to silently misinterpret if it changes.
/// - It is resolved with `dlsym` rather than linked, so a macOS release that removes
///   the symbol degrades to a visible cursor instead of failing to launch.
/// - Failure is cosmetic. Input still forwards correctly; the user just sees a parked
///   pointer on the primary.
///
/// By contrast, gesture forwarding deliberately uses only public API, because there the
/// failure mode would be silent corruption of the product's core feature.
public enum CursorControl {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var backgroundControlEnabled: Bool?
    nonisolated(unsafe) private static var isHidden = false

    private typealias MainConnectionIDFn = @convention(c) () -> UInt32
    private typealias SetConnectionPropertyFn =
        @convention(c) (UInt32, UInt32, CFString, CFTypeRef) -> Int32

    /// Ask the WindowServer to honour cursor hiding from this background process.
    /// Idempotent; the result is cached.
    @discardableResult
    public static func enableBackgroundHiding() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let cached = backgroundControlEnabled { return cached }

        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connSym = dlsym(rtldDefault, "CGSMainConnectionID"),
              let propSym = dlsym(rtldDefault, "CGSSetConnectionProperty") else {
            backgroundControlEnabled = false
            return false
        }
        let mainConnectionID = unsafeBitCast(connSym, to: MainConnectionIDFn.self)
        let setProperty = unsafeBitCast(propSym, to: SetConnectionPropertyFn.self)

        let cid = mainConnectionID()
        let result = setProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        let ok = result == 0
        backgroundControlEnabled = ok
        return ok
    }

    /// Hide the pointer. Balanced with `show()`: `CGDisplayHideCursor` keeps a counter,
    /// so an unbalanced hide would leave the user with no pointer at all.
    public static func hide() {
        lock.lock()
        defer { lock.unlock() }
        guard !isHidden else { return }
        enableBackgroundHidingLocked()
        CGDisplayHideCursor(CGMainDisplayID())
        isHidden = true
    }

    public static func show() {
        lock.lock()
        defer { lock.unlock() }
        guard isHidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        isHidden = false
    }

    /// Whether hiding is expected to actually work on this system.
    public static var canHideInBackground: Bool {
        lock.lock()
        defer { lock.unlock() }
        enableBackgroundHidingLocked()
        return backgroundControlEnabled ?? false
    }

    // MARK: - Safety net
    //
    // A hidden cursor outlives the process that hid it: after SIGKILL the pointer stays
    // invisible until something incidental (mouse movement, an app activating) restores
    // it, and `CGDisplayShowCursor` from a different process does not clear it.
    // Measured directly, see FINDINGS.md section 8.
    //
    // So every exit path we *can* intercept must unhide first. SIGKILL cannot be
    // caught; that residual case is documented rather than solved.

    nonisolated(unsafe) private static var safetyNetInstalled = false
    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []

    /// Idempotent. Safe to call from any consumer that might hide the cursor.
    public static func installSafetyNet() {
        lock.lock()
        let alreadyInstalled = safetyNetInstalled
        safetyNetInstalled = true
        lock.unlock()
        guard !alreadyInstalled else { return }

        // Normal termination, including exit() and returning from main.
        atexit {
            // Deliberately bypasses the lock: at exit we may be the only thread left,
            // and blocking here would be worse than an unlikely race.
            if CursorControl.isHiddenUnsafe {
                CGDisplayShowCursor(CGMainDisplayID())
            }
        }

        // Ctrl-C and orderly shutdown. DispatchSource rather than a raw signal handler,
        // which would have to be async-signal-safe.
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                CursorControl.show()
                exit(128 + sig)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Lock-free read for the `atexit` path only.
    nonisolated(unsafe) fileprivate static var isHiddenUnsafe: Bool { isHidden }

    private static func enableBackgroundHidingLocked() {
        guard backgroundControlEnabled == nil else { return }
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connSym = dlsym(rtldDefault, "CGSMainConnectionID"),
              let propSym = dlsym(rtldDefault, "CGSSetConnectionProperty") else {
            backgroundControlEnabled = false
            return
        }
        let mainConnectionID = unsafeBitCast(connSym, to: MainConnectionIDFn.self)
        let setProperty = unsafeBitCast(propSym, to: SetConnectionPropertyFn.self)
        let cid = mainConnectionID()
        backgroundControlEnabled =
            setProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
    }
}
