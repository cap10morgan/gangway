import Foundation
import Carbon

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
}
