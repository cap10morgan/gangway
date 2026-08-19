import Foundation
import AppKit

/// Features of macOS that compete with Station for the same gesture.
public enum SystemConflicts {

    /// Universal Control's "push through the edge of a display to connect a nearby Mac
    /// or iPad".
    ///
    /// It claims the pointer at a screen edge the same way Station does, and it wins:
    /// Continuity acts below the event tap, so the pointer is gone to an iPad before
    /// Station's edge detector ever sees it. Nothing in Station can outrank that, so the
    /// only honest response is to tell the user which setting to turn off.
    public static var universalControlEdgesEnabled: Bool {
        // Per-host domain, so plain UserDefaults, which reads the global domain, never
        // sees these keys. Absent means the feature is on: these are opt-out settings.
        func hostValue(_ key: String) -> Bool? {
            CFPreferencesCopyValue(key as CFString,
                                   "com.apple.universalcontrol" as CFString,
                                   kCFPreferencesCurrentUser,
                                   kCFPreferencesCurrentHost) as? Bool
        }
        let disabled = hostValue("Disable") ?? false
        let edgesDisabled = hostValue("DisableMagicEdges") ?? false
        return !disabled && !edgesDisabled
    }

    public static func openDisplaysSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
