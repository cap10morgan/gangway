import Foundation
import AppKit

/// Features of macOS that can compete with Station for the same gesture.
public enum SystemConflicts {

    /// Whether Universal Control is allowed to hand the pointer to a nearby device by
    /// pushing through a screen edge.
    ///
    /// Being enabled does **not** mean Station is broken: the two coexist happily
    /// unless a Universal Control device sits at the same edge as a Station Mac, in
    /// which case Continuity claims the pointer first because it acts below the event
    /// tap. Which edge it occupies is not discoverable — the setting's `Configuration`
    /// is an opaque Continuity archive — so this can only ever say the conflict is
    /// *possible*, never that it is happening.
    ///
    /// That is why this belongs next to the arrangement, where edges are being chosen,
    /// rather than as a standing warning. Enabled is the default, so a permanent alarm
    /// would fire for nearly everyone and teach them to ignore it.
    public static var universalControlEdgesEnabled: Bool {
        // Per-host domain, which plain UserDefaults never reads. Both keys are opt-out,
        // so absent means the feature is on.
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
