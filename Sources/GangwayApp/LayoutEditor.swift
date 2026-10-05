import SwiftUI
import GangwayKit
import GangwayInput

/// Drag-to-arrange editor for where each Mac sits relative to the others.
///
/// A window rather than a menu bar popover: arranging screens needs room, and a
/// popover dismisses whenever focus moves, which drag-and-drop does constantly.
struct LayoutEditorView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private let cell: CGFloat = 108
    private let gap: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            ScrollView([.horizontal, .vertical]) {
                gridView.padding(20)
            }
            .frame(minHeight: 260)
            .background(Color(nsColor: .underPageBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if !model.unplacedPeers.isEmpty {
                unplacedTray
            }

            universalControlNote
            footer
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Screen Arrangement").font(.headline)
            Text("Drag each Mac to sit where it does on your desk. The pointer crosses "
                 + "between Macs that touch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One cell per placed Mac, plus every free cell adjacent to one, so there is
    /// always somewhere to drop.
    private var gridView: some View {
        let extent = model.grid.extent
        let columns = (extent.columns.lowerBound - 1)...(extent.columns.upperBound + 1)
        let rows = (extent.rows.lowerBound - 1)...(extent.rows.upperBound + 1)
        let available = model.grid.availableCells

        return VStack(spacing: gap) {
            ForEach(Array(rows), id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(Array(columns), id: \.self) { column in
                        let position = GridPosition(column: column, row: row)
                        cellView(at: position, isDroppable: available.contains(position))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cellView(at position: GridPosition, isDroppable: Bool) -> some View {
        if let placement = model.grid.placement(at: position) {
            MacTile(name: placement.name,
                    isLocal: placement.id == model.localDeviceID,
                    isConnected: model.connectedPeerID == placement.id)
                .frame(width: cell, height: cell * 0.68)
                .draggable(placement.id)
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first else { return false }
                    model.moveMac(id, to: position)
                    return true
                }
        } else if isDroppable {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(.tertiary)
                .frame(width: cell, height: cell * 0.68)
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first else { return false }
                    model.moveMac(id, to: position)
                    return true
                }
        } else {
            Color.clear.frame(width: cell, height: cell * 0.68)
        }
    }

    /// Paired Macs not yet on the grid. Without somewhere to show them they would be
    /// invisible and unplaceable.
    private var unplacedTray: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Not placed").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: gap) {
                ForEach(model.unplacedPeers, id: \.id) { peer in
                    MacTile(name: peer.name, isLocal: false, isConnected: false)
                        .frame(width: cell * 0.8, height: cell * 0.5)
                        .draggable(peer.id)
                }
            }
        }
    }

    /// Advice, not an alarm. Universal Control only takes an edge when one of its
    /// devices happens to occupy that edge, and which edge that is cannot be read from
    /// the system, so this says what to watch for at the moment edges are being chosen.
    @ViewBuilder
    private var universalControlNote: some View {
        if model.universalControlEdgesEnabled {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "info.circle")
                Text("Universal Control also watches screen edges. If it is on, the "
                     + "pointer can jump to a nearby iPad, and moving between Macs may "
                     + "feel jerky even when it does not. Turning off \"Push through "
                     + "the edge of a display\" makes Gangway's edges more reliable.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Displays…") { model.openDisplaysSettings() }
                    .controlSize(.small)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if !model.grid.isConnected(from: model.localDeviceID) {
                Label("Some Macs are not reachable from this one", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            // Every drag already saves, so this only closes the window. It used to
            // call save and nothing else, which looked like a button that did nothing.
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

struct MacTile: View {
    let name: String
    let isLocal: Bool
    let isConnected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: isLocal ? "laptopcomputer" : "display")
                .font(.title2)
            Text(name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            if isLocal {
                Text("This Mac").font(.caption2).foregroundStyle(.secondary)
            } else if isConnected {
                Text("Connected").font(.caption2).foregroundStyle(.green)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isLocal ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isLocal ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.25))
        )
    }
}
