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

    func show(peer: String?, holder: String?) {
        let view = SecureInputWarningView(peer: peer, holder: holder)
        if let window {
            (window.contentViewController as? NSHostingController<SecureInputWarningView>)?
                .rootView = view
            window.orderFrontRegardless()
            return
        }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 220),
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
            panel.setFrameOrigin(CGPoint(x: frame.midX - 190, y: frame.maxY - 300))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Keystrokes aren't reaching \(peer ?? "the other Mac")")
                    .font(.headline)
            } icon: {
                Image(systemName: "keyboard.badge.exclamationmark")
                    .foregroundStyle(.orange)
            }

            Text("An app on this Mac has Secure Keyboard Entry turned on, which stops "
                 + "Station from reading the keyboard. The pointer and trackpad still "
                 + "work normally.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Labelled as a guess on purpose. macOS exposes no way to ask which process
            // holds secure input, and stating the frontmost app as fact would send
            // people to quit something innocent.
            if let holder {
                Text("Most likely **\(holder)**, which is frontmost.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(SecureInput.quickFixes, id: \.self) { fix in
                    Text("• \(fix)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("This closes itself once the keyboard is free.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 380, alignment: .leading)
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
