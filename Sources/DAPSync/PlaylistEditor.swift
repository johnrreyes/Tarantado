import Foundation
import DAPDB
import DAPDevice

/// What can go wrong editing a device's playlists, on top of the structural
/// errors `ITunesDatabase.PlaylistEditError` already raises.
public enum PlaylistEditorError: Error, LocalizedError, Equatable {
    /// Same policy as `SyncEngineError.databaseSignatureRequired`: refuse to
    /// write an unsigned database to firmware that checks one.
    case databaseSignatureRequired(DatabaseSignatureRequirement)
    /// There is no `iTunesDB` on the device to edit.
    case noDatabaseOnDevice
    /// A track ID given to `addTracks` isn't on the device at all, so adding
    /// it would create a playlist entry pointing at nothing.
    case unknownTrackIDs([UInt32])
    case playlistNotFound(String)
    /// We have not verified which `mhsd` section this model's firmware
    /// builds its Playlists menu from, so a new playlist could be filed
    /// where the device never shows it. Refuse instead of guessing — see
    /// `DeviceModel.playlistSectionType`.
    case playlistSectionUnknown(modelName: String)
    /// Two or more playlists share the given title, so a name can't identify
    /// one — the caller should pass a persistent ID instead.
    case ambiguousPlaylistName(String, matchingIDs: [UInt64])

    public var errorDescription: String? {
        switch self {
        case .databaseSignatureRequired(let requirement):
            return requirement.refusalExplanation +
                " Refusing to write an unsigned database rather than risk corrupting the device's library."
        case .noDatabaseOnDevice:
            return "There is no iTunesDB on this device to edit."
        case .unknownTrackIDs(let ids):
            let list = ids.map(String.init).joined(separator: ", ")
            return "No track on this device has ID \(list)."
        case .playlistSectionUnknown(let modelName):
            return "Tarantado has not verified which playlist section \(modelName) firmware reads, so it can't create a playlist this device is guaranteed to show. " +
                "Pass an explicit section to override."
        case .playlistNotFound(let name):
            return "No playlist named (or with ID) \"\(name)\" on this device."
        case .ambiguousPlaylistName(let name, let ids):
            let list = ids.map(String.init).joined(separator: ", ")
            return "More than one playlist is named \"\(name)\" (IDs \(list)); identify it by ID instead."
        }
    }
}

/// Playlist editing against a real device, wrapping `ITunesDatabase`'s
/// playlist mutations in the same safety envelope `SyncEngine.apply` uses for
/// tracks: refuse signed-database models, back up before touching anything,
/// mutate in memory, and write the database back exactly once at the end.
///
/// Track *removal* deliberately does not live here — deleting a track means
/// deleting its audio file too, which `SyncEngine.apply` already does (along
/// with rollback and progress reporting) via a plan whose `toRemove` is
/// populated. See `SyncPlan.removing(_:from:)`.
public struct PlaylistEditor: Sendable {
    public let volume: DAPVolume

    public init(volume: DAPVolume) {
        self.volume = volume
    }

    /// The backup taken before a mutation, so callers can tell the user
    /// where the previous database went. `nil` only when there was nothing
    /// on the device to back up.
    public typealias Backup = BackupManager.Backup

    // MARK: - Reading

    public func database() throws -> ITunesDatabase {
        guard FileManager.default.fileExists(atPath: volume.iTunesDBURL.path) else {
            throw PlaylistEditorError.noDatabaseOnDevice
        }
        return try ITunesDatabase(parsing: Data(contentsOf: volume.iTunesDBURL))
    }

    /// Resolves a user-supplied playlist reference — either a persistent ID
    /// in decimal form, or an exact title — to a single playlist.
    public func resolve(_ reference: String, in db: ITunesDatabase) throws -> Playlist {
        if let id = UInt64(reference), let match = db.playlists.first(where: { $0.id == id }) {
            return match
        }
        let byTitle = db.playlists.filter { $0.title == reference }
        // Count distinct persistent IDs, not matching rows. `db.playlists`
        // flattens every mhsd section, and the firmware mirrors each
        // playlist across two of them — so one playlist legitimately appears
        // twice under a single ID. Counting rows reported that as ambiguous
        // ("matchingIDs: [X, X]") and made every playlist on a device the
        // Apple firmware had touched unreachable by name. Two *different*
        // IDs sharing a title is the real ambiguity.
        let distinctIDs = Set(byTitle.map(\.id))
        switch distinctIDs.count {
        case 0: throw PlaylistEditorError.playlistNotFound(reference)
        case 1: return byTitle[0]
        default: throw PlaylistEditorError.ambiguousPlaylistName(reference, matchingIDs: distinctIDs.sorted())
        }
    }

    // MARK: - Writing

    /// Creates a playlist titled `title`, optionally populated with
    /// `trackIDs` in the order given, and returns its new persistent ID.
    ///
    /// `sectionType` picks which `mhsd` section the playlist is filed
    /// under. When `nil` it comes from `DeviceModel.playlistSectionType`,
    /// which is a hardware-verified fact per model rather than something
    /// inferred from the database — and when that is also `nil`, this
    /// throws rather than guessing. Pass it explicitly only to override,
    /// e.g. to determine the right section for a new model.
    @discardableResult
    public func create(title: String, trackIDs: [UInt32] = [], sectionType: UInt32? = nil) throws -> (id: UInt64, backup: Backup?) {
        // Whether we may write to this device at all outranks where the
        // playlist would go, so check that first — otherwise a signed-database
        // model reports an unverified-section error and hides the real reason.
        try guardWritable()
        guard let section = sectionType ?? volume.model.playlistSectionType else {
            throw PlaylistEditorError.playlistSectionUnknown(modelName: volume.model.displayName)
        }

        var newID: UInt64 = 0
        let backup = try mutate { db in
            try Self.validate(trackIDs: trackIDs, in: db)
            newID = try db.addPlaylist(title: title, inSectionType: section)
            try Self.append(trackIDs, toPlaylistID: newID, in: &db)
        }
        return (newID, backup)
    }

    @discardableResult
    public func delete(id: UInt64) throws -> Backup? {
        try mutate { db in try db.removePlaylist(id: id) }
    }

    @discardableResult
    public func rename(id: UInt64, to newTitle: String) throws -> Backup? {
        try mutate { db in try db.renamePlaylist(id: id, to: newTitle) }
    }

    /// Appends `trackIDs` to the playlist, skipping any that are already in
    /// it (the firmware shows a track once per entry, so adding a duplicate
    /// entry would list it twice).
    @discardableResult
    public func addTracks(_ trackIDs: [UInt32], toPlaylistID id: UInt64) throws -> Backup? {
        try mutate { db in
            guard let playlist = db.playlists.first(where: { $0.id == id }) else {
                throw ITunesDatabase.PlaylistEditError.playlistNotFound(id)
            }
            // Which playlist this is decides the answer regardless of what
            // the track IDs are, so check that first — otherwise adding to
            // the master playlist reports a confusing "no such track".
            guard !playlist.isMaster else { throw ITunesDatabase.PlaylistEditError.cannotModifyMasterPlaylist(id) }
            guard !playlist.isSmart else { throw ITunesDatabase.PlaylistEditError.cannotModifySmartPlaylist(id) }
            try Self.validate(trackIDs: trackIDs, in: db)

            let existing = Set(playlist.trackIDsInOrder)
            try Self.append(trackIDs.filter { !existing.contains($0) }, toPlaylistID: id, in: &db)
        }
    }

    @discardableResult
    public func removeTracks(_ trackIDs: [UInt32], fromPlaylistID id: UInt64) throws -> Backup? {
        try mutate { db in
            guard let playlist = db.playlists.first(where: { $0.id == id }) else {
                throw ITunesDatabase.PlaylistEditError.playlistNotFound(id)
            }
            guard !playlist.isMaster else { throw ITunesDatabase.PlaylistEditError.cannotModifyMasterPlaylist(id) }
            guard !playlist.isSmart else { throw ITunesDatabase.PlaylistEditError.cannotModifySmartPlaylist(id) }

            for trackID in trackIDs {
                try db.removePlaylistEntry(trackID: trackID, fromPlaylistID: id)
            }
            try Self.renumber(playlistID: id, in: &db)
        }
    }

    @discardableResult
    public func reorder(id: UInt64, trackIDsInOrder newOrder: [UInt32]) throws -> Backup? {
        try mutate { db in try db.reorderPlaylist(id: id, trackIDsInOrder: newOrder) }
    }

    // MARK: - Helpers

    /// Backs up, parses, applies `body`, and writes the database back once.
    /// If `body` throws, nothing is written — the device keeps the database
    /// it already had.
    /// The one policy gate every write shares: refuse firmware that checks a
    /// database signature we cannot compute.
    private func guardWritable() throws {
        guard volume.model.requiresDatabaseSignature == .none else {
            throw PlaylistEditorError.databaseSignatureRequired(volume.model.requiresDatabaseSignature)
        }
    }

    private func mutate(_ body: (inout ITunesDatabase) throws -> Void) throws -> Backup? {
        try guardWritable()

        var db = try database()

        var backup: Backup?
        do {
            backup = try BackupManager(volume: volume).createBackup()
        } catch BackupManager.BackupError.nothingToBackUp {
            // Nothing on the device yet to protect; proceed without a backup.
        }

        try body(&db)
        try BackupManager.atomicWrite(db.serialized(), to: volume.iTunesDBURL, forceFallback: false)
        return backup
    }

    private static func validate(trackIDs: [UInt32], in db: ITunesDatabase) throws {
        let known = Set(db.tracks.map(\.uniqueID))
        let unknown = trackIDs.filter { !known.contains($0) }
        guard unknown.isEmpty else { throw PlaylistEditorError.unknownTrackIDs(unknown) }
    }

    /// Appends entries for `trackIDs` after whatever the playlist already
    /// holds, numbering positions on from its current count.
    private static func append(_ trackIDs: [UInt32], toPlaylistID id: UInt64, in db: inout ITunesDatabase) throws {
        guard !trackIDs.isEmpty else { return }
        var position = UInt32(db.playlists.first { $0.id == id }?.trackIDsInOrder.count ?? 0)
        for trackID in trackIDs {
            try db.addPlaylistEntry(MHIP.make(trackID: trackID, position: position), toPlaylistID: id)
            position += 1
        }
    }

    /// Rewrites a playlist's entry positions to 0..<n in their current
    /// order, closing the gaps a removal leaves behind. Order is carried by
    /// each entry's position mhod, so gaps are harmless to playback — this
    /// just keeps what we write looking like what iTunes would have written.
    private static func renumber(playlistID id: UInt64, in db: inout ITunesDatabase) throws {
        guard let playlist = db.playlists.first(where: { $0.id == id }) else { return }
        try db.reorderPlaylist(id: id, trackIDsInOrder: playlist.trackIDsInOrder)
    }
}
