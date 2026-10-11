import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

/// The two TCC permissions Gangway cannot work without.
///
/// Accessibility is required to *post* events (`kTCCServicePostEvent`) and to run a
/// consuming tap. Input Monitoring is required to *observe* events. Every Mac in the
/// mesh both sends and receives, so both are needed on every install — which is also
/// why Gangway cannot ship on the Mac App Store.
public struct Permissions: Equatable, Sendable {
    public var accessibility: Bool
    public var inputMonitoring: Bool

    public var allGranted: Bool { accessibility && inputMonitoring }

    public init(accessibility: Bool, inputMonitoring: Bool) {
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
    }

    /// Uses the dedicated CoreGraphics preflight calls rather than
    /// `AXIsProcessTrusted()`. `AXIsProcessTrusted` caches its answer for the life of
    /// the process, so an app that is running when the user flips the switch in System
    /// Settings keeps reporting "not granted" until it is relaunched.
    /// `CGPreflightPostEventAccess` reflects the change immediately and, being the
    /// permission that actually gates `CGEventPost`, is what we truly depend on.
    public static func current() -> Permissions {
        Permissions(accessibility: CGPreflightPostEventAccess(),
                    inputMonitoring: CGPreflightListenEventAccess())
    }

    /// Ask for permission to post events, which appears to the user as Accessibility.
    /// Calling this is what registers Gangway in the System Settings list; preflighting
    /// alone registers nothing.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        CGRequestPostEventAccess()
    }

    /// Ask for Input Monitoring. macOS shows this prompt only once per app version;
    /// afterwards the user must visit System Settings, so the UI always offers a link.
    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    public static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    public static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
