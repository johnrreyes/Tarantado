import Foundation

/// Typed view over an "mhit" chunk (one track record).
///
/// Field offsets below are cross-checked against libgpod's `get_mhit`/
/// `mk_mhit` in `itdb_itunesdb.c` (the variable names there, not always the
/// inline comments next to them — a few comments are copy-paste leftovers
/// that don't match the field they're next to; the C variable names are
/// consistent between the read and write sides and are what's followed here).
///
/// `headerLen` varies by iPod/iTunes generation (0x9c for iTunes ≤4.7, 0xf4
/// for 4.7.1–4.9, larger still for modern libgpod with gapless/HD-video
/// fields). Every accessor here is bounds-checked against the chunk's actual
/// `headerBytes` and returns `nil`/0 if the field's offset falls outside it,
/// rather than assuming a fixed size.
public struct MHIT: Equatable {
    public var chunk: Chunk

    public init?(_ chunk: Chunk) {
        guard chunk.tag == "mhit" else { return nil }
        self.chunk = chunk
    }

    private var h: Data { chunk.headerBytes }

    // MARK: - Header fields (offsets relative to the start of the mhit)

    /// The iPod-local track index ("iPod ID"). This is what `mhip` entries
    /// reference by track ID — distinct from `dbid`.
    public var uniqueID: UInt32 { h.leU32(at: 16) ?? 0 }
    public var visible: Bool { (h.leU32(at: 20) ?? 0) != 0 }
    /// Raw filetype marker (e.g. an MP3/AAC/WAV four-byte code). The
    /// human-readable filetype string, if present, lives in a child mhod of
    /// type `.filetype` instead.
    public var filetypeMarker: UInt32 { h.leU32(at: 24) ?? 0 }
    public var type1: UInt8 { h.leU8(at: 28) ?? 0 }
    public var type2: UInt8 { h.leU8(at: 29) ?? 0 }
    public var compilation: Bool { (h.leU8(at: 30) ?? 0) != 0 }
    /// Star rating on a 0...100 scale in steps of 20 (i.e. `rating / 20` stars).
    public var rating: UInt8 { h.leU8(at: 31) ?? 0 }
    public var dateModified: Date? { MacEpoch.date(fromRaw: h.leU32(at: 32) ?? 0) }
    public var size: UInt32 { h.leU32(at: 36) ?? 0 }
    /// Track length in milliseconds.
    public var length: UInt32 { h.leU32(at: 40) ?? 0 }
    public var trackNumber: UInt32 { h.leU32(at: 44) ?? 0 }
    public var totalTracks: UInt32 { h.leU32(at: 48) ?? 0 }
    public var year: UInt32 { h.leU32(at: 52) ?? 0 }
    public var bitrate: UInt32 { h.leU32(at: 56) ?? 0 }
    /// Sample rate in Hz (the high 16 bits of the combined field at offset 60;
    /// the low 16 bits are a fractional remainder, rarely used).
    public var sampleRate: UInt32 { (h.leU32(at: 60) ?? 0) >> 16 }
    public var volume: Int32 { Int32(bitPattern: h.leU32(at: 64) ?? 0) }
    public var startTime: UInt32 { h.leU32(at: 68) ?? 0 }
    public var stopTime: UInt32 { h.leU32(at: 72) ?? 0 }
    public var soundCheck: UInt32 { h.leU32(at: 76) ?? 0 }
    public var playCount: UInt32 { h.leU32(at: 80) ?? 0 }
    public var lastPlayed: Date? { MacEpoch.date(fromRaw: h.leU32(at: 88) ?? 0) }
    public var discNumber: UInt32 { h.leU32(at: 92) ?? 0 }
    public var totalDiscs: UInt32 { h.leU32(at: 96) ?? 0 }
    public var dateAdded: Date? { MacEpoch.date(fromRaw: h.leU32(at: 104) ?? 0) }
    public var bookmarkTime: UInt32 { h.leU32(at: 108) ?? 0 }
    /// The persistent library database ID (distinct from `uniqueID`).
    public var dbid: UInt64 { h.leU64(at: 112) ?? 0 }
    public var checked: Bool { (h.leU8(at: 120) ?? 0) != 0 }
    public var appRating: UInt8 { h.leU8(at: 121) ?? 0 }
    public var bpm: UInt16 { h.leU16(at: 122) ?? 0 }
    public var artworkCount: UInt16 { h.leU16(at: 124) ?? 0 }
    public var artworkSize: UInt32 { h.leU32(at: 128) ?? 0 }
    public var sampleRate2: Float { h.leFloat32(at: 136) ?? 0 }
    public var dateReleased: Date? { MacEpoch.date(fromRaw: h.leU32(at: 140) ?? 0) }
    public var explicitFlag: UInt16 { h.leU16(at: 146) ?? 0 }
    public var skipCount: UInt32 { h.leU32(at: 156) ?? 0 }
    public var lastSkipped: Date? { MacEpoch.date(fromRaw: h.leU32(at: 160) ?? 0) }
    public var hasArtwork: UInt8 { h.leU8(at: 164) ?? 0 }
    public var skipWhenShuffling: Bool { (h.leU8(at: 165) ?? 0) != 0 }
    public var rememberPlaybackPosition: Bool { (h.leU8(at: 166) ?? 0) != 0 }
    public var dbid2: UInt64 { h.leU64(at: 168) ?? 0 }
    public var lyricsFlag: UInt8 { h.leU8(at: 176) ?? 0 }
    public var movieFlag: UInt8 { h.leU8(at: 177) ?? 0 }
    public var markUnplayed: UInt8 { h.leU8(at: 178) ?? 0 }
    public var pregap: UInt32 { h.leU32(at: 184) ?? 0 }
    public var sampleCount: UInt64 { h.leU64(at: 188) ?? 0 }
    public var postgap: UInt32 { h.leU32(at: 200) ?? 0 }
    /// Bitmask, see libgpod's `ITDB_MEDIATYPE_*` (audio=1, movie=2, podcast=4,
    /// audiobook=8, music video=32, TV show=64, ringtone, rental, ...).
    public var mediaType: UInt32 { h.leU32(at: 208) ?? 0 }
    public var seasonNumber: UInt32 { h.leU32(at: 212) ?? 0 }
    public var episodeNumber: UInt32 { h.leU32(at: 216) ?? 0 }

    // MARK: - Child MHODs

    public var mhods: [MHOD] { chunk.children(tag: "mhod").compactMap(MHOD.init) }

    private func string(_ kind: MHOD.Kind) -> String? {
        mhods.first { $0.kind == kind }?.stringValue
    }

    public var title: String? { string(.title) }
    public var location: String? { string(.location) }
    public var album: String? { string(.album) }
    public var artist: String? { string(.artist) }
    public var genre: String? { string(.genre) }
    public var filetype: String? { string(.filetype) }
    public var comment: String? { string(.comment) }
    public var composer: String? { string(.composer) }
    public var grouping: String? { string(.grouping) }

    // MARK: - Construction

    /// All the fields a freshly-built `mhit` needs to describe a track. Only
    /// the subset of libgpod's full field set requested for this deliverable
    /// is exposed as constructor parameters; everything else is zero-filled.
    public struct Fields {
        public var uniqueID: UInt32
        public var visible: Bool = true
        public var filetypeMarker: UInt32 = 0
        public var size: UInt32 = 0
        public var length: UInt32 = 0
        public var trackNumber: UInt32 = 0
        public var totalTracks: UInt32 = 0
        public var year: UInt32 = 0
        public var bitrate: UInt32 = 0
        public var sampleRate: UInt32 = 0
        public var playCount: UInt32 = 0
        public var rating: UInt8 = 0
        public var dateAdded: Date? = nil
        public var lastPlayed: Date? = nil
        public var discNumber: UInt32 = 0
        public var totalDiscs: UInt32 = 0
        public var dbid: UInt64 = 0
        public var mediaType: UInt32 = 0
        /// Part of a compilation album. Header byte at offset 30; the iPod
        /// groups these under "Compilations" rather than by album artist.
        public var compilation: Bool = false

        /// Whether this track carries artwork, offset 164. `0` = never
        /// checked (this library's behavior before album art support: every
        /// track written this way), `1` = has artwork, `2` = explicitly
        /// checked and found none. Cross-checked against libgpod's
        /// `itdb_track.c` (`track->has_artwork = 0x01`/`0x02`) and
        /// independently against iOpenPod's `mhit_defs.py`. Left at the
        /// default `0` for devices this library doesn't attempt artwork on.
        public var hasArtwork: UInt8 = 0
        /// `1` if a source image was packed into this track's tags, matching
        /// libgpod's fixed `track->artwork_count = 1` (a legacy MP3-tag-era
        /// count, not the number of on-device thumbnail formats generated —
        /// see `MHII`'s doc). `0` when there's no artwork. Offset 124.
        public var artworkCount: UInt16 = 0
        /// Byte size of the *source* image (e.g. the embedded JPEG), mirrored
        /// into the correlated `MHII.origImageSize`. Offset 128.
        public var artworkSize: UInt32 = 0

        public init(uniqueID: UInt32) {
            self.uniqueID = uniqueID
        }
    }

    /// Header size used by freshly-built mhit chunks: 244 bytes (0xf4), the
    /// size libgpod documents for iTunesDB versions 0x0c/0x0d ("iTunes 4.7.1
    /// through 4.9"). This comfortably covers every field in `Fields` above
    /// (the last of which, `mediaType`, sits at offset 208) plus a run of
    /// zeroed `unk*` fields up to offset 244, without reaching into the
    /// gapless-playback / HD-video fields that only exist in the larger
    /// (0x248-byte) header modern libgpod writes.
    public static let defaultHeaderLen: UInt32 = 244

    /// Builds a new "mhit" chunk with the given fields and child string MHODs.
    public static func make(_ fields: Fields, strings: [MHOD.Kind: String] = [:]) -> Chunk {
        var w = ByteWriter()
        w.fourCC("mhit")
        w.u32(defaultHeaderLen)
        w.u32(0) // totalLen, patched below once children are known
        w.u32(0) // mhod count, patched below

        w.u32(fields.uniqueID) // +16
        w.u32(fields.visible ? 1 : 0)
        w.u32(fields.filetypeMarker)
        w.u8(0) // type1
        w.u8(0) // type2
        w.u8(fields.compilation ? 1 : 0) // compilation
        w.u8(fields.rating)
        w.u32(0) // dateModified (+32)
        w.u32(fields.size) // +36
        w.u32(fields.length) // +40
        w.u32(fields.trackNumber) // +44
        w.u32(fields.totalTracks) // +48
        w.u32(fields.year) // +52
        w.u32(fields.bitrate) // +56
        w.u32(fields.sampleRate << 16) // +60
        w.u32(0) // volume +64
        w.u32(0) // starttime +68
        w.u32(0) // stoptime +72
        w.u32(0) // soundcheck +76
        w.u32(fields.playCount) // +80
        w.u32(0) // playcount2 +84
        w.u32(MacEpoch.raw(from: fields.lastPlayed)) // +88
        w.u32(fields.discNumber) // +92
        w.u32(fields.totalDiscs) // +96
        w.u32(0) // drm_userid +100
        w.u32(MacEpoch.raw(from: fields.dateAdded)) // +104
        w.u32(0) // bookmark_time +108
        w.u64(fields.dbid) // +112
        w.u8(0) // checked +120
        w.u8(0) // app_rating +121
        w.u16(0) // BPM +122
        w.u16(fields.artworkCount) // +124
        w.u16(0) // unk126
        w.u32(fields.artworkSize) // +128
        w.u32(0) // unk132
        w.u32(0) // samplerate2 +136
        w.u32(0) // dateReleased +140
        w.u16(0) // unk144
        w.u16(0) // explicit_flag +146
        w.u32(0) // unk148
        w.u32(0) // unk152
        w.u32(0) // skipcount +156
        w.u32(0) // last_skipped +160
        w.u8(fields.hasArtwork) // +164
        w.u8(0) // skip_when_shuffling +165
        w.u8(0) // remember_playback_position +166
        w.u8(0) // flag4 +167
        w.u64(0) // dbid2 +168
        w.u8(0) // lyrics_flag +176
        w.u8(0) // movie_flag +177
        w.u8(0) // mark_unplayed +178
        w.u8(0) // unk179
        w.u32(0) // unk180
        w.u32(0) // pregap +184
        w.u64(0) // samplecount +188
        w.u32(0) // unk196
        w.u32(0) // postgap +200
        w.u32(0) // unk204
        w.u32(fields.mediaType) // +208
        w.u32(0) // season_nr +212
        w.u32(0) // episode_nr +216
        w.u32(0) // unk220
        w.u32(0) // unk224
        w.u32(0) // unk228
        w.u32(0) // unk232
        w.u32(0) // unk236
        w.u32(0) // unk240 -- ends at offset 244

        precondition(w.count == Int(defaultHeaderLen))
        var headerBytes = w.finalize()

        var children: [Chunk] = []
        for (kind, value) in strings {
            children.append(MHOD.makeString(kind: kind, value: value))
        }

        let childrenLen = children.reduce(0) { $0 + $1.serializedByteCount }
        headerBytes.setLE(UInt32(Int(defaultHeaderLen) + childrenLen), at: 8)
        headerBytes.setLE(UInt32(children.count), at: 12)

        return Chunk(tag: "mhit", headerLen: defaultHeaderLen, headerBytes: headerBytes, children: children, trailingBytes: Data())
    }
}
