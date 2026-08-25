import Foundation
import Observation
import DAPDB
import DAPDevice
import DAPSync

/// Whether Tarantado can safely write to a device, and — if not — why, in
/// the engine's own words where possible.
public struct SyncSupport: Equatable, Sendable {
    public let isSupported: Bool
    public let reason: String?
}

/// Owns all mutable UI-facing state for the connect → scan → review → sync
/// flow.
///
/// State mutation always happens on the main actor (this type is
/// `@MainActor`-isolated), but every call into the engine
/// (`DAPVolume.validate`, `LibraryScanner.scan`, `SyncEngine.apply`, ...)
/// runs on a detached background task so it never blocks the UI. Progress
/// callbacks from those background tasks hop back to the main actor before
/// touching any published state.
///
/// Conforms to `@unchecked Sendable` so it can be captured by the
/// `@Sendable` closures those detached tasks require; every access to its
/// stored state is still only ever performed on the main actor, which is
/// what actually makes that safe.
@MainActor
@Observable
public final class AppModel: @unchecked Sendable {
    // MARK: - Device / connection

    public enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    public private(set) var connectionState: ConnectionState = .disconnected
    public private(set) var volume: DAPVolume?
    public private(set) var capacity: DAPVolume.Capacity?
    public private(set) var deviceTracks: [Track] = []
    public private(set) var devicePlaylists: [Playlist] = []
    public var devicePlaylistCount: Int { devicePlaylists.count }

    /// Playlists the user can actually edit: the master playlist is every
    /// track on the device and smart playlists are opaque rule blobs this
    /// library never rewrites, so neither is offered for editing.
    public var editablePlaylists: [Playlist] {
        devicePlaylists.filter { !$0.isMaster && !$0.isSmart }
    }

    public var isConnected: Bool { volume != nil }

    /// Whether the connected device is one Tarantado can safely write to.
    /// `nil` while nothing is connected.
    public var syncSupport: SyncSupport? {
        guard let volume else { return nil }
        return Self.evaluateSyncSupport(for: volume.model)
    }

    // MARK: - Source / scanning

    public enum ScanState: Equatable {
        case idle
        /// `nil` progress means the scan started but hasn't reported its
        /// first tick yet (enumeration is still walking the folder tree).
        case scanning(LibraryScanner.Progress?)
        case scanned
        case cancelled
        case failed(String)
    }

    public var sourceFolderURL: URL?
    public private(set) var scanState: ScanState = .idle
    public private(set) var sourceTracks: [SourceTrack] = []
    public var searchText: String = ""
    public var selectedFileURLs: Set<URL> = []

    private var scanTask: Task<Void, Never>?

    // MARK: - Local library

    /// The app-owned music folder. `nil` only if the container itself
    /// couldn't be created, which would be a broken install; the UI shows
    /// `localLibraryError` in that case rather than pretending the library
    /// is merely empty.
    public private(set) var localLibrary: LocalLibrary?
    public private(set) var localLibraryError: String?
    public private(set) var lastImportSummary: LocalLibrary.ImportSummary?
    /// True when `sourceFolderURL` points somewhere outside the app's own
    /// library — the macOS-only "scan a folder in place" option. It matters
    /// beyond display: an external folder's security scope dies with the
    /// picker, so its scan can't be silently reused later.
    public private(set) var isUsingExternalFolder = false
    public private(set) var isImporting = false

    public var localLibraryBytes: Int64 { localLibrary?.totalBytes() ?? 0 }

    // MARK: - Review / plan

    public private(set) var plan: SyncPlan?
    /// When on, tracks present on the device but missing from the scanned
    /// source are proposed for removal ("mirror" sync). Off by default,
    /// matching `SyncSelection`'s conservative default.
    public var mirrorSync: Bool = false

    // MARK: - Library editing (removal and playlists)

    /// Whether a library edit — a removal or a playlist mutation — is in
    /// flight, and what went wrong if one did. Separate from `syncState`
    /// because these are small, immediate operations rather than a
    /// long-running transfer with its own screen.
    public enum EditState: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    public private(set) var editState: EditState = .idle

    /// Device tracks ticked for removal on the Library screen.
    public var selectedDeviceTrackIDs: Set<UInt32> = []

    private var deviceTrackByID: [UInt32: Track] = [:]

    /// Looks up a device track by the ID a playlist entry refers to.
    /// Playlists store track IDs, so every playlist screen needs this to
    /// show anything but a number.
    public func deviceTrack(id: UInt32) -> Track? { deviceTrackByID[id] }

    public func dismissEditError() {
        if case .failed = editState { editState = .idle }
    }

    // MARK: - Sync

    public enum SyncState: Equatable {
        case idle
        case syncing(SyncProgress)
        case done(SyncReport)
        case failed(String)
    }

    public private(set) var syncState: SyncState = .idle
    private var syncTask: Task<Void, Never>?

    public init() {
        do {
            self.localLibrary = try LocalLibrary.makeDefault()
        } catch {
            self.localLibraryError = SyncEngine.describe(error)
        }
        useLocalLibrary()
    }

    /// Testing seam. Passing `nil` gives a model with no library at all,
    /// which is what most tests want: the default initializer resolves
    /// `.documentDirectory`, and outside an app container that is the user's
    /// real Documents folder — a test suite has no business creating
    /// anything there.
    init(localLibrary: LocalLibrary?) {
        self.localLibrary = localLibrary
        useLocalLibrary()
    }

    // MARK: - Local library

    /// Points scanning at the app's own library and rescans it. Cheap enough
    /// to call on launch: an empty library finishes immediately.
    public func useLocalLibrary() {
        guard let localLibrary else { return }
        isUsingExternalFolder = false
        sourceFolderURL = localLibrary.folderURL
        startScan()
    }

    /// Rescans the local library if it is what we are currently showing.
    ///
    /// Files can arrive in the library folder without the app doing anything:
    /// `UIFileSharingEnabled` puts the folder in the Files app, so music can
    /// be copied straight into the container — usually while this app is
    /// backgrounded or not running. Nothing notifies us when that happens, so
    /// without a rescan the tracks are on disk and invisible, and the obvious
    /// workaround (pointing "Add Folder" at the library) used to import the
    /// library into itself and show everything twice.
    ///
    /// Deliberately does nothing when the source is an external folder: that
    /// scan came from a security-scoped picker URL, and `useLocalLibrary()`
    /// would silently switch the source out from under the user. Also skips
    /// while a scan, import or sync is already in flight rather than
    /// restarting work that is nearly done.
    public func refreshLocalLibrary() {
        guard localLibrary != nil, !isUsingExternalFolder, !isImporting else { return }
        if case .scanning = scanState { return }
        if case .syncing = syncState { return }
        useLocalLibrary()
    }

    /// macOS only: scans a folder where it sits, without copying it into the
    /// library. Kept because syncing straight from an existing ~/Music tree
    /// is the natural thing to do on a Mac, and duplicating a large library
    /// into the container to achieve it would be absurd.
    public func useExternalFolder(_ url: URL) {
        isUsingExternalFolder = true
        sourceFolderURL = url
        startScan()
    }

    /// Copies picked files and folders into the library, then rescans so the
    /// new tracks appear. Import runs off the main actor: it is bulk file
    /// copying, and on a phone it can be hundreds of megabytes.
    public func importIntoLocalLibrary(_ urls: [URL]) async {
        guard let localLibrary, !urls.isEmpty else { return }
        isImporting = true
        lastImportSummary = nil

        let summary = await Task.detached(priority: .userInitiated) {
            do {
                return try localLibrary.importItems(from: urls)
            } catch {
                return LocalLibrary.ImportSummary(
                    failures: [LocalLibrary.ImportFailure(name: "Import", message: SyncEngine.describe(error))]
                )
            }
        }.value

        isImporting = false
        lastImportSummary = summary
        useLocalLibrary()
    }

    /// Deletes tracks from the app's library. This does not touch the DAP —
    /// tracks already synced stay on the device.
    public func removeFromLocalLibrary(_ urls: [URL]) async {
        guard let localLibrary, !urls.isEmpty else { return }
        let outcome = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try localLibrary.remove(urls)
                return nil
            } catch {
                return SyncEngine.describe(error)
            }
        }.value

        if let outcome {
            editState = .failed(outcome)
            return
        }
        selectedFileURLs.subtract(urls)
        useLocalLibrary()
    }

    public func dismissImportSummary() {
        lastImportSummary = nil
    }

    // MARK: - Sync-support rule

    /// Pure rule: refuse a device whose firmware checks a database
    /// signature this engine can't compute, and refuse a device we
    /// couldn't identify at all. Exposed as a static function (rather than
    /// baked only into instance state) so it's directly testable without a
    /// connected device.
    public nonisolated static func evaluateSyncSupport(for model: DeviceModel) -> SyncSupport {
        if model.isUnknown {
            return SyncSupport(
                isSupported: false,
                reason: "Tarantado doesn't recognize this DAP model (\(model.displayName)), so it can't safely write to it."
            )
        }
        if model.requiresDatabaseSignature != .none {
            return SyncSupport(
                isSupported: false,
                reason: model.requiresDatabaseSignature.refusalExplanation +
                    " Syncing is disabled to avoid corrupting its library."
            )
        }
        return SyncSupport(isSupported: true, reason: nil)
    }

    // MARK: - Connect

    /// Attempts to reconnect to whatever DAP was last connected, using a
    /// saved security-scoped bookmark. Best-effort only: any failure here
    /// (stale bookmark, remounted volume, revoked permission — all
    /// expected and common on iOS) falls back to `.disconnected` silently,
    /// never surfacing an error banner for it. Call once, near app launch.
    public func attemptAutoReconnect() async {
        guard connectionState == .disconnected, let data = BookmarkStore.load() else { return }
        guard let resolved = try? DAPVolume.resolveBookmark(data) else {
            BookmarkStore.clear()
            return
        }
        await connect(to: resolved.url)
        if case .failed = connectionState {
            connectionState = .disconnected
            BookmarkStore.clear()
        }
    }

    /// Validates and connects to the DAP volume at `pickedURL` (typically
    /// the result of a `.fileImporter(.folder)` picker). Wraps every touch
    /// of `pickedURL` in `DAPVolume.withAccess`, and persists a fresh
    /// bookmark on success as a best-effort convenience for next launch.
    public func connect(to pickedURL: URL) async {
        resetForNewConnection()
        connectionState = .connecting

        let outcome = await Self.runDetached {
            try DAPVolume.withAccess(to: pickedURL) { () throws -> DeviceSnapshot in
                let volume = try DAPVolume.validate(at: pickedURL)
                let snapshot = try DeviceSnapshot.load(for: volume)
                if let bookmarkData = try? DAPVolume.makeBookmark(for: pickedURL) {
                    BookmarkStore.save(bookmarkData)
                }
                return snapshot
            }
        }

        switch outcome {
        case .success(let snapshot):
            apply(snapshot)
            connectionState = .connected
        case .failure(let message):
            connectionState = .failed(message)
        }
    }

    /// Re-reads capacity and the device's database, without re-validating
    /// or re-picking the volume. Used to refresh the Device screen after a
    /// sync completes.
    public func refreshDeviceInfo() async {
        guard let volume else { return }
        let outcome = await Self.runDetached {
            try DAPVolume.withAccess(to: volume.rootURL) {
                try DeviceSnapshot.load(for: volume)
            }
        }
        if case .success(let snapshot) = outcome {
            apply(snapshot)
        }
    }

    #if DEBUG
    /// Screenshot support only. A synthetic volume lives inside the app's
    /// container, so the capacity read off it is the host disk's, not a
    /// plausible player's. Overrides it so App Store captures don't claim a
    /// 4 GB player has hundreds of gigabytes free. Never compiled into a
    /// release build.
    public func setCapacityForScreenshots(totalBytes: Int64, availableBytes: Int64) {
        capacity = DAPVolume.Capacity(totalBytes: totalBytes, availableBytes: availableBytes)
    }
    #endif

    public func disconnect() {
        volume = nil
        capacity = nil
        deviceTracks = []
        devicePlaylists = []
        deviceTrackByID = [:]
        selectedDeviceTrackIDs = []
        connectionState = .disconnected
        BookmarkStore.clear()
        resetForNewConnection()
    }

    private func resetForNewConnection() {
        syncTask?.cancel()
        plan = nil
        syncState = .idle

        // The local library belongs to the app, not to whichever DAP is
        // plugged in, so it survives a disconnect — losing a freshly
        // imported library because the cable was bumped would be maddening.
        // An external folder is different: its security scope died with the
        // picker, so the scan can't be trusted or repeated, and it goes.
        if isUsingExternalFolder {
            scanTask?.cancel()
            sourceTracks = []
            selectedFileURLs = []
            scanState = .idle
            sourceFolderURL = nil
            isUsingExternalFolder = false
            useLocalLibrary()
        }
    }

    private func apply(_ snapshot: DeviceSnapshot) {
        volume = snapshot.volume
        capacity = snapshot.capacity
        deviceTracks = snapshot.tracks
        devicePlaylists = snapshot.playlists
        deviceTrackByID = Dictionary(snapshot.tracks.map { ($0.uniqueID, $0) }, uniquingKeysWith: { first, _ in first })
        selectedDeviceTrackIDs.formIntersection(Set(snapshot.tracks.map(\.uniqueID)))
    }

    // MARK: - Scan

    /// Starts (or restarts) scanning `sourceFolderURL`. Cancels any scan
    /// already in flight first.
    public func startScan() {
        guard let folder = sourceFolderURL else { return }
        scanTask?.cancel()

        let model = volume?.model ?? .unknown
        scanState = .scanning(nil)

        scanTask = Task.detached(priority: .userInitiated) { [self] in
            do {
                // The folder comes from a document picker, so on a sandboxed
                // build it is security-scoped and unreadable until access is
                // started — and FileManager.enumerator reports that by
                // yielding nothing rather than by failing, so an unscoped
                // scan looks like a folder with no music in it. The scope has
                // to cover the whole scan, since AVAsset opens each file.
                let relay = LatestValueRelay<LibraryScanner.Progress> { [self] progress in
                    self.updateScanProgress(progress)
                }
                let tracks = try await DAPVolume.withAccess(to: folder) {
                    try await LibraryScanner.scan(sourceFolder: folder, model: model) { progress in
                        relay.send(progress)
                    }
                }
                await MainActor.run {
                    self.finishScan(with: tracks)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.scanState = .cancelled
                }
            } catch {
                let message = AppModel.friendlyMessage(for: error)
                await MainActor.run {
                    self.scanState = .failed(message)
                }
            }
        }
    }

    public func cancelScan() {
        scanTask?.cancel()
    }

    private func updateScanProgress(_ progress: LibraryScanner.Progress) {
        guard case .scanning = scanState else { return }
        scanState = .scanning(progress)
    }

    private func finishScan(with tracks: [SourceTrack]) {
        sourceTracks = tracks
        // Nothing is selected by default. Selecting the whole library was
        // convenient when a scan meant "the folder I just picked", but the
        // local library is a standing collection that is rescanned on every
        // launch and after every import — so select-all both proposes
        // resyncing everything and arms the destructive "Remove from
        // Library" button, neither of which the user asked for.
        // Selections that are still valid survive the rescan.
        selectedFileURLs.formIntersection(Set(tracks.map(\.fileURL)))
        scanState = .scanned
        plan = nil
        syncState = .idle
    }

    public func toggleSelection(for track: SourceTrack) {
        guard case .passThrough = track.compatibility else { return }
        if selectedFileURLs.contains(track.fileURL) {
            selectedFileURLs.remove(track.fileURL)
        } else {
            selectedFileURLs.insert(track.fileURL)
        }
    }

    /// Selects or deselects a whole group at once — every track by an
    /// artist, or on an album. Only playable tracks are ever selected;
    /// including the incompatible ones would put things in the plan that
    /// the engine will only skip again.
    public func setSelection(_ isSelected: Bool, for tracks: [SourceTrack]) {
        let urls = tracks.compactMap { track -> URL? in
            guard case .passThrough = track.compatibility else { return nil }
            return track.fileURL
        }
        if isSelected {
            selectedFileURLs.formUnion(urls)
        } else {
            selectedFileURLs.subtract(urls)
        }
    }

    /// True when every playable track in `tracks` is selected.
    public func isFullySelected(_ tracks: [SourceTrack]) -> Bool {
        let urls = tracks.compactMap { track -> URL? in
            guard case .passThrough = track.compatibility else { return nil }
            return track.fileURL
        }
        return !urls.isEmpty && urls.allSatisfy { selectedFileURLs.contains($0) }
    }

    // MARK: - Plan

    /// Recomputes the plan from the currently scanned/selected source
    /// tracks against the device's current tracks. Pure and synchronous —
    /// no I/O — safe to call as often as selection state changes.
    public func computePlan() {
        guard volume != nil else {
            plan = nil
            return
        }
        let selection = SyncSelection(includedSourceFileURLs: selectedFileURLs, removeMissing: mirrorSync)
        plan = SyncPlan.compute(deviceTracks: deviceTracks, sourceTracks: sourceTracks, selection: selection)
        syncState = .idle
    }

    // MARK: - Sync

    /// Applies the current plan to the connected device. No-ops if there's
    /// no volume, no plan, an empty plan, or the device is unsupported —
    /// the UI is expected to disable the Sync button in those cases, but
    /// this guards against it regardless.
    public func startSync() {
        guard let volume, let plan, !plan.isEmpty else { return }
        // The scan's security scope ended when the scan did, so the source
        // files are unreadable again by the time a sync runs. Both scopes
        // have to be held: the DAP to write to, and the source folder to
        // read from.
        let sourceFolder = sourceFolderURL
        guard Self.evaluateSyncSupport(for: volume.model).isSupported else {
            syncState = .failed("Syncing is unsupported for this device.")
            return
        }

        syncTask?.cancel()
        syncState = .syncing(SyncProgress(phase: .backingUp))

        syncTask = Task.detached(priority: .userInitiated) { [self] in
            do {
                let relay = LatestValueRelay<SyncProgress> { [self] progress in
                    self.updateSyncProgress(progress)
                }
                let report = try await DAPVolume.withAccess(to: volume.rootURL) {
                    try await DAPVolume.withAccess(to: sourceFolder ?? volume.rootURL) {
                        try await SyncEngine.apply(plan: plan, to: volume) { progress in
                            relay.send(progress)
                        }
                    }
                }
                await MainActor.run {
                    self.finishSync(with: report)
                }
                await self.refreshDeviceInfo()
            } catch {
                let message = AppModel.friendlyMessage(for: error)
                await MainActor.run {
                    self.syncState = .failed(message)
                }
            }
        }
    }

    public func cancelSync() {
        syncTask?.cancel()
    }

    /// Dismisses a finished sync's summary, returning to `.idle` so the
    /// Sync screen resets for the next run.
    public func acknowledgeSyncResult() {
        syncState = .idle
        plan = nil
    }

    private func updateSyncProgress(_ progress: SyncProgress) {
        guard case .syncing = syncState else { return }
        syncState = .syncing(progress)
    }

    private func finishSync(with report: SyncReport) {
        syncState = .done(report)
    }

    // MARK: - Library edits

    /// Runs a library edit off the main actor with both the device's
    /// security scope and a busy/failed state around it, then reloads the
    /// device so every screen reflects what actually landed on disk rather
    /// than what we hoped would.
    private func performEdit(_ description: String, _ body: @escaping @Sendable (DAPVolume) async throws -> Void) async {
        guard let volume else { return }
        editState = .working(description)

        let outcome = await Self.runDetachedAsync {
            try await DAPVolume.withAccess(to: volume.rootURL) {
                try await body(volume)
            }
        }

        switch outcome {
        case .success:
            editState = .idle
            await refreshDeviceInfo()
        case .failure(let message):
            editState = .failed(message)
        }
    }

    public func createPlaylist(title: String, trackIDs: [UInt32] = []) async {
        await performEdit("Creating “\(title)”") { volume in
            try PlaylistEditor(volume: volume).create(title: title, trackIDs: trackIDs)
        }
    }

    public func renamePlaylist(id: UInt64, to newTitle: String) async {
        await performEdit("Renaming to “\(newTitle)”") { volume in
            try PlaylistEditor(volume: volume).rename(id: id, to: newTitle)
        }
    }

    public func deletePlaylist(id: UInt64) async {
        await performEdit("Deleting playlist") { volume in
            try PlaylistEditor(volume: volume).delete(id: id)
        }
    }

    public func addTracks(_ trackIDs: [UInt32], toPlaylistID id: UInt64) async {
        await performEdit("Adding \(trackIDs.count) track(s)") { volume in
            try PlaylistEditor(volume: volume).addTracks(trackIDs, toPlaylistID: id)
        }
    }

    public func removeTracks(_ trackIDs: [UInt32], fromPlaylistID id: UInt64) async {
        await performEdit("Removing \(trackIDs.count) track(s)") { volume in
            try PlaylistEditor(volume: volume).removeTracks(trackIDs, fromPlaylistID: id)
        }
    }

    public func reorderPlaylist(id: UInt64, trackIDsInOrder newOrder: [UInt32]) async {
        await performEdit("Reordering") { volume in
            try PlaylistEditor(volume: volume).reorder(id: id, trackIDsInOrder: newOrder)
        }
    }

    /// Deletes tracks from the device outright — audio file, database entry,
    /// and every playlist entry referencing them. Irreversible: backups
    /// cover the database, not the audio.
    ///
    /// Goes through `SyncEngine.apply` rather than a second deletion path,
    /// so it inherits the backup, the cleanup and the AppleDouble sweep that
    /// the sync path already has.
    public func removeTracksFromDevice(_ trackIDs: [UInt32]) async {
        guard !trackIDs.isEmpty else { return }
        let ids = trackIDs
        await performEdit("Removing \(ids.count) track(s) from DAP") { volume in
            let data = try Data(contentsOf: volume.iTunesDBURL)
            let deviceTracks = try ITunesDatabase(parsing: data).tracks
            let (plan, unmatched) = SyncPlan.removing(trackIDs: ids, from: deviceTracks)
            guard unmatched.isEmpty else {
                throw RemovalError.unknownTrackIDs(unmatched)
            }
            _ = try await SyncEngine.apply(plan: plan, to: volume)
        }
        selectedDeviceTrackIDs = []
    }

    enum RemovalError: Error, LocalizedError {
        case unknownTrackIDs([UInt32])

        var errorDescription: String? {
            switch self {
            case .unknownTrackIDs(let ids):
                return "No track on this DAP has ID \(ids.map(String.init).joined(separator: ", "))."
            }
        }
    }

    // MARK: - Error formatting

    /// Surfaces an engine error's own `LocalizedError.errorDescription`
    /// verbatim wherever one is available (the engine's errors are already
    /// written to be descriptive and user-facing — see e.g.
    /// `DAPVolume.ValidationError` and `SyncEngineError`) rather than
    /// replacing it with a generic "something went wrong".
    nonisolated static func friendlyMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    /// Outcome of a `runDetached` call: `any Error` itself isn't
    /// `Sendable`, so failures are converted to a friendly `String` inside
    /// the detached task, before the result ever needs to cross back into
    /// an `@Sendable` context, rather than fighting that restriction.
    enum Outcome<T: Sendable>: Sendable {
        case success(T)
        case failure(String)
    }

    /// Runs a throwing, `@Sendable` operation on a detached background task.
    nonisolated private static func runDetached<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async -> Outcome<T> {
        await Task.detached(priority: .userInitiated) {
            do {
                return .success(try operation())
            } catch {
                return .failure(AppModel.friendlyMessage(for: error))
            }
        }.value
    }

    /// Async variant, for engine calls that are themselves async.
    nonisolated private static func runDetachedAsync<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async -> Outcome<T> {
        await Task.detached(priority: .userInitiated) {
            do {
                return .success(try await operation())
            } catch {
                return .failure(AppModel.friendlyMessage(for: error))
            }
        }.value
    }
}

/// Everything read from a connected device in one pass: capacity plus the
/// parsed database (if one exists yet).
struct DeviceSnapshot: Sendable {
    let volume: DAPVolume
    let capacity: DAPVolume.Capacity
    let tracks: [Track]
    let playlists: [Playlist]

    var playlistCount: Int { playlists.count }

    static func load(for volume: DAPVolume) throws -> DeviceSnapshot {
        let capacity = try volume.capacity()
        var tracks: [Track] = []
        var playlists: [Playlist] = []
        if FileManager.default.fileExists(atPath: volume.iTunesDBURL.path) {
            let data = try Data(contentsOf: volume.iTunesDBURL)
            let db = try ITunesDatabase(parsing: data)
            tracks = db.tracks
            playlists = db.playlists
        }
        return DeviceSnapshot(volume: volume, capacity: capacity, tracks: tracks, playlists: playlists)
    }
}
