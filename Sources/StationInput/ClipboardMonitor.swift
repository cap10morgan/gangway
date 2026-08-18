import Foundation
import AppKit
import StationKit

/// Watches the local pasteboard and applies clipboard content from a peer.
///
/// `NSPasteboard` has no change notification, so polling `changeCount` is the only
/// option. It is cheap: an integer read, not a content read.
public final class ClipboardMonitor: @unchecked Sendable {

    /// Representations worth carrying. An allowlist rather than "everything the item
    /// offers", because applications attach large private representations that the
    /// receiving Mac cannot interpret anyway.
    static let syncedTypes: [NSPasteboard.PasteboardType] = [
        .string, .rtf, .rtfd, .html, .png, .tiff, .pdf, .fileURL, .URL,
    ]

    /// Types whose presence means the content must not leave this Mac.
    ///
    /// Password managers mark their pasteboard items concealed precisely so clipboard
    /// tools ignore them. Syncing a password to another machine over the network,
    /// silently, is exactly the behaviour that marking exists to prevent.
    static let privateTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "com.agilebits.onepassword",
    ]

    private let pasteboard: NSPasteboard
    private var lastChangeCount: Int
    private var timer: Timer?

    /// Local clipboard changed and should be sent to the peer.
    public var onLocalChange: (@Sendable (ClipboardContent) -> Void)?
    public var onSkipped: (@Sendable (String) -> Void)?

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
    }

    public func start(interval: TimeInterval = 0.5) {
        stop()
        // Seed from the current state so we do not immediately broadcast whatever
        // happened to be on the clipboard before the session started.
        lastChangeCount = pasteboard.changeCount
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        guard let content = readLocal() else { return }
        guard !content.items.isEmpty else { return }
        onLocalChange?(content)
    }

    /// Read the current pasteboard, or nil if it must not be shared.
    func readLocal() -> ClipboardContent? {
        guard let items = pasteboard.pasteboardItems else { return nil }

        for item in items {
            let types = Set(item.types.map(\.rawValue))
            if !types.isDisjoint(with: Self.privateTypes) {
                onSkipped?("clipboard marked private; not shared")
                return nil
            }
        }

        var out: [ClipboardItem] = []
        var total = 0
        for item in items {
            var representations: [String: Data] = [:]
            for type in Self.syncedTypes where item.types.contains(type) {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                if total > ClipboardTransfer.maxTotalSize {
                    onSkipped?("clipboard too large to share")
                    return nil
                }
                representations[type.rawValue] = data
            }
            if !representations.isEmpty {
                out.append(ClipboardItem(representations: representations))
            }
        }
        return out.isEmpty ? nil : ClipboardContent(items: out)
    }

    /// Apply content received from a peer.
    ///
    /// Writing bumps `changeCount`, which the poller would otherwise read as a fresh
    /// local copy and send straight back, so the new count is recorded before returning.
    /// Without that the two Macs ping-pong the same clipboard indefinitely.
    public func apply(_ content: ClipboardContent) {
        let items: [NSPasteboardItem] = content.items.map { item in
            let pasteboardItem = NSPasteboardItem()
            for (type, data) in item.representations {
                pasteboardItem.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return pasteboardItem
        }
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        lastChangeCount = pasteboard.changeCount
    }
}
