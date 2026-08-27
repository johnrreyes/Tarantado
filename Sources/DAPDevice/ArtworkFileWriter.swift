import Foundation

/// Appends thumbnail pixel bytes to a format's `.ithmb` file(s) under
/// `iPod_Control/Artwork/`, following the naming convention libgpod's
/// `ithumb-writer.c::get_ithmb_filename` uses: `F<formatID>_<index>.ithmb`,
/// one running file per format, rolling to a new numbered file once the
/// current one would exceed `maxFileSize`.
///
/// An `actor` for the same reason `MusicFolderAllocator` is one: allocation
/// mutates shared per-format state (current file index, current byte
/// offset) and must be safe to call from concurrent sync tasks without
/// callers hand-rolling their own locking.
public actor ArtworkFileWriter {
    public struct Written: Sendable, Equatable {
        /// Bare filename (no colon prefix, no directory), e.g.
        /// `"F1029_1.ithmb"` — matching what `MHNI.make(ithmbFileName:)`
        /// expects a `:` prepended to.
        public let filename: String
        /// Byte offset this write started at — where the pixel data now
        /// lives in `filename`.
        public let offset: UInt32
    }

    public enum WriteError: Error, LocalizedError, Equatable {
        case payloadExceedsMaxFileSize(formatID: UInt32, payloadSize: Int, maxFileSize: UInt32)

        public var errorDescription: String? {
            switch self {
            case .payloadExceedsMaxFileSize(let formatID, let payloadSize, let maxFileSize):
                return "A format \(formatID) thumbnail is \(payloadSize) bytes, larger than the \(maxFileSize)-byte .ithmb file size budget."
            }
        }
    }

    /// Matches libgpod's own `ITHUMB_MAX_SIZE`. Originally set to a smaller,
    /// more conservative 32 MB (the budget iOpenPod's Python port
    /// independently chose), but a real 5G's actual `F1029_1.ithmb` —
    /// several years of a real library's cover art, never rolled over —
    /// turned out to be 230 MB on its own: comfortably past 32 MB, and real
    /// iTunes clearly didn't consider that a problem. 32 MB was learned to be
    /// wrong by writing to that exact device: the smaller budget made this
    /// writer immediately fragment into a needless `_2` file for even a
    /// single added track once the pre-existing file was in scope, which is
    /// harmless (each thumbnail is still self-describing by filename) but
    /// pointless. libgpod's number is now the one with real-device evidence
    /// behind it.
    public static let defaultMaxFileSize: UInt32 = 256_000_000

    private let volume: DAPVolume
    private let maxFileSize: UInt32
    private var stateByFormat: [UInt32: (index: Int, offset: UInt32)] = [:]

    public init(volume: DAPVolume, maxFileSize: UInt32 = ArtworkFileWriter.defaultMaxFileSize) {
        self.volume = volume
        self.maxFileSize = maxFileSize
    }

    private func fileURL(formatID: UInt32, index: Int) -> URL {
        volume.artworkDirectory.appendingPathComponent("F\(formatID)_\(index).ithmb", isDirectory: false)
    }

    /// Appends `pixelData` to `formatID`'s current `.ithmb` file, creating
    /// the `Artwork` directory and/or the file itself as needed. Returns
    /// where the bytes landed.
    public func append(formatID: UInt32, pixelData: Data) throws -> Written {
        guard pixelData.count <= Int(maxFileSize) else {
            throw WriteError.payloadExceedsMaxFileSize(formatID: formatID, payloadSize: pixelData.count, maxFileSize: maxFileSize)
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: volume.artworkDirectory, withIntermediateDirectories: true)

        var state = try currentState(formatID: formatID, fileManager: fileManager)
        if state.offset > 0, UInt64(state.offset) + UInt64(pixelData.count) > UInt64(maxFileSize) {
            state = (state.index + 1, 0)
        }

        let url = fileURL(formatID: formatID, index: state.index)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        try handle.write(contentsOf: pixelData)

        let written = Written(filename: url.lastPathComponent, offset: state.offset)
        stateByFormat[formatID] = (state.index, state.offset + UInt32(pixelData.count))
        return written
    }

    /// Seeds this format's write cursor from whatever's already on disk —
    /// the highest-numbered existing `.ithmb` file for it, appending from
    /// that file's current size — so a second sync continues where the
    /// first left off rather than overwriting it. Computed once per format,
    /// then cached in `stateByFormat` for the life of this writer.
    private func currentState(formatID: UInt32, fileManager: FileManager) throws -> (index: Int, offset: UInt32) {
        if let cached = stateByFormat[formatID] { return cached }

        var index = 1
        while fileManager.fileExists(atPath: fileURL(formatID: formatID, index: index + 1).path) {
            index += 1
        }
        let url = fileURL(formatID: formatID, index: index)
        let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? UInt64
        let state = (index, UInt32(clamping: size ?? 0))
        stateByFormat[formatID] = state
        return state
    }
}
