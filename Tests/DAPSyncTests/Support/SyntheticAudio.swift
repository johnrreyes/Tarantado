import Foundation
import AVFoundation
import CoreMedia

/// Generates small, silent audio files at runtime for tests, rather than
/// committing binary fixtures to the repo.
enum SyntheticAudio {
    struct Tags {
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var genre: String?
        var composer: String?
        var trackNumber: Int?
        var totalTracks: Int?
        var discNumber: Int?
        var totalDiscs: Int?
        var year: Int?
        var compilation: Bool?
        var artworkData: Data?

        init(
            title: String? = nil, artist: String? = nil, album: String? = nil, albumArtist: String? = nil,
            genre: String? = nil, composer: String? = nil, trackNumber: Int? = nil, totalTracks: Int? = nil,
            discNumber: Int? = nil, totalDiscs: Int? = nil, year: Int? = nil, compilation: Bool? = nil,
            artworkData: Data? = nil
        ) {
            self.title = title
            self.artist = artist
            self.album = album
            self.albumArtist = albumArtist
            self.genre = genre
            self.composer = composer
            self.trackNumber = trackNumber
            self.totalTracks = totalTracks
            self.discNumber = discNumber
            self.totalDiscs = totalDiscs
            self.year = year
            self.compilation = compilation
            self.artworkData = artworkData
        }
    }

    /// Writes a short, silent, 16-bit PCM `.wav` file. AVFoundation's writer
    /// carries essentially no useful tag data through a WAV container, so
    /// this is used for filename-fallback-naming and mechanical (copy,
    /// classification, cancellation) tests, not metadata-round-trip tests.
    static func makeWAV(at url: URL, durationSeconds: Double = 0.2, sampleRate: Double = 44_100) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        guard let bufferFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 2, interleaved: true) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: bufferFormat, frameCapacity: frameCount) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = frameCount
        try file.write(from: buffer)
    }

    /// Writes a short, silent AAC (`.m4a`) file carrying the given
    /// iTunes-style metadata atoms, generated entirely at runtime: a raw PCM
    /// buffer is fed to an `AVAssetWriterInput` configured for AAC output,
    /// which transcodes internally (no separate encoding step needed).
    static func makeAAC(at url: URL, durationSeconds: Double = 0.2, sampleRate: Double = 44_100, tags: Tags = Tags()) async throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let writer = try AVAssetWriter(url: url, fileType: .m4a)
        writer.metadata = metadataItems(for: tags)

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 64_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)

        guard let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else {
            throw CocoaError(.fileWriteUnknown)
        }
        pcmBuffer.frameLength = frameCount

        let sampleBuffer = try makeSampleBuffer(from: pcmBuffer, at: .zero)
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard input.append(sampleBuffer) else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        input.markAsFinished()

        writer.finishWriting {}
        while writer.status == .writing {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard writer.status == .completed else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    // MARK: - Metadata

    private static func metadataItems(for tags: Tags) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []

        func add(_ identifier: AVMetadataIdentifier, _ value: (any NSCopying & NSObjectProtocol)?) {
            guard let value else { return }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            items.append(item)
        }

        add(.iTunesMetadataSongName, tags.title as NSString?)
        add(.iTunesMetadataArtist, tags.artist as NSString?)
        add(.iTunesMetadataAlbum, tags.album as NSString?)
        add(.iTunesMetadataAlbumArtist, tags.albumArtist as NSString?)
        add(.iTunesMetadataUserGenre, tags.genre as NSString?)
        add(.iTunesMetadataComposer, tags.composer as NSString?)
        if let year = tags.year {
            add(.iTunesMetadataReleaseDate, "\(year)-01-01T00:00:00Z" as NSString)
        }
        if tags.trackNumber != nil || tags.totalTracks != nil {
            add(.iTunesMetadataTrackNumber, pairData(index: tags.trackNumber ?? 0, total: tags.totalTracks ?? 0) as NSData)
        }
        if tags.discNumber != nil || tags.totalDiscs != nil {
            add(.iTunesMetadataDiscNumber, pairData(index: tags.discNumber ?? 0, total: tags.totalDiscs ?? 0) as NSData)
        }
        if let compilation = tags.compilation {
            add(.iTunesMetadataDiscCompilation, NSNumber(value: compilation))
        }
        if let artworkData = tags.artworkData {
            add(.iTunesMetadataCoverArt, artworkData as NSData)
        }
        return items
    }

    /// Binary layout of the iTunes `trkn`/`disk` atom payload: 2 reserved
    /// bytes, a big-endian `UInt16` index, a big-endian `UInt16` total, then
    /// 2 more reserved bytes.
    private static func pairData(index: Int, total: Int) -> Data {
        var bytes: [UInt8] = [0, 0]
        bytes.append(UInt8((index >> 8) & 0xff))
        bytes.append(UInt8(index & 0xff))
        bytes.append(UInt8((total >> 8) & 0xff))
        bytes.append(UInt8(total & 0xff))
        bytes.append(contentsOf: [0, 0])
        return Data(bytes)
    }

    // MARK: - AVAudioPCMBuffer -> CMSampleBuffer bridge

    private static func makeSampleBuffer(from buffer: AVAudioPCMBuffer, at time: CMTime) throws -> CMSampleBuffer {
        guard let formatDescription = buffer.format.formatDescription as CMAudioFormatDescription? else {
            throw CocoaError(.fileWriteUnknown)
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(buffer.format.sampleRate)),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw CocoaError(.fileWriteUnknown)
        }
        let status2 = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList
        )
        guard status2 == noErr else {
            throw CocoaError(.fileWriteUnknown)
        }
        return sampleBuffer
    }
}
