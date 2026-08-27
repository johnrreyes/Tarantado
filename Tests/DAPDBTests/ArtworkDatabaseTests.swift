import Foundation
import Testing
@testable import DAPDB

/// Byte-level tests for the ArtworkDB model added in Phase 1 of album-art
/// support (`mhfd`/`mhsd`/`mhli`/`mhii`/`mhni`/`mhlf`/`mhif`, plus the
/// ArtworkDB-specific `mhod` shape in `ArtworkMHOD`).
///
/// These prove the parser agrees with the writer, byte-for-byte — the same
/// standard `MHITSyntheticTests`/`ImageListParsingTests` hold the rest of
/// this library to. They cannot prove the *layout* is what a real 5G's
/// firmware expects; per the module's own README, only a physical device can
/// do that, and this feature has not yet been validated against one.
struct ArtworkDatabaseTests {

    // MARK: - ArtworkMHOD

    @Test func stringMHODRoundTripsUTF16LEFilename() throws {
        let chunk = ArtworkMHOD.makeString(kind: .fileName, value: ":F1029_1.ithmb")

        let serialized = ChunkTree.serialize(chunk)
        let reparsed = try ChunkTree.parse(serialized)
        #expect(reparsed.tag == "mhod")
        // Declared headerLen is 24 even though the string's real fixed
        // prefix is 36 bytes -- see ArtworkMHOD's type doc.
        #expect(reparsed.headerLen == 24)
        #expect(reparsed.headerBytes.count == 24)

        let mhod = try #require(ArtworkMHOD(reparsed))
        #expect(mhod.kind == .fileName)
        #expect(mhod.isStringType)
        #expect(mhod.stringValue == ":F1029_1.ithmb")
    }

    @Test func stringMHODPayloadHandlesUnicode() throws {
        // Not a realistic ithmb filename, but proves the UTF-16LE round trip
        // isn't accidentally ASCII-only.
        let chunk = ArtworkMHOD.makeString(kind: .fileName, value: ":caf\u{00e9}.ithmb")
        let reparsed = try ChunkTree.parse(ChunkTree.serialize(chunk))
        let mhod = try #require(ArtworkMHOD(reparsed))
        #expect(mhod.stringValue == ":caf\u{00e9}.ithmb")
    }

    @Test func containerMHODWrapsItsChildAndReportsNoStringValue() throws {
        let mhni = MHNI.make(
            formatID: 1029, ithmbOffset: 0, imageSize: 80_000,
            imageWidth: 200, imageHeight: 200, ithmbFileName: "F1029_1.ithmb"
        )
        let chunk = ArtworkMHOD.makeContainer(kind: .thumbnailImage, wrapping: mhni)

        let reparsed = try ChunkTree.parse(ChunkTree.serialize(chunk))
        let mhod = try #require(ArtworkMHOD(reparsed))
        #expect(mhod.kind == .thumbnailImage)
        #expect(mhod.isStringType == false)
        #expect(mhod.stringValue == nil)
        #expect(mhod.wrappedChunk?.tag == "mhni")
    }

    // MARK: - MHNI

    @Test func syntheticMHNIRoundTripsEveryField() throws {
        let chunk = MHNI.make(
            formatID: 1029,
            ithmbOffset: 163_840,
            imageSize: 80_000,
            imageWidth: 200,
            imageHeight: 200,
            horizontalPadding: 3,
            verticalPadding: -2,
            ithmbFileName: ":F1029_1.ithmb"
        )

        let reparsed = try ChunkTree.parse(ChunkTree.serialize(chunk))
        let mhni = try #require(MHNI(reparsed))

        #expect(mhni.formatID == 1029)
        #expect(mhni.ithmbOffset == 163_840)
        #expect(mhni.imageSize == 80_000)
        #expect(mhni.imageWidth == 200)
        #expect(mhni.imageHeight == 200)
        #expect(mhni.horizontalPadding == 3)
        #expect(mhni.verticalPadding == -2)
        #expect(mhni.ithmbFileName == ":F1029_1.ithmb")

        #expect(reparsed.headerBytes.leU32(at: 8) == UInt32(reparsed.serializedByteCount))
        #expect(reparsed.headerBytes.leU32(at: 12) == UInt32(reparsed.children.count))
    }

    // MARK: - MHII

    @Test func syntheticMHIIRoundTripsWithTwoThumbnailFormats() throws {
        var fields = MHII.Fields(imageID: 100, songID: 0x0123_4567_89AB_CDEF)
        fields.rating = 60
        fields.origDate = Date(timeIntervalSince1970: 1_700_000_000)
        fields.digitizedDate = Date(timeIntervalSince1970: 1_700_000_100)
        fields.origImageSize = 18_726 // matches a real embedded JPEG's size

        let small = MHNI.make(
            formatID: 1028, ithmbOffset: 0, imageSize: 20_000,
            imageWidth: 100, imageHeight: 100, ithmbFileName: ":F1028_1.ithmb"
        )
        let large = MHNI.make(
            formatID: 1029, ithmbOffset: 0, imageSize: 80_000,
            imageWidth: 200, imageHeight: 200, ithmbFileName: ":F1029_1.ithmb"
        )

        let chunk = MHII.make(fields, thumbnails: [small, large])
        let reparsed = try ChunkTree.parse(ChunkTree.serialize(chunk))
        let mhii = try #require(MHII(reparsed))

        #expect(mhii.imageID == 100)
        #expect(mhii.songID == 0x0123_4567_89AB_CDEF)
        #expect(mhii.rating == 60)
        #expect(mhii.origDate == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(mhii.digitizedDate == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(mhii.origImageSize == 18_726)

        #expect(mhii.thumbnails.count == 2)
        #expect(mhii.thumbnail(formatID: 1028)?.imageWidth == 100)
        #expect(mhii.thumbnail(formatID: 1029)?.imageWidth == 200)

        #expect(reparsed.headerBytes.leU32(at: 8) == UInt32(reparsed.serializedByteCount))
        #expect(reparsed.headerBytes.leU32(at: 12) == 2)
    }

    // MARK: - MHIF

    @Test func syntheticMHIFRoundTrips() throws {
        let chunk = MHIF.make(formatID: 1029, imageSize: 200 * 200 * 2)
        let reparsed = try ChunkTree.parse(ChunkTree.serialize(chunk))
        let mhif = try #require(MHIF(reparsed))
        #expect(mhif.formatID == 1029)
        #expect(mhif.imageSize == 80_000)
    }

    // MARK: - MHFD / ArtworkDatabase.makeEmpty

    @Test func emptyArtworkDatabaseHasThreeSectionsAndRoundTrips() throws {
        let db = ArtworkDatabase.makeEmpty(
            formats: [(formatID: 1028, imageSizeBytes: 20_000), (formatID: 1029, imageSizeBytes: 80_000)],
            nextImageID: 100
        )

        #expect(db.root.tag == "mhfd")
        let mhfd = try #require(MHFD(db.root))
        #expect(mhfd.numberOfSections == 3)
        #expect(mhfd.nextID == 100)
        // The landmine libgpod's own comment warns about: iTunes 7+ deletes
        // the whole ArtworkDB if this is 1.
        #expect(mhfd.chunk.headerBytes.leU32(at: 16) == 2)

        #expect(db.images.isEmpty)
        #expect(db.files.map(\.formatID).sorted() == [1028, 1029])
        #expect(db.files.first { $0.formatID == 1029 }?.imageSize == 80_000)

        let data = db.serialized()
        let reparsed = try ArtworkDatabase(parsing: data)
        #expect(reparsed.serialized() == data)
        #expect(reparsed.files.count == 2)
    }

    @Test func addingAndRemovingAnImageUpdatesCountsAndStillRoundTrips() throws {
        var db = ArtworkDatabase.makeEmpty(
            formats: [(formatID: 1028, imageSizeBytes: 20_000), (formatID: 1029, imageSizeBytes: 80_000)]
        )

        let dbid: UInt64 = 0xAAAA_BBBB_CCCC_DDDD
        var fields = MHII.Fields(imageID: 100, songID: dbid)
        fields.origImageSize = 18_726
        let mhni = MHNI.make(
            formatID: 1028, ithmbOffset: 0, imageSize: 20_000,
            imageWidth: 100, imageHeight: 100, ithmbFileName: ":F1028_1.ithmb"
        )
        try db.addImage(MHII.make(fields, thumbnails: [mhni]))

        #expect(db.images.count == 1)
        #expect(db.image(forTrackDBID: dbid)?.imageID == 100)

        // Self-consistency: totalLen/counts correct all the way to the root,
        // and a fresh parse of the serialized bytes agrees.
        let serialized = db.serialized()
        let reparsed = try ArtworkDatabase(parsing: serialized)
        #expect(reparsed.serialized() == serialized)
        #expect(reparsed.images.count == 1)
        #expect(Int(reparsed.root.headerBytes.leU32(at: 8) ?? 0) == reparsed.root.serializedByteCount)

        db.removeImage(forTrackDBID: dbid)
        #expect(db.images.isEmpty)
        #expect(db.image(forTrackDBID: dbid) == nil)
    }

    @Test func addingAnImageToATreeWithNoImageListThrows() {
        // A root with no mhli anywhere -- e.g. a stray "mhfd" with no
        // sections at all -- must fail loudly rather than silently no-op.
        let bareRoot = MHFD.make(sections: [], nextImageID: 100)
        var db = ArtworkDatabase(root: bareRoot)
        let mhii = MHII.make(MHII.Fields(imageID: 1, songID: 1), thumbnails: [])
        #expect(throws: ArtworkMutationError.noImageList) {
            try db.addImage(mhii)
        }
    }
}
