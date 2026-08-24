import Foundation

/// A plain-value snapshot of an `mhit` chunk's commonly-used fields, for
/// callers that don't need to touch the chunk tree directly.
public struct Track: Equatable, Sendable {
    public var uniqueID: UInt32
    public var dbid: UInt64
    public var visible: Bool
    public var filetypeMarker: UInt32
    public var size: UInt32
    public var length: UInt32
    public var trackNumber: UInt32
    public var totalTracks: UInt32
    public var year: UInt32
    public var bitrate: UInt32
    public var sampleRate: UInt32
    public var playCount: UInt32
    public var rating: UInt8
    public var dateAdded: Date?
    public var lastPlayed: Date?
    public var discNumber: UInt32
    public var totalDiscs: UInt32
    public var mediaType: UInt32

    public var title: String?
    public var location: String?
    public var album: String?
    public var artist: String?
    public var genre: String?
    public var filetype: String?
    public var comment: String?
    public var composer: String?
    public var grouping: String?

    public init(from mhit: MHIT) {
        uniqueID = mhit.uniqueID
        dbid = mhit.dbid
        visible = mhit.visible
        filetypeMarker = mhit.filetypeMarker
        size = mhit.size
        length = mhit.length
        trackNumber = mhit.trackNumber
        totalTracks = mhit.totalTracks
        year = mhit.year
        bitrate = mhit.bitrate
        sampleRate = mhit.sampleRate
        playCount = mhit.playCount
        rating = mhit.rating
        dateAdded = mhit.dateAdded
        lastPlayed = mhit.lastPlayed
        discNumber = mhit.discNumber
        totalDiscs = mhit.totalDiscs
        mediaType = mhit.mediaType

        title = mhit.title
        location = mhit.location
        album = mhit.album
        artist = mhit.artist
        genre = mhit.genre
        filetype = mhit.filetype
        comment = mhit.comment
        composer = mhit.composer
        grouping = mhit.grouping
    }
}
