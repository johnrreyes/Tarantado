// Builds a synthetic DAP volume with invented demo content, for App Store
// screenshots. Development tool only: it is a package target with no product
// entry, so it never ships in the app.
//
//   swift run demoseed <output-volume-dir> <golden-itunesdb>
//
// The track metadata is deliberately fictional. Screenshots go on a public
// store listing, so inventing artists and albums avoids putting anyone's real
// catalogue on the page.
import Foundation
import DAPDB

struct DemoTrack {
    let title: String
    let artist: String
    let album: String
    let genre: String
    let year: UInt32
    let seconds: UInt32
    let trackNumber: UInt32
    let totalTracks: UInt32
}

let demoTracks: [DemoTrack] = [
    .init(title: "Ferrite Bloom", artist: "Halcyon Test Pattern", album: "Ferrite Bloom", genre: "Electronic", year: 2004, seconds: 253, trackNumber: 1, totalTracks: 9),
    .init(title: "Slow Ferry", artist: "Halcyon Test Pattern", album: "Ferrite Bloom", genre: "Electronic", year: 2004, seconds: 194, trackNumber: 2, totalTracks: 9),
    .init(title: "Nightwater", artist: "Halcyon Test Pattern", album: "Ferrite Bloom", genre: "Electronic", year: 2004, seconds: 311, trackNumber: 3, totalTracks: 9),
    .init(title: "Signal Hill", artist: "Marisol Vane", album: "Paper Lanterns", genre: "Folk", year: 2006, seconds: 227, trackNumber: 1, totalTracks: 11),
    .init(title: "Paper Lanterns", artist: "Marisol Vane", album: "Paper Lanterns", genre: "Folk", year: 2006, seconds: 268, trackNumber: 2, totalTracks: 11),
    .init(title: "The Long Green", artist: "Marisol Vane", album: "Paper Lanterns", genre: "Folk", year: 2006, seconds: 205, trackNumber: 3, totalTracks: 11),
    .init(title: "Brass Weather", artist: "The Ordinal Set", album: "Brass Weather", genre: "Jazz", year: 2003, seconds: 342, trackNumber: 1, totalTracks: 7),
    .init(title: "Eight Below", artist: "The Ordinal Set", album: "Brass Weather", genre: "Jazz", year: 2003, seconds: 289, trackNumber: 2, totalTracks: 7),
    .init(title: "Quiet Ledger", artist: "The Ordinal Set", album: "Brass Weather", genre: "Jazz", year: 2003, seconds: 246, trackNumber: 3, totalTracks: 7),
    .init(title: "Cassette Sunrise", artist: "Neon Almanac", album: "Cassette Sunrise", genre: "Pop", year: 2005, seconds: 214, trackNumber: 1, totalTracks: 10),
    .init(title: "Radio Silence", artist: "Neon Almanac", album: "Cassette Sunrise", genre: "Pop", year: 2005, seconds: 232, trackNumber: 2, totalTracks: 10),
    .init(title: "Static Bloom", artist: "Neon Almanac", album: "Cassette Sunrise", genre: "Pop", year: 2005, seconds: 259, trackNumber: 3, totalTracks: 10),
    .init(title: "Winter Ordinal", artist: "Kessler Line", album: "Winter Ordinal", genre: "Ambient", year: 2007, seconds: 401, trackNumber: 1, totalTracks: 6),
    .init(title: "Glasshouse", artist: "Kessler Line", album: "Winter Ordinal", genre: "Ambient", year: 2007, seconds: 355, trackNumber: 2, totalTracks: 6),
]

let sysInfoText = """
BoardHwName: iPod Q22B
pszSerialNumber: EXAMPLE0001
ModelNumStr: M9800
FirewireGuid: 0x000A270000000001
HddFirmwareRev: Rev 3.72
RegionCode: LL(0x0001)
visibleBuildID: 0x01418000 (1.4.1)
iPodFamily: 0x00000003
"""

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: demoseed <output-volume-dir> <golden-itunesdb>\n".data(using: .utf8)!)
    exit(2)
}
let root = URL(fileURLWithPath: args[1], isDirectory: true)
let goldenURL = URL(fileURLWithPath: args[2])

let fm = FileManager.default
try? fm.removeItem(at: root)

let control = root.appendingPathComponent("iPod_Control", isDirectory: true)
let deviceDir = control.appendingPathComponent("Device", isDirectory: true)
let iTunesDir = control.appendingPathComponent("iTunes", isDirectory: true)
let musicDir = control.appendingPathComponent("Music", isDirectory: true)
for dir in [deviceDir, iTunesDir, musicDir] {
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
}
for index in 0..<50 {
    try fm.createDirectory(
        at: musicDir.appendingPathComponent(String(format: "F%02d", index), isDirectory: true),
        withIntermediateDirectories: true
    )
}
try sysInfoText.write(to: deviceDir.appendingPathComponent("SysInfo"), atomically: true, encoding: .utf8)

// Start from the golden database so the surrounding chunk tree is a real one
// the firmware is known to accept, then replace its contents wholesale.
var db = try ITunesDatabase(parsing: try Data(contentsOf: goldenURL))

for track in db.tracks {
    try? db.removeTrack(uniqueID: track.uniqueID)
}
for playlist in db.playlists where !playlist.isMaster {
    try? db.removePlaylist(id: playlist.id)
}
guard let masterID = db.playlists.first(where: { $0.isMaster })?.id else {
    FileHandle.standardError.write("no master playlist in golden database\n".data(using: .utf8)!)
    exit(1)
}

var position: UInt32 = 0
var uniqueID: UInt32 = 100
var idsByAlbum: [String: [UInt32]] = [:]
var allTrackIDs: [UInt32] = []

for demo in demoTracks {
    uniqueID += 1
    let folder = String(format: "F%02d", Int(uniqueID) % 50)
    let fileName = String(format: "DEMO%04d.mp3", uniqueID)

    var fields = MHIT.Fields(uniqueID: uniqueID)
    fields.visible = true
    fields.mediaType = 1
    fields.length = demo.seconds * 1000
    fields.size = demo.seconds * 160_000 / 8      // ~160 kbps
    fields.bitrate = 160
    fields.sampleRate = 44_100
    fields.year = demo.year
    fields.trackNumber = demo.trackNumber
    fields.totalTracks = demo.totalTracks
    fields.dateAdded = Date()
    fields.dbid = UInt64(uniqueID) &* 0x9E37_79B9_7F4A_7C15
    fields.rating = [0, 60, 80, 100][Int(uniqueID) % 4]

    let strings: [MHOD.Kind: String] = [
        .title: demo.title,
        .artist: demo.artist,
        .album: demo.album,
        .genre: demo.genre,
        .filetype: "MPEG audio file",
        .location: ":iPod_Control:Music:\(folder):\(fileName)",
    ]

    try db.addTrack(MHIT.make(fields, strings: strings))
    try db.addPlaylistEntry(MHIP.make(trackID: uniqueID, position: position), toPlaylistID: masterID)
    position += 1
    idsByAlbum[demo.album, default: []].append(uniqueID)
    allTrackIDs.append(uniqueID)

    // A real file at the referenced path, so on-device size accounting and
    // any existence check see what the database claims.
    let audioURL = musicDir.appendingPathComponent(folder).appendingPathComponent(fileName)
    fm.createFile(atPath: audioURL.path, contents: Data(count: Int(fields.size)))
}

// A couple of named playlists, so the Playlists screen has something to show.
@MainActor
func addPlaylist(_ title: String, trackIDs: [UInt32]) throws {
    let id = try db.addPlaylist(title: title)
    for (index, trackID) in trackIDs.enumerated() {
        try db.addPlaylistEntry(MHIP.make(trackID: trackID, position: UInt32(index)), toPlaylistID: id)
    }
}
try addPlaylist("Evening Drive", trackIDs: Array((idsByAlbum["Ferrite Bloom"] ?? []) + (idsByAlbum["Winter Ordinal"] ?? [])))
try addPlaylist("Kitchen Radio", trackIDs: Array((idsByAlbum["Cassette Sunrise"] ?? []) + (idsByAlbum["Paper Lanterns"] ?? []).prefix(2)))
try addPlaylist("Late Shift", trackIDs: Array(idsByAlbum["Brass Weather"] ?? []))

// The golden database's master playlist carries the original owner's name
// ("<name>'s iPod"). These screenshots go on a public store listing, so give
// it a neutral title instead.
// The golden database's master playlist is titled after the original owner
// ("<name>'s iPod"), and it carries a second, empty master chunk sharing the
// real one's persistent id — neither belongs in a public store listing.
//
// Rewriting the chunk tree by hand is not an option: the size fix-up that
// keeps container headers consistent (`recomputeDerivedFields`) is internal to
// DAPDB, and skipping it produces a database the app cannot parse. So use the
// public mutation API only. `removingPlaylist` matches on id, which takes both
// masters at once, and a replacement is then added as a regular playlist.
if let masterID = db.playlists.first(where: { $0.isMaster })?.id {
    db.root = ChunkMutation.removingPlaylist(id: masterID, from: db.root)
    let allMusicID = try db.addPlaylist(title: "All Music")
    for (index, trackID) in allTrackIDs.enumerated() {
        try db.addPlaylistEntry(MHIP.make(trackID: trackID, position: UInt32(index)), toPlaylistID: allMusicID)
    }
}

try db.serialized().write(to: iTunesDir.appendingPathComponent("iTunesDB"))

// Re-read what was actually written: the chunk surgery above rewrites
// container headers, and a database the app cannot parse would otherwise only
// surface as an empty screenshot.
let written = try Data(contentsOf: iTunesDir.appendingPathComponent("iTunesDB"))
let reparsed = try ITunesDatabase(parsing: written)
guard reparsed.tracks.count == db.tracks.count,
      reparsed.playlists.count == db.playlists.count else {
    FileHandle.standardError.write("re-parse mismatch: \(reparsed.tracks.count) tracks / \(reparsed.playlists.count) playlists\n".data(using: .utf8)!)
    exit(1)
}
print("re-parse OK: \(reparsed.tracks.count) tracks, \(reparsed.playlists.count) playlists")

print("demo volume: \(root.path)")
print("tracks: \(db.tracks.count)  playlists: \(db.playlists.count)")
for playlist in db.playlists {
    let kind = playlist.isMaster ? "master" : (playlist.isSmart ? "smart" : "regular")
    print("  [\(kind)] id=\(playlist.id) \(playlist.title ?? "untitled") — \(playlist.trackIDsInOrder.count) tracks")
}
