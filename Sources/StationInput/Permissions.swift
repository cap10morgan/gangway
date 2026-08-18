import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

/// The two TCC permissions Station cannot work without.
///
/// Accessibility is required to *post* events (`kTCCServicePostEvent`) and to run a
/// consuming tap. Input Monitoring is required to *observe* events. Every Mac in the
/// mesh both sends and receives, so both are needed on every install — which is also
/// why Station cannot ship on the Mac App Store. See FINDINGS.md section 3.
public struct Permissions: Equatable, Sendable {
    public var accessibility: Bool
    public var inputMonitoring: Bool

    public var allGranted: Bool { accessibility && inputMonitoring }

    public init(accessibility: Bool, inputMonitoring: Bool) {
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
    }

    public static func current() -> Permissions {
        Permissions(accessibility: AXIsProcessTrusted(),
                    inputMonitoring: CGPreflightListenEventAccess())
    }

    /// Ask for Accessibility, prompting the user.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        // The literal key rather than kAXTrustedCheckOptionPrompt: the imported global
        // is a mutable var and so is not concurrency-safe under Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
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
