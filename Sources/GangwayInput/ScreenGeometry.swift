import Foundation
import CoreGraphics
import GangwayKit

/// Reads the local display arrangement in the coordinate space `CGEvent` uses:
/// origin at the top-left of the main display, y increasing downward.
///
/// Deliberately not `NSScreen`, whose frames use a bottom-left origin. Mixing the two
/// conventions inverts vertical edge transitions in a way that is tedious to debug.
public enum ScreenGeometry {

    public static func localScreens() -> ScreenSet {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return ScreenSet(screens: [])
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return ScreenSet(screens: [])
        }
        let main = CGMainDisplayID()
        let screens = ids.prefix(Int(count)).map { id -> ScreenInfo in
            let b = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            // pixelWidth exceeds width on Retina panels; the ratio is the scale factor.
            let scale = (mode?.pixelWidth).map { Double($0) / Double(max(b.width, 1)) } ?? 1
            return ScreenInfo(displayID: id,
                              frame: Rect(x: b.origin.x, y: b.origin.y,
                                          width: b.width, height: b.height),
                              isMain: id == main,
                              backingScale: scale)
        }
        return ScreenSet(screens: Array(screens))
    }

    /// Union of all local displays.
    public static var globalBounds: Rect { localScreens().bounds }

    public static var currentCursor: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}
