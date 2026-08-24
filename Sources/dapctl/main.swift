import Foundation
import DAPDB
import DAPDevice
import DAPSync

// A hand-rolled, dependency-free CLI harness for validating DAPSync
// against real hardware before any UI exists. macOS only.
//
//   dapctl info  <volume>
//   dapctl list  <volume>
//   dapctl scan  <source-folder>
//   dapctl plan  <volume> <source> [--limit N]
//   dapctl sync  <volume> <source> [--limit N] [--yes]
//   dapctl remove <volume> <trackID>... [--yes]
//   dapctl playlists <volume>
//   dapctl playlist <show|create|rename|delete|add|rm|reorder> ...

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func formatDuration(ms: Int) -> String {
    let totalSeconds = ms / 1000
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return String(format: "%d:%02d", minutes, seconds)
}

func parseFlags(_ args: [String]) -> (positional: [String], limit: Int?, yes: Bool, section: UInt32?) {
    var positional: [String] = []
    var limit: Int?
    var yes = false
    var section: UInt32?
    var i = 0
    while i < args.count {
        let arg = args[i]
        if arg == "--section" {
            i += 1
            guard i < args.count, let n = UInt32(args[i]) else { fail("--section requires an mhsd section type") }
            section = n
        } else if arg.hasPrefix("--section=") {
            guard let n = UInt32(arg.dropFirst("--section=".count)) else { fail("--section requires an mhsd section type") }
            section = n
        } else if arg == "--limit" {
            i += 1
            guard i < args.count, let n = Int(args[i]) else { fail("--limit requires a number") }
            limit = n
        } else if arg.hasPrefix("--limit=") {
            guard let n = Int(arg.dropFirst("--limit=".count)) else { fail("--limit requires a number") }
            limit = n
        } else if arg == "--yes" {
            yes = true
        } else {
            positional.append(arg)
        }
        i += 1
    }
    return (positional, limit, yes, section)
}

func openVolume(_ path: String) throws -> DAPVolume {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    return try DAPVolume.validate(at: url)
}

func printInfo(_ volume: DAPVolume) throws {
    print("Model:            \(volume.model.displayName) (\(volume.model.generation))")
    print("Serial:           \(volume.sysInfo.serialNumber ?? "unknown")")
    print("Signature req.:   \(volume.model.requiresDatabaseSignature)")
    print("Music folders:    \(volume.model.musicFolderCount)")
    print("Supports artwork: \(volume.model.supportsArtwork)")
    let capacity = try volume.capacity()
    print("Capacity:         \(formatBytes(capacity.availableBytes)) available of \(formatBytes(capacity.totalBytes))")

    if FileManager.default.fileExists(atPath: volume.iTunesDBURL.path) {
        let data = try Data(contentsOf: volume.iTunesDBURL)
        let db = try ITunesDatabase(parsing: data)
        print("Tracks:           \(db.tracks.count)")
        print("Playlists:        \(db.playlists.count)")
    } else {
        print("Tracks:           (no iTunesDB on device yet)")
    }
}

func printList(_ volume: DAPVolume) throws {
    guard FileManager.default.fileExists(atPath: volume.iTunesDBURL.path) else {
        fail("No iTunesDB found at \(volume.iTunesDBURL.path)")
    }
    let data = try Data(contentsOf: volume.iTunesDBURL)
    let db = try ITunesDatabase(parsing: data)
    for track in db.tracks.sorted(by: { ($0.artist ?? "", $0.album ?? "", $0.trackNumber) < ($1.artist ?? "", $1.album ?? "", $1.trackNumber) }) {
        let artist = track.artist ?? "Unknown Artist"
        let title = track.title ?? "Untitled"
        let duration = formatDuration(ms: Int(track.length))
        print("[\(track.uniqueID)] \(artist) - \(title)  (\(duration), \(formatBytes(Int64(track.size))))")
    }
    print("\n\(db.tracks.count) track(s)")
}

func printScan(_ sourceFolder: URL, model: DeviceModel) async throws {
    print("Scanning \(sourceFolder.path) ...")
    let tracks = try await LibraryScanner.scan(sourceFolder: sourceFolder, model: model) { progress in
        if let name = progress.currentFileName {
            FileHandle.standardError.write(Data("  [\(progress.filesProcessed)/\(progress.filesDiscovered)] \(name)\n".utf8))
        }
    }

    var compatibleCount = 0
    for track in tracks.sorted(by: { $0.fileURL.path < $1.fileURL.path }) {
        switch track.compatibility {
        case .passThrough(let format):
            compatibleCount += 1
            print("OK    [\(format.kind.rawValue)] \(track.artist ?? "?") - \(track.title)  (\(formatDuration(ms: track.durationMS)), \(formatBytes(track.fileSize)))  <- \(track.fileURL.lastPathComponent)")
        case .unsupported(let reason):
            print("SKIP  \(track.fileURL.lastPathComponent): \(reason)")
        }
    }
    print("\n\(tracks.count) file(s) found, \(compatibleCount) compatible, \(tracks.count - compatibleCount) skipped")
}

func buildPlan(volume: DAPVolume, sourceFolder: URL, limit: Int?) async throws -> SyncPlan {
    let sourceTracks = try await LibraryScanner.scan(sourceFolder: sourceFolder, model: volume.model)

    var deviceTracks: [Track] = []
    if FileManager.default.fileExists(atPath: volume.iTunesDBURL.path) {
        let data = try Data(contentsOf: volume.iTunesDBURL)
        deviceTracks = try ITunesDatabase(parsing: data).tracks
    }

    var selection = SyncSelection()
    if let limit {
        let compatible = sourceTracks
            .sorted { $0.fileURL.path < $1.fileURL.path }
            .filter { if case .passThrough = $0.compatibility { return true } else { return false } }
        let included = compatible.prefix(limit).map(\.fileURL)
        selection.includedSourceFileURLs = Set(included)
    }

    return SyncPlan.compute(deviceTracks: deviceTracks, sourceTracks: sourceTracks, selection: selection)
}

func printPlan(_ plan: SyncPlan) {
    print("To add (\(plan.toAdd.count)):")
    for item in plan.toAdd {
        print("  + \(item.source.artist ?? "?") - \(item.source.title)  (\(formatBytes(item.source.fileSize)))  <- \(item.source.fileURL.lastPathComponent)")
    }
    print("\nTo remove (\(plan.toRemove.count)):")
    for item in plan.toRemove {
        print("  - [\(item.deviceTrack.uniqueID)] \(item.deviceTrack.artist ?? "?") - \(item.deviceTrack.title ?? "?")")
    }
    if !plan.skipped.isEmpty {
        print("\nSkipped (\(plan.skipped.count), incompatible):")
        for item in plan.skipped {
            print("  ! \(item.source.fileURL.lastPathComponent): \(item.reason)")
        }
    }
    print("\nUnchanged: \(plan.unchanged.count)")
    print("Bytes required: \(formatBytes(plan.bytesRequired))")
    print("Bytes freed:    \(formatBytes(plan.bytesFreed))")
}

func promptYesNo(_ question: String) -> Bool {
    print("\(question) [y/N] ", terminator: "")
    guard let line = readLine() else { return false }
    let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
    return trimmed == "y" || trimmed == "yes"
}

func runInfo(_ args: [String]) throws {
    let (positional, _, _, _) = parseFlags(args)
    guard positional.count == 1 else { fail("usage: dapctl info <volume>") }
    let volume = try openVolume(positional[0])
    try printInfo(volume)
}

func runList(_ args: [String]) throws {
    let (positional, _, _, _) = parseFlags(args)
    guard positional.count == 1 else { fail("usage: dapctl list <volume>") }
    let volume = try openVolume(positional[0])
    try printList(volume)
}

func runScan(_ args: [String]) async throws {
    let (positional, _, _, _) = parseFlags(args)
    guard positional.count == 1 else { fail("usage: dapctl scan <source-folder>") }
    let sourceFolder = URL(fileURLWithPath: positional[0], isDirectory: true)
    try await printScan(sourceFolder, model: .unknown)
}

func runPlan(_ args: [String]) async throws {
    let (positional, limit, _, _) = parseFlags(args)
    guard positional.count == 2 else { fail("usage: dapctl plan <volume> <source> [--limit N]") }
    let volume = try openVolume(positional[0])
    let sourceFolder = URL(fileURLWithPath: positional[1], isDirectory: true)
    let plan = try await buildPlan(volume: volume, sourceFolder: sourceFolder, limit: limit)
    printPlan(plan)
}

func runSync(_ args: [String]) async throws {
    let (positional, limit, yes, _) = parseFlags(args)
    guard positional.count == 2 else { fail("usage: dapctl sync <volume> <source> [--limit N] [--yes]") }
    let volume = try openVolume(positional[0])
    let sourceFolder = URL(fileURLWithPath: positional[1], isDirectory: true)

    print("Device: \(volume.model.displayName) at \(volume.rootURL.path)")
    let plan = try await buildPlan(volume: volume, sourceFolder: sourceFolder, limit: limit)
    printPlan(plan)

    if plan.isEmpty {
        print("\nNothing to do.")
        return
    }

    let backupsDirectory = BackupManager(volume: volume).backupsDirectory
    print("\nA backup of the current database will be written to:\n  \(backupsDirectory.path)")

    if !yes {
        guard promptYesNo("\nProceed with this sync?") else {
            print("Aborted.")
            return
        }
    }

    let report = try await SyncEngine.apply(plan: plan, to: volume) { progress in
        switch progress.phase {
        case .backingUp:
            FileHandle.standardError.write(Data("Backing up database...\n".utf8))
        case .parsingDatabase:
            FileHandle.standardError.write(Data("Parsing database...\n".utf8))
        case .copying(let index, let total):
            let name = progress.currentFile ?? ""
            FileHandle.standardError.write(Data("Copying [\(index + 1)/\(total)] \(name) (\(formatBytes(progress.bytesCopied))/\(formatBytes(progress.bytesTotal)))\n".utf8))
        case .removing(let index, let total):
            let name = progress.currentFile ?? ""
            FileHandle.standardError.write(Data("Removing [\(index + 1)/\(total)] \(name)\n".utf8))
        case .writingDatabase:
            FileHandle.standardError.write(Data("Writing database...\n".utf8))
        }
    }

    print("\nAdded:   \(report.added.count)")
    print("Removed: \(report.removed.count)")
    if let backup = report.backup {
        print("Backup:  \(backup.directoryURL.path)")
    }
    if !report.failures.isEmpty {
        print("\nFailures (\(report.failures.count)):")
        for failure in report.failures {
            print("  ! \(failure.sourceFileURL?.lastPathComponent ?? "<removal>"): \(failure.message)")
        }
    }
    if report.cancelled {
        print("\nSync was cancelled.")
    }

    if !report.failures.isEmpty {
        exit(1)
    }
}


// MARK: - Track removal

func printTrackTable(_ tracks: [Track]) {
    for track in tracks {
        let artist = track.artist ?? "Unknown Artist"
        let title = track.title ?? "Untitled"
        print("  [\(track.uniqueID)] \(artist) - \(title)  (\(formatBytes(Int64(track.size))))")
    }
}

func runRemove(_ args: [String]) async throws {
    let (positional, _, yes, _) = parseFlags(args)
    guard positional.count >= 2 else { fail("usage: dapctl remove <volume> <trackID>... [--yes]") }
    let volume = try openVolume(positional[0])

    let trackIDs = try positional.dropFirst().map { arg -> UInt32 in
        guard let id = UInt32(arg) else { throw CLIError("\"\(arg)\" is not a track ID; run `dapctl list` to see them") }
        return id
    }

    let deviceTracks = try ITunesDatabase(parsing: Data(contentsOf: volume.iTunesDBURL)).tracks
    let (plan, unmatched) = SyncPlan.removing(trackIDs: trackIDs, from: deviceTracks)
    guard unmatched.isEmpty else {
        fail("no track on this device has ID \(unmatched.map(String.init).joined(separator: ", "))")
    }

    print("Device: \(volume.model.displayName) at \(volume.rootURL.path)")
    print("\nWill delete \(plan.toRemove.count) track(s) — audio file and database entry:")
    printTrackTable(plan.toRemove.map(\.deviceTrack))
    print("\nFrees: \(formatBytes(plan.bytesFreed))")
    print("Remaining after removal: \(plan.unchanged.count) track(s)")

    let backupsDirectory = BackupManager(volume: volume).backupsDirectory
    print("\nA backup of the current database will be written to:\n  \(backupsDirectory.path)")
    print("Note: the backup covers the database only, not the audio files — deleting those is irreversible.")

    if !yes {
        guard promptYesNo("\nProceed?") else {
            print("Aborted.")
            return
        }
    }

    let report = try await SyncEngine.apply(plan: plan, to: volume) { progress in
        if case .removing(let index, let total) = progress.phase {
            FileHandle.standardError.write(Data("Removing [\(index + 1)/\(total)] \(progress.currentFile ?? "")\n".utf8))
        }
    }

    print("\nRemoved: \(report.removed.count)")
    if let backup = report.backup {
        print("Backup:  \(backup.directoryURL.path)")
    }
    if !report.failures.isEmpty {
        print("\nFailures (\(report.failures.count)):")
        for failure in report.failures {
            print("  ! \(failure.message)")
        }
        exit(1)
    }
}

// MARK: - Playlists

func describe(_ playlist: Playlist) -> String {
    var tags: [String] = []
    if playlist.isMaster { tags.append("master") }
    if playlist.isSmart { tags.append("smart, read-only") }
    let suffix = tags.isEmpty ? "" : "  [\(tags.joined(separator: ", "))]"
    return "[\(playlist.id)] \(playlist.title ?? "(untitled)")  \(playlist.trackIDsInOrder.count) track(s)\(suffix)"
}

func runPlaylists(_ args: [String]) throws {
    let (positional, _, _, _) = parseFlags(args)
    guard positional.count == 1 else { fail("usage: dapctl playlists <volume>") }
    let volume = try openVolume(positional[0])
    let db = try PlaylistEditor(volume: volume).database()
    // Grouped by mhsd section: a database in the wild commonly mirrors its
    // master playlist across two sections under one persistent ID, and the
    // copies can hold different entries. A flat list makes that look like a
    // duplicate rather than what it is.
    for section in db.playlistSections {
        print("mhsd section type \(section.sectionType):")
        for playlist in section.playlists {
            print("  \(describe(playlist))")
        }
    }
    print("\n\(db.playlists.count) playlist(s) across \(db.playlistSections.count) section(s)")
}

/// Reports what a playlist mutation did, and where the previous database went.
func reportPlaylistEdit(_ message: String, backup: BackupManager.Backup?) {
    print(message)
    if let backup {
        print("Backup: \(backup.directoryURL.path)")
    }
}

func parseTrackIDs(_ args: some Collection<String>) throws -> [UInt32] {
    try args.map { arg in
        guard let id = UInt32(arg) else { throw CLIError("\"\(arg)\" is not a track ID; run `dapctl list` to see them") }
        return id
    }
}

func confirmPlaylistWrite(_ question: String, volume: DAPVolume, yes: Bool) -> Bool {
    if yes { return true }
    print("A backup of the current database will be written to:\n  \(BackupManager(volume: volume).backupsDirectory.path)")
    return promptYesNo(question)
}

func runPlaylist(_ args: [String]) throws {
    let usage = """
    usage: dapctl playlist show    <volume> <playlist>
           dapctl playlist create  <volume> <name> [trackID...] [--section N] [--yes]
           dapctl playlist rename  <volume> <playlist> <new-name> [--yes]
           dapctl playlist delete  <volume> <playlist> [--yes]
           dapctl playlist add     <volume> <playlist> <trackID>... [--yes]
           dapctl playlist rm      <volume> <playlist> <trackID>... [--yes]
           dapctl playlist reorder <volume> <playlist> <trackID>... [--yes]

    <playlist> is a playlist's persistent ID or its exact title.
    """
    guard let subcommand = args.first else { fail(usage) }
    let (positional, _, yes, section) = parseFlags(Array(args.dropFirst()))
    guard let volumePath = positional.first else { fail(usage) }
    let volume = try openVolume(volumePath)
    let editor = PlaylistEditor(volume: volume)
    let rest = Array(positional.dropFirst())

    switch subcommand {
    case "show":
        guard rest.count == 1 else { fail(usage) }
        let db = try editor.database()
        let playlist = try editor.resolve(rest[0], in: db)
        print(describe(playlist))
        let byID = Dictionary(db.tracks.map { ($0.uniqueID, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, trackID) in playlist.trackIDsInOrder.enumerated() {
            if let track = byID[trackID] {
                print("  \(index + 1). [\(trackID)] \(track.artist ?? "?") - \(track.title ?? "?")")
            } else {
                print("  \(index + 1). [\(trackID)] <no such track in the database>")
            }
        }

    case "create":
        guard let name = rest.first else { fail(usage) }
        let trackIDs = try parseTrackIDs(rest.dropFirst())
        guard confirmPlaylistWrite("Create playlist \"\(name)\" with \(trackIDs.count) track(s)?", volume: volume, yes: yes) else {
            print("Aborted.")
            return
        }
        let (id, backup) = try editor.create(title: name, trackIDs: trackIDs, sectionType: section)
        let where_ = section.map { " in mhsd section \($0)" } ?? ""
        reportPlaylistEdit("Created playlist \"\(name)\" (ID \(id)) with \(trackIDs.count) track(s)\(where_).", backup: backup)

    case "rename":
        guard rest.count == 2 else { fail(usage) }
        let playlist = try editor.resolve(rest[0], in: try editor.database())
        guard confirmPlaylistWrite("Rename \"\(playlist.title ?? "(untitled)")\" to \"\(rest[1])\"?", volume: volume, yes: yes) else {
            print("Aborted.")
            return
        }
        let backup = try editor.rename(id: playlist.id, to: rest[1])
        reportPlaylistEdit("Renamed playlist \(playlist.id) to \"\(rest[1])\".", backup: backup)

    case "delete":
        guard rest.count == 1 else { fail(usage) }
        let playlist = try editor.resolve(rest[0], in: try editor.database())
        print("Deleting a playlist removes only the playlist; the tracks themselves stay on the device.")
        guard confirmPlaylistWrite("Delete playlist \"\(playlist.title ?? "(untitled)")\" (\(playlist.trackIDsInOrder.count) track(s))?", volume: volume, yes: yes) else {
            print("Aborted.")
            return
        }
        let backup = try editor.delete(id: playlist.id)
        reportPlaylistEdit("Deleted playlist \(playlist.id).", backup: backup)

    case "add":
        guard rest.count >= 2 else { fail(usage) }
        let playlist = try editor.resolve(rest[0], in: try editor.database())
        let trackIDs = try parseTrackIDs(rest.dropFirst())
        guard confirmPlaylistWrite("Add \(trackIDs.count) track(s) to \"\(playlist.title ?? "(untitled)")\"?", volume: volume, yes: yes) else {
            print("Aborted.")
            return
        }
        let backup = try editor.addTracks(trackIDs, toPlaylistID: playlist.id)
        reportPlaylistEdit("Added \(trackIDs.count) track(s) to playlist \(playlist.id).", backup: backup)

    case "rm":
        guard rest.count >= 2 else { fail(usage) }
        let playlist = try editor.resolve(rest[0], in: try editor.database())
        let trackIDs = try parseTrackIDs(rest.dropFirst())
        print("This removes the tracks from the playlist only; the audio files stay on the device.")
        guard confirmPlaylistWrite("Remove \(trackIDs.count) track(s) from \"\(playlist.title ?? "(untitled)")\"?", volume: volume, yes: yes) else {
            print("Aborted.")
            return
        }
        let backup = try editor.removeTracks(trackIDs, fromPlaylistID: playlist.id)
        reportPlaylistEdit("Removed \(trackIDs.count) track(s) from playlist \(playlist.id).", backup: backup)

    case "reorder":
        guard rest.count >= 2 else { fail(usage) }
        let playlist = try editor.resolve(rest[0], in: try editor.database())
        let newOrder = try parseTrackIDs(rest.dropFirst())
        guard confirmPlaylistWrite("Reorder \"\(playlist.title ?? "(untitled)")\" into the \(newOrder.count) given track(s)?", volume: volume, yes: yes) else {
            print("Aborted.")
            return
        }
        let backup = try editor.reorder(id: playlist.id, trackIDsInOrder: newOrder)
        reportPlaylistEdit("Reordered playlist \(playlist.id).", backup: backup)

    default:
        fail("unknown playlist subcommand \"\(subcommand)\"\n\n\(usage)")
    }
}

// MARK: - Entry point

let arguments = Array(CommandLine.arguments.dropFirst())

guard let command = arguments.first else {
    print("""
    dapctl: validate DAPSync against real hardware.

    Usage:
      dapctl info  <volume>
      dapctl list  <volume>
      dapctl scan  <source-folder>
      dapctl plan  <volume> <source> [--limit N]
      dapctl sync  <volume> <source> [--limit N] [--yes]
      dapctl remove <volume> <trackID>... [--yes]
      dapctl playlists <volume>
      dapctl playlist <show|create|rename|delete|add|rm|reorder> ...
    """)
    exit(1)
}

let rest = Array(arguments.dropFirst())

do {
    switch command {
    case "info":
        try runInfo(rest)
    case "list":
        try runList(rest)
    case "scan":
        try await runScan(rest)
    case "plan":
        try await runPlan(rest)
    case "sync":
        try await runSync(rest)
    case "remove":
        try await runRemove(rest)
    case "playlists":
        try runPlaylists(rest)
    case "playlist":
        try runPlaylist(rest)
    default:
        fail("unknown command \"\(command)\"")
    }
} catch {
    fail(String(describing: error))
}
