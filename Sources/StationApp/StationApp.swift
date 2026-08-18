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

            if let error = model.lastError {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(12)
            }

            Divider()
            footer
        }
        .onAppear {
            model.refreshPermissions()
            model.startDiscovery()
        }
        .onDisappear { model.stopDiscovery() }
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

            Button("Check again") { model.refreshPermissions() }
                .controlSize(.small)
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
                Picker("This Mac is on the", selection: $model.edge) {
                    // Where the *peer* sits relative to this Mac.
                    ForEach(ScreenEdge.allCases, id: \.self) { edge in
                        Text(edge.rawValue.capitalized).tag(edge)
                    }
                }
                .font(.caption)

                TextField("6-digit code", text: $model.enteredCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                ForEach(model.peers) { peer in
                    Button {
                        model.startSending(to: peer)
                    } label: {
                        Label(peer.name, systemImage: "display")
                    }
                    .disabled(model.enteredCode.count != Pairing.codeDigits)
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
            if let code = model.pairingCode {
                Text("Enter this code on the other Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(code)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .kerning(4)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            if let peer = model.connectedPeer {
                Label("Controlled by \(peer)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
        }
        .padding(12)
    }
}

struct SendingSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let peer = model.connectedPeer {
                Label("Connected to \(peer)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
            Text(model.controlIsRemote
                 ? "Input is going to the other Mac."
                 : "Move the pointer off the \(model.edge.rawValue) edge to take over.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label("Control-Option-Escape returns control here", systemImage: "keyboard")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }
}
