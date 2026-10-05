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
        /// The bundle is somewhere macOS will not register, typically because it is
        /// still in a build directory or on a disk image.
        case unavailable(String)
    }

    public static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled:          return .enabled
        case .notRegistered:    return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound:         return .unavailable("Gangway is not in a location macOS can launch from.")
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
                guard SMAppService.mainApp.status != .notRegistered else { return }
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
