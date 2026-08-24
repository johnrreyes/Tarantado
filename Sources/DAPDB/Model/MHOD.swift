import Foundation

/// Typed view over an "mhod" chunk (a single metadata object attached to a
/// track, playlist, or playlist entry).
///
/// Header layout (confirmed against libgpod's `get_mhod`/`mk_mhod` in
/// `itdb_itunesdb.c`), `headerLen` is always 24:
/// ```
/// 0  tag "mhod"
/// 4  headerLen (u32) = 24
/// 8  totalLen  (u32) = header + payload
/// 12 type      (u32) — an `MHOD.Kind` raw value
/// 16 unknown   (u32)
/// 20 unknown   (u32)
/// ```
/// For the string types, the payload (in `chunk.trailingBytes`, since a
/// string body is never itself a nested "mh"-tagged chunk) is:
/// ```
/// 0  string encoding (u32) — 1 (or 0) = UTF-16LE, 2 = UTF-8
/// 4  byte length of the string (u32)
/// 8  unknown (u32, observed as 1)
/// 12 unknown (u32, observed as 0)
/// 16 text, `byteLength` bytes
/// ```
/// For all other types (smart-playlist prefs/rules, chapter data, library
/// playlist index, ...) the payload is exposed only as opaque `Data` — this
/// library never reinterprets it.
public struct MHOD: Equatable {
    public var chunk: Chunk

    public init?(_ chunk: Chunk) {
        guard chunk.tag == "mhod" else { return nil }
        self.chunk = chunk
    }

    /// Well-known MHOD types. Names and values cross-checked against
    /// libgpod's `enum MHOD_ID`. Not exhaustive — anything else surfaces via
    /// `type` and, for non-string types, `opaquePayload`.
    public enum Kind: UInt32, Sendable {
        case title = 1
        case location = 2 // file path on iPod, special format
        case album = 3
        case artist = 4
        case genre = 5
        case filetype = 6
        case comment = 8
        case category = 9
        case composer = 12
        case grouping = 13
        case description = 14
        case podcastURL = 15
        case podcastRSS = 16
        case chapterData = 17
        case subtitle = 18
        case tvShow = 19
        case tvEpisode = 20
        case tvNetwork = 21
        case albumArtist = 22
        case sortArtist = 23
        case keywords = 24
        case sortTitle = 27
        case sortAlbum = 28
        case sortAlbumArtist = 29
        case sortComposer = 30
        case sortTVShow = 31
        /// Settings for a smart playlist. Opaque — never reinterpreted.
        case smartPlaylistPrefs = 50
        /// Rules for a smart playlist. Opaque — never reinterpreted.
        case smartPlaylistRules = 51
        case libraryPlaylistIndex = 52
        case libraryPlaylistJumpTable = 53
        /// Position of a track within a playlist (child of an `mhip`), or
        /// (unused/opaque) playlist settings when a direct child of `mhyp`.
        case playlistPosition = 100
    }

    public var type: UInt32 {
        chunk.headerBytes.leU32(at: 12) ?? 0
    }

    public var kind: Kind? { Kind(rawValue: type) }

    private static let stringTypes: Set<UInt32> = [
        Kind.title.rawValue, Kind.location.rawValue, Kind.album.rawValue, Kind.artist.rawValue,
        Kind.genre.rawValue, Kind.filetype.rawValue, Kind.comment.rawValue, Kind.category.rawValue,
        Kind.composer.rawValue, Kind.grouping.rawValue, Kind.description.rawValue,
        Kind.podcastURL.rawValue, Kind.podcastRSS.rawValue, Kind.subtitle.rawValue,
        Kind.tvShow.rawValue, Kind.tvEpisode.rawValue, Kind.tvNetwork.rawValue,
        Kind.albumArtist.rawValue, Kind.sortArtist.rawValue, Kind.keywords.rawValue,
        Kind.sortTitle.rawValue, Kind.sortAlbum.rawValue, Kind.sortAlbumArtist.rawValue,
        Kind.sortComposer.rawValue, Kind.sortTVShow.rawValue,
    ]

    public var isStringType: Bool { MHOD.stringTypes.contains(type) }

    /// The decoded string payload, for string-typed MHODs (title, artist, ...).
    /// `nil` for non-string types, or if the payload is malformed.
    public var stringValue: String? {
        guard isStringType else { return nil }
        let payload = chunk.trailingBytes
        guard let encoding = payload.leU32(at: 0), let byteLen = payload.leU32(at: 4) else { return nil }
        let start = 16
        let end = start + Int(byteLen)
        guard end <= payload.count, start <= end else { return nil }
        let textStart = payload.startIndex + start
        let textEnd = payload.startIndex + end
        let text = payload[textStart..<textEnd]
        if encoding == 2 {
            return String(data: text, encoding: .utf8)
        } else {
            return MHOD.decodeUTF16LE(text)
        }
    }

    /// The raw payload bytes for non-string types (smart playlist prefs/rules,
    /// chapter data, etc.) — never reinterpreted, exposed as-is.
    public var opaquePayload: Data? {
        guard !isStringType else { return nil }
        return chunk.trailingBytes
    }

    private static func decodeUTF16LE(_ data: Data.SubSequence) -> String? {
        guard data.count % 2 == 0 else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(data.count / 2)
        var i = data.startIndex
        while i < data.endIndex {
            let lo = UInt16(data[i])
            let hi = UInt16(data[data.index(after: i)])
            units.append(lo | (hi << 8))
            i = data.index(i, offsetBy: 2)
        }
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: - Construction

    /// Builds a new string-typed `mhod` chunk (UTF-16LE payload, matching what
    /// libgpod's `mk_mhod` writes for a non-endian-reversed iTunesDB).
    public static func makeString(type: UInt32, value: String) -> Chunk {
        let units = Array(value.utf16)
        var w = ByteWriter()
        w.fourCC("mhod")
        w.u32(24) // headerLen
        let totalLen = UInt32(24 + 16 + units.count * 2)
        w.u32(totalLen)
        w.u32(type)
        w.u32(0) // unknown
        w.u32(0) // unknown
        // payload
        w.u32(1) // string encoding: UTF-16LE
        w.u32(UInt32(units.count * 2))
        w.u32(1) // unknown, observed as 1
        w.u32(0) // unknown
        for u in units {
            w.u8(UInt8(u & 0xff))
            w.u8(UInt8((u >> 8) & 0xff))
        }
        let full = w.finalize()
        let headerBytes = full.subdata(in: full.startIndex..<(full.startIndex + 24))
        let trailing = full.subdata(in: (full.startIndex + 24)..<full.endIndex)
        return Chunk(tag: "mhod", headerLen: 24, headerBytes: headerBytes, children: [], trailingBytes: trailing)
    }

    public static func makeString(kind: Kind, value: String) -> Chunk {
        makeString(type: kind.rawValue, value: value)
    }

    /// Builds a new opaque-payload `mhod` chunk (smart playlist prefs/rules,
    /// chapter data, etc.) by wrapping raw bytes without interpreting them.
    public static func makeOpaque(type: UInt32, payload: Data) -> Chunk {
        var w = ByteWriter()
        w.fourCC("mhod")
        w.u32(24)
        w.u32(UInt32(24 + payload.count))
        w.u32(type)
        w.u32(0)
        w.u32(0)
        let full = w.finalize()
        let headerBytes = full.subdata(in: full.startIndex..<(full.startIndex + 24))
        return Chunk(tag: "mhod", headerLen: 24, headerBytes: headerBytes, children: [], trailingBytes: payload)
    }

    /// Builds the "position of track in playlist" mhod that is the sole child
    /// of every `mhip`, matching libgpod's `mk_mhod` for `MHOD_ID_PLAYLIST`.
    public static func makePlaylistPosition(_ position: UInt32) -> Chunk {
        var w = ByteWriter()
        w.fourCC("mhod")
        w.u32(24)
        w.u32(44) // header(24) + 5 x u32(4) = 44
        w.u32(Kind.playlistPosition.rawValue)
        w.u32(0)
        w.u32(0)
        w.u32(position)
        w.zeros(16) // 4 unknown u32 fields, all zero
        let full = w.finalize()
        let headerBytes = full.subdata(in: full.startIndex..<(full.startIndex + 24))
        let trailing = full.subdata(in: (full.startIndex + 24)..<full.endIndex)
        return Chunk(tag: "mhod", headerLen: 24, headerBytes: headerBytes, children: [], trailingBytes: trailing)
    }

    /// The playlist-position value carried by a `playlistPosition` mhod (child of an `mhip`).
    public var playlistPosition: UInt32? {
        guard kind == .playlistPosition else { return nil }
        return chunk.trailingBytes.leU32(at: 0)
    }
}
