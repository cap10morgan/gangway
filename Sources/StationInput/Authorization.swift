import Foundation
import LocalAuthentication

/// Asks the person at this Mac to authorise something, with Touch ID or their password.
///
/// `.deviceOwnerAuthentication` rather than the biometrics-only policy: it falls back to
/// the login password automatically, so this works on Macs without Touch ID and when a
/// finger is not recognised. Requiring biometrics would simply lock some users out.
public enum Authorization {

    public enum Result: Equatable, Sendable {
        case authorized
        case declined
        /// No Touch ID and no password available, which is rare but not impossible.
        case unavailable(String)
    }

    public static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case .faceID:  return "Face ID"
        default:       return "your password"
        }
    }

    public static func confirm(reason: String) async -> Result {
        let context = LAContext()
        context.localizedCancelTitle = "Don't Allow"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable(error?.localizedDescription
                                ?? "This Mac cannot ask for authentication.")
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                      localizedReason: reason)
            return ok ? .authorized : .declined
        } catch {
            // A cancelled or failed attempt is a decline, not an error to report: the
            // user either said no or could not prove who they are, and both mean the
            // pairing must not proceed.
            return .declined
        }
    }
}
