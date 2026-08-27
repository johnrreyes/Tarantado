import Foundation

/// A parsed ArtworkDB (`iPod_Control/Artwork/ArtworkDB`), as a typed façade
/// over the underlying (still fully accessible) generic chunk tree.
///
/// Structurally the album-art counterpart to `ITunesDatabase`: same chunk
/// grammar (`ChunkTree.parse`/`serialize` are root-tag agnostic), different
/// root tag ("mhfd" instead of "mhbd") and a fixed, small set of `mhsd`
/// sections rather than iTunesDB's variable one. The three-section shape
/// built by `makeEmpty` below — image list, empty photo-album list, file
/// list — mirrors libgpod's `write_artwork_db` and is independently
/// corroborated by iOpenPod's `artworkdb_writer/artworkdb_chunks.py
/// ::build_artworkdb`.
public struct ArtworkDatabase: Equatable {
    /// The full generic chunk tree ("mhfd" at the root). Anything not yet
    /// exposed by a typed accessor is still reachable here.
    public var root: Chunk

    public init(root: Chunk) {
        self.root = root
    }

    public init(parsing data: Data) throws {
        self.root = try ChunkTree.parse(data)
    }

    public func serialized() -> Data {
        ChunkTree.serialize(root)
    }

    // MARK: - Reading

    /// ArtworkDB's `mhsd` section-type field (offset 12) is **16 bits**
    /// wide, unlike iTunesDB's 32-bit one at the same offset — a documented
    /// quirk libgpod's `_ArtworkDB_MhsdHeader` calls out explicitly ("this
    /// could well be an error with the first generation of mobile phones
    /// with iPod support"). Cross-checked against iOpenPod's
    /// `ArtworkDatasetType`.
    public enum SectionType: UInt16, Sendable {
        case imageList = 1
        case photoAlbumList = 2
        case fileList = 3
    }

    private func section(_ type: SectionType) -> Chunk? {
        root.children(tag: "mhsd").first { $0.headerBytes.leU16(at: 12) == type.rawValue }
    }

    private var imageListChunk: Chunk? {
        section(.imageList)?.firstDescendant { $0.tag == "mhli" }
    }

    public var imageChunks: [Chunk] {
        imageListChunk?.children(tag: "mhii") ?? []
    }

    public var images: [MHII] { imageChunks.compactMap(MHII.init) }

    /// The image entry correlated to a track by `MHIT.dbid`, if any. Every
    /// `mhii.songID` this library writes equals the correlated track's
    /// `dbid` — see `MHII`'s type doc.
    public func image(forTrackDBID dbid: UInt64) -> MHII? {
        images.first { $0.songID == dbid }
    }

    private var fileListChunk: Chunk? {
        section(.fileList)?.firstDescendant { $0.tag == "mhlf" }
    }

    public var fileChunks: [Chunk] {
        fileListChunk?.children(tag: "mhif") ?? []
    }

    public var files: [MHIF] { fileChunks.compactMap(MHIF.init) }

    // MARK: - Mutation

    /// Appends a new image (an `mhii` chunk, e.g. built with `MHII.make`) to
    /// the image list.
    public mutating func addImage(_ image: Chunk) throws {
        root = try ArtworkMutation.addingImage(image, to: root)
    }

    /// Removes the image entry correlated to a track by `dbid`, if any (a
    /// no-op if that track never had one).
    public mutating func removeImage(forTrackDBID dbid: UInt64) {
        root = ArtworkMutation.removingImage(songID: dbid, from: root)
    }

    /// Updates `mhfd.nextID` — the next `mhii.imageID` a caller allocating
    /// its own IDs (e.g. `SyncEngine`) should hand out after this. Purely a
    /// header field patch: unlike `addImage`, nothing here changes the
    /// tree's shape, so there's no derived `totalLen`/count to recompute.
    public mutating func setNextImageID(_ id: UInt32) {
        root.headerBytes.setLE(id, at: 28)
    }

    // MARK: - Construction

    /// Builds a fresh, empty ArtworkDB with the three fixed sections real
    /// iTunes/libgpod databases carry: an empty image list, an empty
    /// (unused for music artwork) photo-album list, and a file list holding
    /// one `mhif` per entry in `formats`.
    ///
    /// `nextImageID` seeds `mhfd.nextID`; `100` matches iTunes' own
    /// convention (see iOpenPod's `write_artworkdb(start_img_id=100, ...)`).
    public static func makeEmpty(
        formats: [(formatID: UInt32, imageSizeBytes: UInt32)],
        nextImageID: UInt32 = 100
    ) -> ArtworkDatabase {
        let imageListSection = makeSection(type: .imageList, child: makeEmptyCountedList(tag: "mhli"))
        let albumListSection = makeSection(type: .photoAlbumList, child: makeEmptyCountedList(tag: "mhla"))
        let fileListSection = makeSection(type: .fileList, child: makeMHLF(formats: formats))

        let root = MHFD.make(
            sections: [imageListSection, albumListSection, fileListSection],
            nextImageID: nextImageID
        )
        return ArtworkDatabase(root: root)
    }

    /// Header size used for freshly-built `mhsd` sections: 96 bytes,
    /// matching iOpenPod's `MHSD_HEADER_SIZE` and the value already used for
    /// the hand-built `mhsd` fixtures in `ImageListParsingTests.swift`.
    private static let mhsdHeaderLen: UInt32 = 96

    private static func makeSection(type: SectionType, child: Chunk) -> Chunk {
        var w = ByteWriter()
        w.fourCC("mhsd")
        w.u32(mhsdHeaderLen)
        w.u32(0) // totalLen, patched below
        w.u16(type.rawValue) // +12, 16-bit -- see SectionType's doc
        w.u16(0) // unknown +14
        w.zeros(Int(mhsdHeaderLen) - w.count)

        precondition(w.count == Int(mhsdHeaderLen))
        var headerBytes = w.finalize()
        headerBytes.setLE(UInt32(Int(mhsdHeaderLen) + child.serializedByteCount), at: 8)

        return Chunk(tag: "mhsd", headerLen: mhsdHeaderLen, headerBytes: headerBytes, children: [child], trailingBytes: Data())
    }

    /// Header size used for freshly-built `mhli`/`mhla` counted lists: 92
    /// bytes, matching iOpenPod's `MHLI_HEADER_SIZE`/`MHLA_HEADER_SIZE` and
    /// the value already used in `ImageListParsingTests.swift`.
    private static let countedListHeaderLen: UInt32 = 92

    private static func makeEmptyCountedList(tag: String) -> Chunk {
        var w = ByteWriter()
        w.fourCC(tag)
        w.u32(countedListHeaderLen)
        w.u32(0) // count
        w.zeros(Int(countedListHeaderLen) - w.count)

        precondition(w.count == Int(countedListHeaderLen))
        return Chunk(tag: tag, headerLen: countedListHeaderLen, headerBytes: w.finalize(), children: [], trailingBytes: Data())
    }

    private static func makeMHLF(formats: [(formatID: UInt32, imageSizeBytes: UInt32)]) -> Chunk {
        let mhifs = formats.map { MHIF.make(formatID: $0.formatID, imageSize: $0.imageSizeBytes) }

        var w = ByteWriter()
        w.fourCC("mhlf")
        w.u32(countedListHeaderLen)
        w.u32(UInt32(mhifs.count))
        w.zeros(Int(countedListHeaderLen) - w.count)

        precondition(w.count == Int(countedListHeaderLen))
        return Chunk(tag: "mhlf", headerLen: countedListHeaderLen, headerBytes: w.finalize(), children: mhifs, trailingBytes: Data())
    }
}
