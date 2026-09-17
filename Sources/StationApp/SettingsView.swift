import SwiftUI
import StationKit
import StationInput

/// The Settings window, opened with ⌘, like any other Mac app.
///
/// Everything here used to live in the menu bar popover, which forced the menu to carry
/// paragraphs of explanation and left no room to say anything properly. A menu holds
/// commands; the reasoning behind them belongs somewhere you can read it.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            PermissionsSettings(model: model)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 460)
        .onAppear { model.refreshPermissions() }
    }
}

struct GeneralSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Active", isOn: Binding(get: { model.isEnabled },
                                               set: { model.isEnabled = $0 }))
                Text("Station runs on its own. Turning this off is remembered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Clipboard") {
                Toggle("Share clipboard between Macs", isOn: $model.clipboardSyncEnabled)
                // Phrased for the moment before the decision. What someone weighing this
                // up wants to know is whether turning it on will leak a password, and
                // saying so only afterwards is too late to reassure.
                Text("Items marked private by password managers are never shared.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let activity = model.lastClipboardActivity, model.clipboardSyncEnabled {
                    Text(activity).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Startup") {
                switch model.loginItemState {
                case .enabled, .disabled:
                    Toggle("Start at login", isOn: Binding(
                        get: { model.startsAtLogin },
                        set: { model.setStartAtLogin($0) }))
                case .requiresApproval:
                    // macOS will not let the app override the user's choice here, so
                    // pretending the toggle works would just silently do nothing.
                    Label("Start at login is turned off in System Settings",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Open Login Items…") { model.openLoginItemsSettings() }
                case .unavailable:
                    // Almost always because the app is still in a build directory.
                    Text("Start at login needs Station in your Applications folder.")
                    Text("Move Station.app there, then reopen it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Control") {
                Label("Control-Option-Escape always returns control to this Mac",
                      systemImage: "keyboard")
                    .font(.callout)
                if model.universalControlEdgesEnabled {
                    Text("Universal Control also uses screen edges. If the pointer "
                         + "sometimes goes to the wrong Mac, turn its edge setting off "
                         + "in Displays.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Displays…") { model.openDisplaysSettings() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Station is useless without both permissions, and each Mac needs both: every Mac
/// sends and receives input, so there is no lesser role to fall back to.
struct PermissionsSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Text("Both permissions are required on every Mac, because each one "
                     + "both sends and receives input.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
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
            }

            Section {
                HStack {
                    Button("Check Again") { model.refreshPermissions() }
                    // A granted permission that still reads as missing usually clears
                    // with a fresh process.
                    Button("Relaunch Station") { model.relaunch() }
                }
            }
        }
        .formStyle(.grouped)
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
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if !granted {
                    HStack(spacing: 8) {
                        Button("Grant", action: request).controlSize(.small)
                        Button("Open Settings…", action: openSettings).controlSize(.small)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
