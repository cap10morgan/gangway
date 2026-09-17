import Foundation
import Carbon
import AppKit
import CoreGraphics

/// Secure Event Input, which any application can turn on.
///
/// While it is active, event taps stop receiving keyboard events entirely, but keep
/// receiving mouse events. That asymmetry is worth naming: it presents as "the pointer
/// moves to the other Mac but nothing I type arrives", which looks like a bug in
/// forwarding rather than a system-wide input restriction.
///
/// Terminal's "Secure Keyboard Entry" is the usual cause; focused password fields and
/// some password managers do it too.
public enum SecureInput {
    public static var isEnabled: Bool { IsSecureEventInputEnabled() }

    /// macOS exposes no way to identify which process holds Secure Event Input.
    ///
    /// Verified rather than assumed: holding it in a test process produced no
    /// `kCGSSessionSecureInputPID` entry, nor any secure-related key under
    /// `IOHIDSystem`, so the widely repeated `ioreg` recipe finds nothing on current
    /// macOS. An earlier version of this shipped that lookup and would have silently
    /// reported "unknown" forever.
    ///
    /// The frontmost application is a reasonable guess, since the common holders take
    /// it while focused, but it is a guess and is labelled as one.
    public static func likelyHolder() -> String? {
        guard isEnabled else { return nil }
        return NSWorkspace.shared.frontmostApplication?.localizedName
    }

    /// Whether secure input appears to be *actually* withholding keystrokes from our
    /// tap, as opposed to merely being switched on somewhere.
    ///
    /// `IsSecureEventInputEnabled()` on its own is not evidence of a problem. It was
    /// shipped as if it were, and produced a floating panel saying keystrokes were not
    /// arriving while they were arriving perfectly well. The flag reports that some
    /// application in the session has asked for secure input; whether that actually
    /// stops *this* tap from seeing keys is a separate question, and the answer is
    /// observably sometimes no.
    ///
    /// So corroborate it. The system keeps a timestamp of the last keyboard event at
    /// the HID layer, which is a counter rather than a delivery, so asking for it does
    /// not require the event to have reached us. If the system says a key went down a
    /// moment ago and our tap has not seen one in far longer, keystrokes are going
    /// somewhere we cannot see. That is the symptom worth reporting; the flag is not.
    ///
    /// Deliberately biased towards silence. If the counter turns out to be suppressed
    /// too, `sinceSystemKeyDown` stays large and this simply never fires -- which is
    /// where things stood before the warning existed, and better than a panel that
    /// lies. A detector that has not been proven must fail quiet.
    public static func appearsToBlockKeyboard(lastKeyDownAtTap: Date?) -> Bool {
        guard isEnabled else { return false }

        let sinceSystemKeyDown = CGEventSource.secondsSinceLastEventType(
            .hidSystemState, eventType: .keyDown)
        // Nobody is typing, so there is nothing to be missing.
        guard sinceSystemKeyDown < Self.typingWindow else { return false }

        guard let lastKeyDownAtTap else { return true }
        // A margin so ordinary scheduling jitter between the two clocks cannot look
        // like a swallowed keystroke.
        return Date().timeIntervalSince(lastKeyDownAtTap) > sinceSystemKeyDown + 1
    }

    /// How recently the system must have seen a keystroke for its absence at our tap to
    /// mean anything.
    private static let typingWindow: TimeInterval = 3

    /// The same list, trimmed for a panel the user reads while their keyboard is
    /// half-broken. Ordered by how likely it is to be the answer, and phrased as
    /// things to go and do rather than things that are true.
    public static let quickFixes = [
        "Finish or dismiss the password prompt — an unlocking password manager is the usual cause",
        "Click out of any password field",
        "Ghostty, Terminal or iTerm2: turn off Secure Keyboard Entry in the app menu",
    ]

    /// The applications that habitually enable it, worth checking by hand.
    ///
    /// Ghostty is listed first because it enables secure input *automatically* at
    /// password prompts and releases it afterwards. That makes it the hardest case to
    /// attribute: the keyboard stops working, and by the time anyone looks, the prompt
    /// has finished and nothing appears to be holding it.
    public static let commonCauses = [
        "A password prompt: a password manager holds it while unlocking, "
            + "which is by far the most common cause and clears itself",
        "A focused password field in any app",
        "Ghostty: enables it automatically at password prompts "
            + "(macos-auto-secure-input, on by default), and can be toggled from its menu",
        "Terminal: Terminal menu > Secure Keyboard Entry",
        "iTerm2: iTerm2 menu > Secure Keyboard Entry",
        "The login window or fast user switching",
    ]
}
