import Foundation
import AppKit

/// Features of macOS that can compete with Station for the same gesture.
public enum SystemConflicts {

    /// Whether Universal Control is allowed to hand the pointer to a nearby device by
    /// pushing through a screen edge.
    ///
    /// The two can coexist, but not cleanly. Continuity watches screen edges too, and
    /// acts below the event tap, so it claims the pointer first when one of its devices
    /// sits at the same edge. Even when it does not take the pointer, having both
    /// watching the same edges was observed to make crossings feel jerky and to make
    /// the cursor briefly vanish; turning it off resolved that.
    ///
    /// Which edge its devices occupy is not discoverable — the setting's
    /// `Configuration` is an opaque Continuity archive — so this can only say the
    /// conflict is *possible*, never that it is happening.
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
