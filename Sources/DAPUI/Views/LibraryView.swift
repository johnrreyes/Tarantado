import SwiftUI
import DAPDB

/// What's on the DAP, and the only place to delete it.
///
/// Deleting is deliberately a two-step affair — tick tracks, then confirm a
/// dialog that names the count and says what a backup does and doesn't
/// cover. Backups hold the database, not audio, so this is the one
/// destructive action in the app that nothing can undo.
struct LibraryView: View {
    @Bindable var model: AppModel
    @Binding var step: RootView.Step?

    @State private var searchText = ""
    @State private var isConfirmingRemoval = false
    @State private var grouping: TrackGrouping = .songs

    var body: some View {
        Group {
            if model.deviceTracks.isEmpty {
                ContentUnavailableView {
                    Label("No music on this DAP", systemImage: "music.note")
                } description: {
                    Text("Add some from the Local Library tab.")
                } actions: {
                    Button("Choose Music") { step = .localLibrary }
                }
            } else {
                trackList
            }
        }
        .navigationTitle("DAP Library")
        .toolbar {
            if !model.selectedDeviceTrackIDs.isEmpty {
                ToolbarItem {
                    Button("Remove \(model.selectedDeviceTrackIDs.count)…", role: .destructive) {
                        isConfirmingRemoval = true
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete \(model.selectedDeviceTrackIDs.count) track\(model.selectedDeviceTrackIDs.count == 1 ? "" : "s") from this DAP?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await model.removeTracksFromDevice(Array(model.selectedDeviceTrackIDs)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The audio files are deleted from the DAP, along with their entries in every playlist. A backup of the database is written first, but backups don't cover audio — this can't be undone.")
        }
        .overlay { EditStatusOverlay(model: model) }
    }

    private var trackList: some View {
        List {
            switch grouping {
            case .songs:
                Section {
                    ForEach(matching, id: \.uniqueID) { track in
                        trackRow(track)
                    }
                } header: {
                    HStack {
                        Text("\(model.deviceTracks.count) track\(model.deviceTracks.count == 1 ? "" : "s") on DAP")
                        Spacer()
                        selectAllButton(for: matching)
                        if !model.selectedDeviceTrackIDs.isEmpty {
                            Button("Clear") { model.selectedDeviceTrackIDs.removeAll() }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                                .font(.caption)
                                .textCase(nil)
                        }
                    }
                }
            case .artists, .albums:
                ForEach(groups, id: \.name) { group in
                    Section {
                        ForEach(group.tracks, id: \.uniqueID) { track in
                            trackRow(track)
                        }
                    } header: {
                        HStack {
                            Text(group.name)
                            Spacer()
                            selectAllButton(for: group.tracks)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Filter by title or artist")
        .safeAreaInset(edge: .top) {
            TrackGroupingPicker(grouping: $grouping)
        }
    }

    private func trackRow(_ track: Track) -> some View {
        Button {
            toggle(track.uniqueID)
        } label: {
            HStack {
                Image(systemName: model.selectedDeviceTrackIDs.contains(track.uniqueID) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.selectedDeviceTrackIDs.contains(track.uniqueID) ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title ?? "Untitled")
                    Text(secondaryLabel(for: track))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Formatting.duration(ms: Int(track.length)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Inside an artist or album section, repeating the thing you grouped by
    /// on every row is noise — show the other one.
    private func secondaryLabel(for track: Track) -> String {
        switch grouping {
        case .songs, .albums: return track.artist ?? "Unknown Artist"
        case .artists: return track.album ?? "Unknown Album"
        }
    }

    private func selectAllButton(for tracks: [Track]) -> some View {
        let ids = tracks.map(\.uniqueID)
        let isFullySelected = !ids.isEmpty && ids.allSatisfy { model.selectedDeviceTrackIDs.contains($0) }
        return SelectAllButton(isFullySelected: isFullySelected) {
            if isFullySelected {
                model.selectedDeviceTrackIDs.subtract(ids)
            } else {
                model.selectedDeviceTrackIDs.formUnion(ids)
            }
        }
    }

    // MARK: - Grouping

    private struct TrackGroup {
        let name: String
        let tracks: [Track]
    }

    private var groups: [TrackGroup] {
        // The DAP's database has no album-artist field, so the album key
        // falls back to the track artist.
        let keyed = Dictionary(grouping: matching) { track in
            grouping.sectionName(artist: track.artist, album: track.album)
        }
        return keyed
            .map { TrackGroup(name: $0.key, tracks: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func toggle(_ id: UInt32) {
        if model.selectedDeviceTrackIDs.contains(id) {
            model.selectedDeviceTrackIDs.remove(id)
        } else {
            model.selectedDeviceTrackIDs.insert(id)
        }
    }

    private var matching: [Track] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = model.deviceTracks.sorted {
            ($0.artist ?? "", $0.album ?? "", $0.trackNumber) < ($1.artist ?? "", $1.album ?? "", $1.trackNumber)
        }
        guard !query.isEmpty else { return sorted }
        return sorted.filter {
            ($0.title ?? "").lowercased().contains(query) || ($0.artist ?? "").lowercased().contains(query)
        }
    }
}

/// Shared busy/error surface for the edit operations, so every screen that
/// mutates the device reports progress and failure the same way.
struct EditStatusOverlay: View {
    @Bindable var model: AppModel

    var body: some View {
        switch model.editState {
        case .idle:
            EmptyView()
        case .working(let description):
            VStack(spacing: 10) {
                ProgressView()
                Text(description).font(.callout)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .failed(let message):
            VStack(spacing: 12) {
                Label("That didn't work", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("OK") { model.dismissEditError() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
