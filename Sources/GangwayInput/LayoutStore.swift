import Foundation
import GangwayKit

/// Persists the screen arrangement.
///
/// Plain UserDefaults: an arrangement is a preference, not a secret. It names Macs and
/// their public identities, neither of which is sensitive.
public enum LayoutStore {

    private static let key = "com.timetraveltoaster.Gangway.layoutGrid"

    public static func load() -> ScreenLayoutGrid {
        guard let data = UserDefaults.standard.data(forKey: key),
              let grid = try? JSONDecoder().decode(ScreenLayoutGrid.self, from: data) else {
            return ScreenLayoutGrid()
        }
        return grid
    }

    public static func save(_ grid: ScreenLayoutGrid) {
        guard let data = try? JSONEncoder().encode(grid) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Ensure this Mac is on the grid, since an arrangement with no local Mac has no
    /// reference point for any of the others.
    public static func ensureLocal(_ id: DeviceID, name: String,
                                   in grid: inout ScreenLayoutGrid) {
        if grid.placement(of: id) == nil {
            grid.place(id, name: name, at: GridPosition(column: 0, row: 0))
        } else {
            grid.rename(id, to: name)
        }
    }
}
