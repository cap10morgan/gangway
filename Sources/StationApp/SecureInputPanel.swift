import AppKit
import SwiftUI
import StationInput

/// The warning shown when Secure Event Input is swallowing the keyboard mid-session.
///
/// This is the failure that looks most like a bug in Station and least like a system
/// restriction: the pointer crosses to the other Mac and moves perfectly, clicks land,
/// gestures land, and nothing typed arrives. Every previous instance of it cost an
/// evening of looking in the wrong place, so it is worth interrupting for.
///
/// It appears on the *controlling* Mac, which is the one whose keyboard is being held
/// and therefore the only one where the problem can be fixed.
///
/// A floating non-activating panel rather than an alert, for two reasons. An alert
/// would take focus, and taking focus away from whatever holds Secure Event Input can
/// make it release -- the warning would appear to fix the condition it is reporting and
/// then reappear. And Station is forwarding at the moment this shows, so the pointer is
/// on the other Mac: a modal nobody can reach is a modal that traps the session.
///
/// For the same reason there is no dismiss button. Nothing here is clickable, because
/// while this is on screen the local pointer is somewhere else entirely. It goes away
/// on its own when secure input is released or when control comes back.
@MainActor
final class SecureInputPanel {

    private var window: NSPanel?

    func show(peer: String?, holder: String?, onThisMac: Bool = true) {
        let view = SecureInputWarningView(peer: peer, holder: holder, onThisMac: onThisMac)
        if let window {
            (window.contentViewController as? NSHostingController<SecureInputWarningView>)?
                .rootView = view
            window.orderFrontRegardless()
            return
        }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 130),
                            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        // Above ordinary windows, and above full-screen apps: the terminal that is
        // holding secure input is very often the full-screen window in front.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentViewController = NSHostingController(rootView: view)

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(CGPoint(x: frame.midX - 170, y: frame.maxY - 200))
        }
        panel.orderFrontRegardless()
        window = panel
    }

    func hide() {
        window?.orderOut(nil)
    }
}

struct SecureInputWarningView: View {
    let peer: String?
    let holder: String?
    /// Whether the keyboard being held is this Mac's. The same condition needs opposite
    /// wording on the two screens: here it is "your keyboard is held", and on the Mac
    /// being driven it is "the keys you are typing are not arriving".
    var onThisMac: Bool = true

    /// Two lines, because this is read at a glance or not at all.
    ///
    /// It used to carry an explanation, a reassurance about passwords, three suggested
    /// fixes and a footer. All true, none of it readable in the seconds the warning is
    /// up while the user is mid-keystroke and looking at the other Mac. What is left is
    /// what has to be understood immediately: keys are not arriving, why, and the one
    /// thing most likely to end it.
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "keyboard.badge.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(onThisMac
                     ? "Keystrokes aren't reaching \(peer ?? "the other Mac")"
                     : "\(peer ?? "The other Mac") can't send keystrokes")
                    .font(.headline)
                Text(onThisMac
                     ? "Secure Keyboard Entry is on here."
                     : "Secure Keyboard Entry is on there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                // One suggestion, not a list: naming the most likely cause is worth the
                // line it costs, because "Secure Keyboard Entry" means nothing to
                // someone who has never turned it on deliberately. On the Mac being
                // typed at, the fix is on the other one, so it says which.
                Text(onThisMac
                     ? "**How to fix:** If any app is prompting for a password, try "
                       + "entering the password or closing the app"
                     : "**How to fix:** On \(peer ?? "that Mac"), if any app is "
                       + "prompting for a password, try entering the password or "
                       + "closing the app")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }
}

/// A small floating notice for a problem the user can only act on with the keyboard.
///
/// Congestion is reported here rather than acted on. Station could take the pointer
/// back automatically when a peer falls behind, and an earlier version of that idea --
/// reclaiming control from a peer judged unresponsive -- turned out to fire against
/// peers that were perfectly healthy, snatching the pointer mid-gesture. The pointer
/// belongs to the user. Telling them what is happening, and which key ends it, leaves
/// the decision where it belongs.
///
/// It has no buttons for the same reason the secure input panel has none: while this is
/// on screen the pointer is on the other Mac, so nothing here can be clicked.
@MainActor
final class PeerLagPanel {

    private var window: NSPanel?

    func show(peer: String) {
        let view = PeerLagView(peer: peer)
        if let window {
            (window.contentViewController as? NSHostingController<PeerLagView>)?.rootView = view
            window.orderFrontRegardless()
            return
        }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 130),
                            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentViewController = NSHostingController(rootView: view)

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(CGPoint(x: frame.midX - 170, y: frame.minY + 80))
        }
        panel.orderFrontRegardless()
        window = panel
    }

    func hide() { window?.orderOut(nil) }
}

struct PeerLagView: View {
    let peer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("\(peer) is running behind").font(.headline)
            } icon: {
                Image(systemName: "tortoise").foregroundStyle(.orange)
            }

            Text("It can't keep up with the pointer, so what you do here is arriving "
                 + "there late.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Press ⌃⌥⎋ to bring control back to this Mac.")
                .font(.callout)
        }
        .padding(20)
        .frame(width: 340, alignment: .leading)
    }
}
