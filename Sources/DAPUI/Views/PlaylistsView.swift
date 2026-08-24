import SwiftUI
import DAPDB

/// Playlist management: create, rename, delete, add and remove tracks, and
/// reorder by dragging.
///
/// Only regular playlists are editable. The master playlist is every track
/// on the device, and smart playlists are opaque rule blobs this library
/// preserves byte-for-byte and never rewrites — both are shown, greyed, so
/// their absence from the editable list doesn't look like a bug.
struct PlaylistsView: View {
    @Bindable var model: AppModel
    @Binding var step: RootView.Step?

    @State private var selectedPlaylistID: UInt64?
    @State private var isCreating = false
    @State private var newPlaylistTitle = ""
    @State private var renamingPlaylist: Playlist?
    @State private var renameTitle = ""
    @State private var deletingPlaylist: Playlist?
    @State private var isAddingTracks = false

    var body: some View {
        Group {
            if model.devicePlaylists.isEmpty {
                ContentUnavailableView("No playlists", systemImage: "music.note.list")
            } else {
                content
            }
        }
        .navigationTitle("Playlists")
        .toolbar {
            ToolbarItem {
                Button {
                    newPlaylistTitle = ""
                    isCreating = true
                } label: {
                    Label("New Playlist", systemImage: "plus")
                }
                .disabled(model.deviceTracks.isEmpty)
            }
        }
        .alert("New Playlist", isPresented: $isCreating) {
            TextField("Name", text: $newPlaylistTitle)
            Button("Create") {
                let title = newPlaylistTitle.trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { return }
                Task { await model.createPlaylist(title: title) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Playlist", isPresented: Binding(get: { renamingPlaylist != nil }, set: { if !$0 { renamingPlaylist = nil } })) {
            TextField("Name", text: $renameTitle)
            Button("Rename") {
                guard let playlist = renamingPlaylist else { return }
                let title = renameTitle.trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { return }
                Task { await model.renamePlaylist(id: playlist.id, to: title) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(deletingPlaylist?.title ?? "")”?",
            isPresented: Binding(get: { deletingPlaylist != nil }, set: { if !$0 { deletingPlaylist = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Playlist", role: .destructive) {
                guard let playlist = deletingPlaylist else { return }
                Task { await model.deletePlaylist(id: playlist.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the playlist is deleted. Its tracks stay on the DAP.")
        }
        .sheet(isPresented: $isAddingTracks) {
            if let playlist = selected {
                AddTracksSheet(model: model, playlist: playlist)
            }
        }
        .overlay { EditStatusOverlay(model: model) }
    }

    private var content: some View {
        HStack(spacing: 0) {
            playlistList
                .frame(minWidth: 220, maxWidth: 300)
            Divider()
            detail
        }
    }

    private var playlistList: some View {
        List(selection: $selectedPlaylistID) {
            Section("Editable") {
                ForEach(model.editablePlaylists, id: \.id) { playlist in
                    row(playlist)
                        .tag(playlist.id)
                        .contextMenu {
                            Button("Rename…") {
                                renameTitle = playlist.title ?? ""
                                renamingPlaylist = playlist
                            }
                            Button("Delete…", role: .destructive) { deletingPlaylist = playlist }
                        }
                }
                if model.editablePlaylists.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                }
            }

            let readOnly = model.devicePlaylists.filter { $0.isMaster || $0.isSmart }
            if !readOnly.isEmpty {
                Section("Read-only") {
                    ForEach(readOnly, id: \.id) { playlist in
                        row(playlist).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func row(_ playlist: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(playlist.title ?? "(untitled)")
            Text(subtitle(for: playlist))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func subtitle(for playlist: Playlist) -> String {
        let count = playlist.trackIDsInOrder.count
        let tracks = "\(count) track\(count == 1 ? "" : "s")"
        if playlist.isMaster { return "\(tracks) · everything on the DAP" }
        if playlist.isSmart { return "\(tracks) · smart, read-only" }
        return tracks
    }

    private var selected: Playlist? {
        guard let selectedPlaylistID else { return nil }
        return model.devicePlaylists.first { $0.id == selectedPlaylistID }
    }

    @ViewBuilder
    private var detail: some View {
        if let playlist = selected {
            PlaylistDetailView(model: model, playlist: playlist, isAddingTracks: $isAddingTracks)
        } else {
            ContentUnavailableView("Select a playlist", systemImage: "sidebar.left")
        }
    }
}

/// One playlist's contents: reorderable by dragging, removable by swipe.
private struct PlaylistDetailView: View {
    @Bindable var model: AppModel
    let playlist: Playlist
    @Binding var isAddingTracks: Bool

    var body: some View {
        List {
            Section {
                ForEach(playlist.trackIDsInOrder, id: \.self) { trackID in
                    if let track = model.deviceTrack(id: trackID) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title ?? "Untitled")
                            Text(track.artist ?? "Unknown Artist")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Track \(trackID) — not on this DAP")
                            .foregroundStyle(.secondary)
                    }
                }
                .onMove { indices, destination in
                    guard isEditable else { return }
                    var order = playlist.trackIDsInOrder
                    order.move(fromOffsets: indices, toOffset: destination)
                    Task { await model.reorderPlaylist(id: playlist.id, trackIDsInOrder: order) }
                }
                .onDelete { offsets in
                    guard isEditable else { return }
                    let ids = offsets.map { playlist.trackIDsInOrder[$0] }
                    Task { await model.removeTracks(ids, fromPlaylistID: playlist.id) }
                }
            } header: {
                Text(isEditable ? "Drag to reorder · swipe to remove" : "Read-only")
            }

            if playlist.trackIDsInOrder.isEmpty {
                Text("This playlist is empty.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(playlist.title ?? "(untitled)")
        .toolbar {
            if isEditable {
                ToolbarItem {
                    Button {
                        isAddingTracks = true
                    } label: {
                        Label("Add Tracks", systemImage: "plus.circle")
                    }
                }
            }
        }
    }

    private var isEditable: Bool { !playlist.isMaster && !playlist.isSmart }
}

/// Picks device tracks to append to a playlist. Tracks already in it are
/// shown but not selectable — adding a duplicate entry would list the track
/// twice on the device.
private struct AddTracksSheet: View {
    @Bindable var model: AppModel
    let playlist: Playlist

    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<UInt32> = []
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(matching, id: \.uniqueID) { track in
                    let alreadyIn = playlist.trackIDsInOrder.contains(track.uniqueID)
                    Button {
                        if chosen.contains(track.uniqueID) { chosen.remove(track.uniqueID) } else { chosen.insert(track.uniqueID) }
                    } label: {
                        HStack {
                            Image(systemName: alreadyIn ? "checkmark.circle" : (chosen.contains(track.uniqueID) ? "checkmark.circle.fill" : "circle"))
                                .foregroundStyle(alreadyIn ? Color.secondary : (chosen.contains(track.uniqueID) ? Color.accentColor : .secondary))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title ?? "Untitled")
                                Text(alreadyIn ? "Already in this playlist" : (track.artist ?? "Unknown Artist"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(alreadyIn)
                }
            }
            .searchable(text: $searchText, prompt: "Filter by title or artist")
            .navigationTitle("Add to “\(playlist.title ?? "")”")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(chosen.count)") {
                        let ids = Array(chosen)
                        dismiss()
                        Task { await model.addTracks(ids, toPlaylistID: playlist.id) }
                    }
                    .disabled(chosen.isEmpty)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 460)
    }

    private var matching: [Track] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = model.deviceTracks.sorted {
            ($0.artist ?? "", $0.title ?? "") < ($1.artist ?? "", $1.title ?? "")
        }
        guard !query.isEmpty else { return sorted }
        return sorted.filter {
            ($0.title ?? "").lowercased().contains(query) || ($0.artist ?? "").lowercased().contains(query)
        }
    }
}
