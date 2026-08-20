import Foundation
import Carbon
import AppKit

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

    /// The applications that habitually enable it, worth checking by hand.
    ///
    /// Ghostty is listed first because it enables secure input *automatically* at
    /// password prompts and releases it afterwards. That makes it the hardest case to
    /// attribute: the keyboard stops working, and by the time anyone looks, the prompt
    /// has finished and nothing appears to be holding it.
    public static let commonCauses = [
        "Ghostty: enables it automatically at password prompts "
            + "(macos-auto-secure-input, on by default), and can be toggled from its menu",
        "Terminal: Terminal menu > Secure Keyboard Entry",
        "iTerm2: iTerm2 menu > Secure Keyboard Entry",
        "A focused password field in any app",
        "1Password and similar, while their window has focus",
        "The login window or fast user switching",
    ]
}
