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
                switch model.mode {
                case .idle:     IdleSection(model: model)
                case .receiving: ReceivingSection(model: model)
                case .sending:  SendingSection(model: model)
                }
            }

            if model.mode != .idle {
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
            if model.mode != .idle {
                Button("Stop") { model.stop() }
            }
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

struct IdleSection: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                model.startReceiving()
            } label: {
                Label("Let another Mac control this one", systemImage: "arrow.down.to.line")
            }

            Divider()

            Text("Control another Mac").font(.subheadline).bold()

            if model.peers.isEmpty {
                Text("Looking for Macs running Station on this network…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    openWindow(id: "layout")
                } label: {
                    Label("Arrange screens…", systemImage: "rectangle.3.group")
                }
                .font(.caption)

                ForEach(model.peers) { peer in
                    if let reason = model.unusableReason(for: peer) {
                        Label("\(peer.name) — \(reason)", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            model.startSending(to: peer)
                        } label: {
                            Label(peer.name, systemImage: "display")
                        }

                    }
                }
            }
        }
        .padding(12)
    }
}

struct ReceivingSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let sas = model.confirmationCode {
                ConfirmationPrompt(sas: sas,
                                   confirm: { model.confirmPairing() },
                                   reject: { model.rejectPairing() })
            } else if let peer = model.connectedPeer {
                Label("Controlled by \(peer)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                Text("Waiting for another Mac to connect…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let port = model.listeningPort {
                    // Surfaced so a stuck pairing can be tested directly, which
                    // separates a discovery problem from a connection problem.
                    Text("Listening on port \(String(port))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(12)
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

/// First-pairing check. The digits are a comparison value, not a secret: an attacker
/// who sees them gains nothing. What they prove is that nobody is interposed, because a
/// machine-in-the-middle would have to run two separate exchanges and could not make
/// both Macs display the same value.
struct ConfirmationPrompt: View {
    let sas: String
    let confirm: () -> Void
    let reject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Does the other Mac show these digits?")
                .font(.subheadline).bold()
            Text(sas)
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .kerning(6)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            Text("If they differ, someone may be intercepting the connection. Do not pair.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("They match — pair", action: confirm)
                    .keyboardShortcut(.defaultAction)
                Button("They differ", action: reject)
            }
        }
    }
}

struct SendingSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let sas = model.confirmationCode {
                ConfirmationPrompt(sas: sas,
                                   confirm: { model.confirmPairing() },
                                   reject: { model.rejectPairing() })
            } else if let peer = model.connectedPeer {
                Label("Connected to \(peer)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
            if model.confirmationCode == nil {
                Text(model.controlIsRemote
                     ? "Input is going to the other Mac."
                     : "Move the pointer off the \(model.lastUsedEdge.rawValue) edge to take over.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label("Control-Option-Escape returns control here", systemImage: "keyboard")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }
}
