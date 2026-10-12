import Foundation
import ServiceManagement
import AppKit

/// Registers Gangway to start at login.
///
/// `SMAppService.mainApp` rather than a separate helper: Gangway is a menu bar app with
/// no dock presence, so the app itself is the right thing to launch. A helper would add
/// a second bundle to sign, notarize and keep in step for no benefit.
public enum LoginItem {

    public enum State: Equatable, Sendable {
        case enabled
        case disabled
        /// Registered, but the user switched it off in System Settings. macOS will not
        /// let the app override that, so the UI has to send them there rather than
        /// silently failing to enable.
        case requiresApproval
        /// A status this version of Gangway does not know.
        case unavailable(String)
        /// macOS is running a temporary copy of the bundle instead of the one the user
        /// installed. It does this to a downloaded app that still carries its
        /// quarantine flag and was not moved into place with Finder, and the copy lives
        /// at a random read-only path that cannot be registered -- or updated. Being in
        /// the Applications folder does not help; the flag has to go.
        case translocated
    }

    /// Whether this process was launched from an App Translocation copy.
    public static var isTranslocated: Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    public static var state: State {
        // Checked first: a translocated app reports `.notFound`, which reads as "not in
        // Applications" and sends the user to fix the one thing that is already right.
        if isTranslocated { return .translocated }
        switch SMAppService.mainApp.status {
        case .enabled:          return .enabled
        // `.notFound` is what macOS reports for an app that has never been registered,
        // wherever it is installed: measured on macOS 27 with a fresh bundle in
        // /Applications, where `register()` then succeeded and the status became
        // `.enabled`. Treating it as "wrong location" disabled the switch, so the one
        // call that would have cleared it could never be made.
        case .notRegistered, .notFound: return .disabled
        case .requiresApproval: return .requiresApproval
        @unknown default:       return .unavailable("Unknown login item status.")
        }
    }

    public static var isEnabled: Bool { state == .enabled }

    public enum LoginItemError: LocalizedError {
        case registrationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .registrationFailed(let detail):
                return "Could not change the login item: \(detail)"
            }
        }
    }

    public static func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                // Registering while already registered throws, which is not a failure
                // the user needs to hear about.
                guard SMAppService.mainApp.status != .enabled else { return }
                try SMAppService.mainApp.register()
            } else {
                let status = SMAppService.mainApp.status
                guard status != .notRegistered, status != .notFound else { return }
                try SMAppService.mainApp.unregister()
            }
        } catch {
            throw LoginItemError.registrationFailed(error.localizedDescription)
        }
    }

    /// Open the Login Items pane, for the cases the app cannot resolve itself.
    public static func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
