import AppKit
import SwiftUI

/// A floating panel showing the pairing code on the Mac that asked to connect.
///
/// The code previously lived only inside the menu bar popover, which is visible only
/// while the user holds it open. Since the whole point is to compare it against the
/// prompt on the *other* Mac, a code you have to go looking for is a code nobody
/// compares. This puts it on screen by itself, and takes no keyboard focus so it cannot
/// interrupt anything.
@MainActor
final class PairingCodePanel {

    private var window: NSPanel?

    func show(name: String, code: String) {
        let view = PairingCodeView(name: name, code: code)
        if let window {
            (window.contentViewController as? NSHostingController<PairingCodeView>)?.rootView = view
            window.orderFrontRegardless()
            return
        }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 190),
                            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Visible while the user works on the other Mac, so it must not steal focus.
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentViewController = NSHostingController(rootView: view)

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(CGPoint(x: frame.midX - 160, y: frame.maxY - 260))
        }
        panel.orderFrontRegardless()
        window = panel
    }

    func hide() {
        window?.orderOut(nil)
    }
}

struct PairingCodeView: View {
    let name: String
    let code: String

    var body: some View {
        VStack(spacing: 10) {
            Text("Pairing with \(name)")
                .font(.headline)

            Text(code.map(String.init).joined(separator: " "))
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .padding(.vertical, 10)
                .padding(.horizontal, 18)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.15))
                )

            Text("Approve on \(name) only if it shows this code.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 320)
    }
}
