import Foundation
import Carbon
import AppKit

/// Secure Event Input, which any application can turn on.
///
/// While it is active, event taps stop receiving keyboard events entirely, but keep
/// receiving mouse events. That asymmetry is worth naming: it presents as "the pointer
/// moves to the other Mac but nothing I type arrives", which looks like a bug in
/// forwarding rather than a system-wide input restriction.
///
/// Terminal's "Secure Keyboard Entry" is the usual cause; focused password fields and
/// some password managers do it too.
public enum SecureInput {
    public static var isEnabled: Bool { IsSecureEventInputEnabled() }

    /// Which process turned it on, when that can be determined.
    ///
    /// The window server records the owning pid in its session properties. There is no
    /// API for it, so this reads the same value `ioreg` exposes; it is advisory only,
    /// and naming the culprit turns an unexplained failure into an obvious one.
    public static func holdingProcess() -> (pid: pid_t, name: String?)? {
        guard isEnabled else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        task.arguments = ["-l", "-w", "0", "-d", "1", "-k", "kCGSSessionSecureInputPID"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8),
              let line = text.split(separator: "\n")
                .first(where: { $0.contains("kCGSSessionSecureInputPID") }),
              let value = line.split(separator: "=").last,
              let pid = pid_t(value.trimmingCharacters(in: .whitespaces)) else { return nil }

        let name = NSRunningApplication(processIdentifier: pid)?.localizedName
        return (pid, name)
    }
}
