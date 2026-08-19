import SwiftUI
import StationKit
import StationInput

@main
struct StationApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
                .frame(width: 320)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        // A window, not a popover: arranging screens needs room, and a popover
        // dismisses whenever focus moves, which dragging does constantly.
        Window("Screen Arrangement", id: "layout") {
            LayoutEditorView(model: model)
        }
        .windowResizability(.contentMinSize)
    }
}

struct MenuContent: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if !model.permissions.allGranted {
                PermissionsSection(model: model)
            } else {
                MeshSection(model: model)
            }

            if model.isRunning {
                Divider()
                ClipboardSection(model: model)
            }

            if let error = model.lastError {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(12)
            }

            Divider()
            LoginItemSection(model: model)

            Divider()
            footer
        }
        .onAppear { model.refreshPermissions() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.menuBarSymbol)
                .foregroundStyle(model.controlIsRemote ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Station").font(.headline)
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            // Not a Start button: Station runs on its own. This is only for switching
            // it off deliberately.
            Toggle("Active", isOn: Binding(get: { model.isEnabled },
                                           set: { model.isEnabled = $0 }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(12)
    }
}

/// Station is useless without both permissions, so this replaces the whole UI until
/// they are granted rather than letting the user start something that cannot work.
struct PermissionsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Station needs two permissions")
                .font(.subheadline).bold()
            Text("Both are required on every Mac, because each one both sends and receives input.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PermissionRow(title: "Accessibility",
                          detail: "Lets Station send input to this Mac",
                          granted: model.permissions.accessibility,
                          request: { Permissions.requestAccessibility() },
                          openSettings: { Permissions.openAccessibilitySettings() })

            PermissionRow(title: "Input Monitoring",
                          detail: "Lets Station read this Mac's keyboard and trackpad",
                          granted: model.permissions.inputMonitoring,
                          request: { Permissions.requestInputMonitoring() },
                          openSettings: { Permissions.openInputMonitoringSettings() })

            HStack(spacing: 8) {
                Button("Check again") { model.refreshPermissions() }
                    .controlSize(.small)
                // A granted permission that still reads as missing usually clears with
                // a fresh process.
                Button("Relaunch Station") { model.relaunch() }
                    .controlSize(.small)
            }
        }
        .padding(12)
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if !granted {
                    HStack(spacing: 8) {
                        Button("Grant", action: request).controlSize(.small)
                        Button("Open Settings", action: openSettings).controlSize(.small)
                    }
                }
            }
            Spacer()
        }
    }
}

/// One view for the whole mesh. There is no controller/controlled choice to make: this
/// Mac is either taking part or not, and which Mac is forwarding follows the pointer.
struct MeshSection: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let waiting = model.awaitingApproval {
                // Passive, not a dialog: the decision is being made on the other Mac.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Waiting for approval on \(waiting.name)")
                        .font(.callout)
                    Text("Approve on \(waiting.name) only if it shows this code:")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(waiting.code)
                        .font(.system(size: 26, weight: .semibold, design: .monospaced))
                        .kerning(5)
                        .frame(maxWidth: .infinity)
                }
            }

            if !model.isEnabled {
                Text("Station is switched off.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !model.isRunning {
                Text("Starting…")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.peers.isEmpty {
                Text("Looking for other Macs running Station…")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Macs on this network").font(.caption).foregroundStyle(.secondary)
                ForEach(model.peers) { peer in
                    PeerRow(peer: peer, model: model)
                }
            }

            if model.isRunning {
                Button { openWindow(id: "layout") } label: {
                    Label("Arrange screens…", systemImage: "rectangle.3.group")
                }
                .font(.caption)

                Label("Control-Option-Escape returns control here",
                      systemImage: "keyboard")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }
}

struct PeerRow: View {
    let peer: DiscoveredPeer
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "display")
                .foregroundStyle(model.isPaired(peer) ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(peer.name).font(.callout)
                if model.connectedPeer == peer.name {
                    Text("Connected").font(.caption2).foregroundStyle(.green)
                } else if let step = model.nextStep(for: peer) {
                    Text(step).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Ready").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

struct LoginItemSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch model.loginItemState {
            case .enabled, .disabled:
                Toggle("Start at login", isOn: Binding(
                    get: { model.startsAtLogin },
                    set: { model.setStartAtLogin($0) }))
                    .font(.callout)
                    .toggleStyle(.switch)
                    .controlSize(.small)

            case .requiresApproval:
                // macOS will not let the app override the user's choice here, so
                // pretending the toggle works would just silently do nothing.
                VStack(alignment: .leading, spacing: 4) {
                    Label("Start at login is turned off in System Settings",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Login Items") { model.openLoginItemsSettings() }
                        .controlSize(.small)
                }

            case .unavailable(let reason):
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start at login unavailable")
                        .font(.callout)
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct ClipboardSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Share clipboard", isOn: $model.clipboardSyncEnabled)
                .font(.callout)
                .toggleStyle(.switch)
                .controlSize(.small)
            if let activity = model.lastClipboardActivity, model.clipboardSyncEnabled {
                Text(activity)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if model.clipboardSyncEnabled {
                // Say what is excluded, so nobody assumes passwords are being synced.
                Text("Items marked private by password managers are never shared.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
