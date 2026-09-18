import AppKit
import SwiftUI
import StationKit
import StationInput

@main
struct StationApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            StationMenu(model: model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        // A real pull-down rather than a custom panel.
        //
        // The previous menu was a SwiftUI window: switches, captions, cards and a
        // bespoke footer. It worked, but it behaved like nothing else in the menu bar --
        // no keyboard navigation, no highlight-to-select, no standard Settings or Quit
        // items -- and every piece of explanatory text had to live in it because there
        // was nowhere else to put them. A menu holds commands and state; anything that
        // needs a paragraph belongs in Settings.
        .menuBarExtraStyle(.menu)

        // A window, not a popover: arranging screens needs room, and a popover
        // dismisses whenever focus moves, which dragging does constantly.
        Window("Screen Arrangement", id: "layout") {
            LayoutEditorView(model: model)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// The menu bar pull-down: state and commands only.
struct StationMenu: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // No status header. Which Mac holds control changes constantly and belongs to
        // whichever one the pointer is on, so stating it here was both redundant with
        // the peer list and out of date the moment it was read.
        if model.permissions.allGranted {
            settingsToggles
        } else {
            Text("Station needs Accessibility and Input Monitoring")
            SettingsLink { Text("Grant Permissions…") }
        }

        approvalItems

        peerItems

        if let error = model.lastError {
            Divider()
            Text(error)
        }

        Divider()

        if model.isRunning {
            Button("Arrange Screens…") { openWindow(id: "layout") }
        }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit Station") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Toggles become checkmarked items, which is what a menu uses for a setting that
    /// is simply on or off.
    @ViewBuilder
    private var settingsToggles: some View {
        Toggle("Active", isOn: Binding(get: { model.isEnabled },
                                       set: { model.isEnabled = $0 }))
        Toggle("Share Clipboard", isOn: $model.clipboardSyncEnabled)
            .disabled(!model.isRunning)
        Toggle("Start at Login", isOn: Binding(get: { model.startsAtLogin },
                                               set: { model.setStartAtLogin($0) }))
            .disabled(!loginItemIsToggleable)
    }

    /// macOS will not let the app override the user's own choice in Login Items, so a
    /// toggle that appears to work and silently does nothing would be a lie. Settings
    /// explains what to do instead.
    private var loginItemIsToggleable: Bool {
        switch model.loginItemState {
        case .enabled, .disabled: return true
        case .requiresApproval, .unavailable: return false
        }
    }

    /// Approving is Touch ID, and the code being compared is shown in its own floating
    /// panel, so the menu needs only the two commands.
    @ViewBuilder
    private var approvalItems: some View {
        if let pending = model.pendingApproval {
            Divider()
            Text("\(pending.name) wants to control this Mac")
            Button("Approve \(pending.name)…") { Task { await model.approvePending() } }
            Button("Decline") { model.declinePending() }
        }
        if let waiting = model.awaitingApproval {
            Divider()
            Text("Waiting for approval on \(waiting.name)")
        }
    }

    @ViewBuilder
    private var peerItems: some View {
        if model.isRunning, !model.peers.isEmpty {
            Divider()
            Text("Macs on This Network")
            ForEach(model.peers) { peer in
                Label {
                    Text(peerSummary(peer))
                } icon: {
                    Image(nsImage: status(of: peer).image)
                        .renderingMode(.original)
                }
            }
        }
    }

    /// Emoji rather than an SF Symbol, because the colour is the whole point.
    ///
    /// A menu item's image is a template image, so `Image(systemName: "circle.fill")`
    /// tinted green arrives in the menu as a grey dot. Emoji carry their own colour and
    /// survive the trip into AppKit intact.
    /// Three states, because two conflated the only two things a dot can mean here.
    /// Red on a Mac that has never been paired reads as a fault, when nothing is wrong
    /// with it at all -- it simply has not been set up yet, which is a thing to go and
    /// do rather than a thing to worry about.
    private func isConnected(_ peer: DiscoveredPeer) -> Bool {
        peer.deviceID != nil && peer.deviceID == model.connectedPeerID
    }

    private func status(of peer: DiscoveredPeer) -> StatusDot {
        if isConnected(peer) { return .connected }
        return model.isPaired(peer) ? .offline : .unpaired
    }

    private func peerSummary(_ peer: DiscoveredPeer) -> String {
        if isConnected(peer) { return "\(peer.name) — Connected" }
        if let step = model.nextStep(for: peer) { return "\(peer.name) — \(step)" }
        return peer.name
    }
}


/// A small coloured dot for a menu row.
///
/// Drawn as a non-template `NSImage` rather than a tinted SF Symbol or an emoji. A menu
/// item's image is treated as a template, so `circle.fill` tinted green arrives grey;
/// emoji keep their colour but are as tall as the text and far too loud beside it.
/// Drawing it gives both the colour and the size: a few points across, sitting quietly
/// to the left of the name.
enum StatusDot {
    case connected, offline, unpaired

    private var color: NSColor {
        switch self {
        case .connected: return .systemGreen
        case .offline:   return .systemRed
        case .unpaired:  return .systemOrange
        }
    }

    var image: NSImage {
        let side: CGFloat = 7
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.25, dy: 0.25)).fill()
            return true
        }
        // Not a template: a template image is recoloured to the menu's text colour,
        // which is exactly the thing being avoided.
        image.isTemplate = false
        return image
    }
}
