import SwiftUI
import DAPSync
import UniformTypeIdentifiers

/// The app's own music library: what's staged on this iPhone, iPad or Mac,
/// ready to go to a DAP. Music is imported here first — copied into the
/// app's container — and only then selected for syncing.
///
/// The two-step shape exists because iOS gives no persistent view of the
/// filesystem: a document picker hands out a URL that stops being readable
/// once its scope ends, so the only way to have a library that is still
/// there tomorrow is to own the files. See `LocalLibrary`.
struct LocalLibraryView: View {
    @Bindable var model: AppModel
    @Binding var step: RootView.Step?

    // One picker, selected by state. Stacking three `.fileImporter`
    // modifiers on the same view does not give you three pickers: SwiftUI
    // honours only one of them, and the others' bindings flip to true and
    // present nothing at all — a tap that appears to do nothing whatsoever.
    @State private var activePicker: ImportPicker?
    @State private var isPickerPresented = false
    @State private var isConfirmingDelete = false
    @State private var grouping: TrackGrouping = .songs

    private enum ImportPicker {
        case songs
        case foldersToImport
        case externalFolder

        var contentTypes: [UTType] {
            switch self {
            case .songs: return ImportPicker.audioTypes
            case .foldersToImport, .externalFolder: return [.folder]
            }
        }

        var allowsMultipleSelection: Bool {
            switch self {
            case .songs, .foldersToImport: return true
            case .externalFolder: return false
            }
        }

        /// `.audio` alone greys out formats the system doesn't classify as
        /// audio — `.ogg` and `.opus` among them — so the scanner's own list
        /// of extensions is mapped to types and added.
        static let audioTypes: [UTType] = {
            var types: [UTType] = [.audio]
            for ext in LibraryScanner.candidateExtensions.sorted() {
                if let type = UTType(filenameExtension: ext), !types.contains(type) {
                    types.append(type)
                }
            }
            return types
        }()
    }

    private func present(_ picker: ImportPicker) {
        activePicker = picker
        isPickerPresented = true
    }

    var body: some View {
        Group {
            if let error = model.localLibraryError {
                ContentUnavailableView {
                    Label("Library unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else {
                // The summary sheet hangs off `content`, not off the same
                // view as the file importer below. A `.fileImporter` *is* a
                // sheet presentation, and two of those on one view collide
                // the same way three importers do.
                content
                    .sheet(item: importSummaryBinding) { summary in
                        ImportSummarySheet(summary: summary) { model.dismissImportSummary() }
                    }
            }
        }
        .navigationTitle(model.isUsingExternalFolder ? externalFolderName : "Local Library")
        .toolbar { toolbarContent }
        .fileImporter(
            isPresented: $isPickerPresented,
            allowedContentTypes: activePicker?.contentTypes ?? ImportPicker.audioTypes,
            allowsMultipleSelection: activePicker?.allowsMultipleSelection ?? true
        ) { result in
            let picker = activePicker
            activePicker = nil
            guard case .success(let urls) = result, !urls.isEmpty else { return }

            switch picker {
            case .songs, .foldersToImport:
                Task { await model.importIntoLocalLibrary(urls) }
            case .externalFolder:
                model.useExternalFolder(urls[0])
            case nil:
                break
            }
        }
        .confirmationDialog(
            "Remove \(model.selectedFileURLs.count) track\(model.selectedFileURLs.count == 1 ? "" : "s") from this device's library?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                let urls = Array(model.selectedFileURLs)
                Task { await model.removeFromLocalLibrary(urls) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The files are deleted from Tarantado's library. Anything already copied to a DAP stays on the DAP.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isImporting {
            VStack(spacing: 12) {
                ProgressView("Importing music…")
                Text("Copying files into Tarantado's library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        } else {
            switch model.scanState {
            case .scanning(let progress):
                scanningState(progress)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't read the library", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { model.startScan() }
                }
            case _ where model.sourceTracks.isEmpty:
                emptyState
            default:
                trackList
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if case .scanning = model.scanState {
            ToolbarItem {
                Button("Cancel") { model.cancelScan() }
            }
        }
        ToolbarItem {
            Menu {
                Button("Add Songs…", systemImage: "music.note") { present(.songs) }
                Button("Add Folder…", systemImage: "folder") { present(.foldersToImport) }
                #if os(macOS)
                Divider()
                // On a Mac the user already has a music library on disk;
                // copying it into the container to sync from it would double
                // the storage for no benefit.
                Button("Sync From a Folder Instead…", systemImage: "externaldrive") {
                    present(.externalFolder)
                }
                if model.isUsingExternalFolder {
                    Button("Back to Local Library", systemImage: "arrow.uturn.backward") {
                        model.useLocalLibrary()
                    }
                }
                #endif
            } label: {
                Label("Add Music", systemImage: "plus")
            }
            .disabled(model.isImporting)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(model.isUsingExternalFolder ? "No audio files found" : "Library is empty", systemImage: "music.note.list")
        } description: {
            Text(emptyDescription)
        } actions: {
            Button("Add Songs…") { present(.songs) }
            Button("Add Folder…") { present(.foldersToImport) }
        }
    }

    private var emptyDescription: String {
        if model.isUsingExternalFolder {
            return "\(externalFolderName) contains no files Tarantado recognizes as audio. It looks for \(LibraryScanner.candidateExtensions.sorted().joined(separator: ", ")) anywhere inside, including subfolders."
        }
        return "Add music here first, then choose what to copy to your DAP. Files are stored inside Tarantado, so they stay available whether or not a DAP is plugged in — and you can also drag music into Tarantado's folder from the Files app."
    }

    private func scanningState(_ progress: LibraryScanner.Progress?) -> some View {
        VStack(spacing: 12) {
            if let progress, progress.filesDiscovered > 0 {
                ProgressView(value: Double(progress.filesProcessed), total: Double(progress.filesDiscovered)) {
                    Text("Reading \(progress.filesProcessed) of \(progress.filesDiscovered)")
                }
                if let name = progress.currentFileName {
                    Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                ProgressView("Looking for audio files…")
            }
        }
        .padding()
        .frame(maxWidth: 420)
    }

    private var trackList: some View {
        List {
            if !compatible.isEmpty {
                switch grouping {
                case .songs:
                    Section {
                        ForEach(compatible) { track in
                            trackRow(track)
                        }
                    } header: {
                        selectionHeader
                    }
                case .artists, .albums:
                    ForEach(groups, id: \.name) { group in
                        Section {
                            ForEach(group.tracks) { track in
                                trackRow(track)
                            }
                        } header: {
                            groupHeader(group)
                        }
                    }
                }
            }

            if !skipped.isEmpty {
                Section("Can't be played by this DAP (\(skipped.count))") {
                    ForEach(skipped) { track in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.fileURL.lastPathComponent)
                            if case .unsupported(let reason) = track.compatibility {
                                Text(reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $model.searchText, prompt: "Filter by title or artist")
        .safeAreaInset(edge: .top) {
            TrackGroupingPicker(grouping: $grouping)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                // Deleting from the app's own library is only meaningful for
                // files the app owns; an external folder is the user's, and
                // syncing from it must never delete it.
                if !model.isUsingExternalFolder {
                    Button("Remove from Library", role: .destructive) {
                        isConfirmingDelete = true
                    }
                    .disabled(model.selectedFileURLs.isEmpty)
                }
                Spacer()
                Button(syncButtonTitle) {
                    model.computePlan()
                    step = .review
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedFileURLs.isEmpty || !model.isConnected)
            }
            .padding()
            .background(.bar)
        }
    }

    private var syncButtonTitle: String {
        let count = model.selectedFileURLs.count
        return count == 1 ? "Sync 1 Track" : "Sync \(count) Tracks"
    }

    private func trackRow(_ track: SourceTrack) -> some View {
        Button {
            model.toggleSelection(for: track)
        } label: {
            HStack {
                Image(systemName: model.selectedFileURLs.contains(track.fileURL) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.selectedFileURLs.contains(track.fileURL) ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                    Text(secondaryLabel(for: track))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Formatting.duration(ms: track.durationMS))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Inside an artist or album section, repeating the thing you grouped by
    /// on every row is noise — show the other one.
    private func secondaryLabel(for track: SourceTrack) -> String {
        switch grouping {
        case .songs: return track.artist ?? "Unknown Artist"
        case .artists: return track.album ?? "Unknown Album"
        case .albums: return track.artist ?? "Unknown Artist"
        }
    }

    private var selectionHeader: some View {
        HStack {
            Text("\(model.selectedFileURLs.count) of \(compatible.count) selected")
            Spacer()
            selectAllButton(for: compatible)
            if !model.isUsingExternalFolder {
                Text(Formatting.bytes(model.localLibraryBytes))
            }
        }
    }

    private func groupHeader(_ group: TrackGroup) -> some View {
        HStack {
            Text(group.name)
            Spacer()
            selectAllButton(for: group.tracks)
        }
    }

    private func selectAllButton(for tracks: [SourceTrack]) -> some View {
        let isFullySelected = model.isFullySelected(tracks)
        return SelectAllButton(isFullySelected: isFullySelected) {
            model.setSelection(!isFullySelected, for: tracks)
        }
    }

    // MARK: - Grouping

    struct TrackGroup {
        let name: String
        let tracks: [SourceTrack]
    }

    private var groups: [TrackGroup] {
        let keyed = Dictionary(grouping: compatible) { track in
            grouping.sectionName(artist: track.artist, albumArtist: track.albumArtist, album: track.album)
        }
        return keyed
            .map { TrackGroup(name: $0.key, tracks: $0.value.sorted { lhs, rhs in
                if lhs.discNumber != rhs.discNumber { return (lhs.discNumber ?? 0) < (rhs.discNumber ?? 0) }
                if lhs.trackNumber != rhs.trackNumber { return (lhs.trackNumber ?? 0) < (rhs.trackNumber ?? 0) }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var externalFolderName: String {
        model.sourceFolderURL?.lastPathComponent ?? "Folder"
    }

    /// `.sheet(item:)` needs an `Identifiable` optional; the summary is
    /// value data, so it gets its identity from the model's ownership of it.
    private var importSummaryBinding: Binding<IdentifiedImportSummary?> {
        Binding(
            get: { model.lastImportSummary.map(IdentifiedImportSummary.init) },
            set: { if $0 == nil { model.dismissImportSummary() } }
        )
    }

    // MARK: - Filtering

    private var matching: [SourceTrack] {
        let query = model.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.sourceTracks }
        return model.sourceTracks.filter {
            $0.title.lowercased().contains(query) || ($0.artist ?? "").lowercased().contains(query)
        }
    }

    private var compatible: [SourceTrack] {
        matching.filter { if case .passThrough = $0.compatibility { return true } else { return false } }
    }

    private var skipped: [SourceTrack] {
        matching.filter { if case .unsupported = $0.compatibility { return true } else { return false } }
    }
}

struct IdentifiedImportSummary: Identifiable {
    let id = UUID()
    let summary: LocalLibrary.ImportSummary

    init(_ summary: LocalLibrary.ImportSummary) {
        self.summary = summary
    }
}

/// Shown after an import so silent skips and failures can't hide. An import
/// that copied nothing because every file was already there looks identical
/// to one that failed, unless it says which happened.
struct ImportSummarySheet: View {
    let summary: IdentifiedImportSummary
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Added", value: "\(summary.summary.imported.count)")
                    if !summary.summary.skipped.isEmpty {
                        LabeledContent("Already in library", value: "\(summary.summary.skipped.count)")
                    }
                }
                if !summary.summary.failures.isEmpty {
                    Section("Couldn't be imported (\(summary.summary.failures.count))") {
                        ForEach(summary.summary.failures, id: \.name) { failure in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(failure.name)
                                Text(failure.message).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Import Finished")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
    }
}
