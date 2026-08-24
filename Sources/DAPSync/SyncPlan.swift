import Foundation
import DAPDB
import DAPDevice

/// Which source tracks and device tracks a `SyncPlan.compute` call should
/// consider.
public struct SyncSelection: Sendable, Equatable {
    /// Restricts which scanned source files are eligible to be added.
    /// `nil` means "every source track `compute` was given" — used by
    /// `dapctl sync --limit N` to only propose adding the first N tracks
    /// without touching anything already on the device.
    public var includedSourceFileURLs: Set<URL>?

    /// When `true`, device tracks with no matching source track are
    /// proposed for removal (a "mirror" sync). When `false` (the default),
    /// the sync is purely additive: existing device tracks are left alone
    /// even if they aren't present in `sourceTracks`. This matters a lot in
    /// practice — a `--limit 5` smoke-test sync against a 900-track library
    /// must never propose deleting the other 895 tracks.
    public var removeMissing: Bool

    public init(includedSourceFileURLs: Set<URL>? = nil, removeMissing: Bool = false) {
        self.includedSourceFileURLs = includedSourceFileURLs
        self.removeMissing = removeMissing
    }
}

/// A pure, side-effect-free description of the work a sync would do,
/// computed by diffing a device's current tracks against a freshly scanned
/// source folder. Never touches the device — safe to compute for display
/// (an "are you sure?" review screen, or `dapctl plan`) before anything is
/// written.
public struct SyncPlan: Sendable, Equatable {
    public struct AddItem: Sendable, Equatable {
        public let source: SourceTrack
        public let format: SourceAudioFormat
    }

    public struct RemoveItem: Sendable, Equatable {
        public let deviceTrack: Track
    }

    public struct SkippedItem: Sendable, Equatable {
        public let source: SourceTrack
        public let reason: String
    }

    /// Source tracks to copy to the device and add to the database.
    public var toAdd: [AddItem]
    /// Device tracks to delete (file + database entry). Only ever
    /// populated when `SyncSelection.removeMissing` is `true`.
    public var toRemove: [RemoveItem]
    /// Device tracks that already match a source track and need no change.
    public var unchanged: [Track]
    /// Source tracks that were considered but can't be played by the
    /// device at all (wrong codec, DRM, oversized) — never added, but
    /// reported so the review UI can explain why a file didn't show up.
    public var skipped: [SkippedItem]

    /// Total bytes the new files in `toAdd` will occupy.
    public var bytesRequired: Int64
    /// Total bytes freed by deleting the files in `toRemove`.
    public var bytesFreed: Int64

    public init(
        toAdd: [AddItem] = [],
        toRemove: [RemoveItem] = [],
        unchanged: [Track] = [],
        skipped: [SkippedItem] = [],
        bytesRequired: Int64 = 0,
        bytesFreed: Int64 = 0
    ) {
        self.toAdd = toAdd
        self.toRemove = toRemove
        self.unchanged = unchanged
        self.skipped = skipped
        self.bytesRequired = bytesRequired
        self.bytesFreed = bytesFreed
    }

    public var isEmpty: Bool { toAdd.isEmpty && toRemove.isEmpty }

    /// Whether this plan would fit on a device with the given capacity,
    /// accounting for space freed by removals as well as space consumed by
    /// additions.
    public func fits(in capacity: DAPVolume.Capacity) -> Bool {
        capacity.availableBytes + bytesFreed >= bytesRequired
    }

    // MARK: - Computing a plan

    /// Diffs `sourceTracks` (as produced by `LibraryScanner.scan`) against
    /// `deviceTracks` (as read from the device's current `ITunesDatabase`).
    ///
    /// Matching uses a stable content key rather than file path, so the
    /// same logical track is recognized as "already present" even though
    /// its on-device filename is an opaque 4-letter code unrelated to the
    /// source filename: file size, plus case/diacritic/punctuation-folded
    /// artist and title. Duration (rounded to the nearest second) is used
    /// only to disambiguate multiple device tracks that would otherwise tie
    /// on that key.
    ///
    /// This is a pure function — it never touches `volume` or the
    /// filesystem — so syncing the same, unchanged source folder twice in a
    /// row is guaranteed to produce an empty second plan (nothing in
    /// `toAdd`/`toRemove`), which is what makes a sync idempotent.
    public static func compute(
        deviceTracks: [Track],
        sourceTracks: [SourceTrack],
        selection: SyncSelection = SyncSelection()
    ) -> SyncPlan {
        let included: [SourceTrack]
        if let allowed = selection.includedSourceFileURLs {
            included = sourceTracks.filter { allowed.contains($0.fileURL) }
        } else {
            included = sourceTracks
        }

        var deviceByKey: [ContentKey: [Track]] = [:]
        for track in deviceTracks {
            deviceByKey[ContentKey(size: track.size, artist: track.artist, title: track.title), default: []].append(track)
        }

        var matchedDeviceIDs = Set<UInt32>()
        var toAdd: [AddItem] = []
        var skipped: [SkippedItem] = []
        var unchanged: [Track] = []

        for source in included {
            switch source.compatibility {
            case .unsupported(let reason):
                skipped.append(SkippedItem(source: source, reason: reason))

            case .passThrough(let format):
                let key = ContentKey(size: UInt32(clamping: source.fileSize), artist: source.artist, title: source.title)
                let sourceSeconds = source.durationMS / 1000
                let candidates = (deviceByKey[key] ?? []).filter { !matchedDeviceIDs.contains($0.uniqueID) }

                if let best = candidates.min(by: {
                    abs(Int($0.length / 1000) - sourceSeconds) < abs(Int($1.length / 1000) - sourceSeconds)
                }) {
                    matchedDeviceIDs.insert(best.uniqueID)
                    unchanged.append(best)
                } else {
                    toAdd.append(AddItem(source: source, format: format))
                }
            }
        }

        var toRemove: [RemoveItem] = []
        if selection.removeMissing {
            for track in deviceTracks where !matchedDeviceIDs.contains(track.uniqueID) {
                toRemove.append(RemoveItem(deviceTrack: track))
            }
        }

        let bytesRequired = toAdd.reduce(Int64(0)) { $0 + $1.source.fileSize }
        let bytesFreed = toRemove.reduce(Int64(0)) { $0 + Int64($1.deviceTrack.size) }

        return SyncPlan(
            toAdd: toAdd,
            toRemove: toRemove,
            unchanged: unchanged,
            skipped: skipped,
            bytesRequired: bytesRequired,
            bytesFreed: bytesFreed
        )
    }

    /// Builds a plan that deletes exactly the device tracks whose unique IDs
    /// appear in `trackIDs`, and adds nothing. Unlike `compute`, this needs no
    /// source folder — it's how a user removes tracks directly ("delete these
    /// three songs") rather than as a side effect of mirroring a folder.
    ///
    /// IDs with no matching device track are ignored here and returned in
    /// `unmatched` so the caller can report them rather than silently doing
    /// less than the user asked for.
    public static func removing(
        trackIDs: [UInt32],
        from deviceTracks: [Track]
    ) -> (plan: SyncPlan, unmatched: [UInt32]) {
        let requested = Set(trackIDs)
        let matched = deviceTracks.filter { requested.contains($0.uniqueID) }
        let unmatched = trackIDs.filter { id in !matched.contains { $0.uniqueID == id } }

        let toRemove = matched.map { RemoveItem(deviceTrack: $0) }
        let plan = SyncPlan(
            toRemove: toRemove,
            unchanged: deviceTracks.filter { !requested.contains($0.uniqueID) },
            bytesFreed: toRemove.reduce(Int64(0)) { $0 + Int64($1.deviceTrack.size) }
        )
        return (plan, unmatched)
    }

    // MARK: - Content key

    private struct ContentKey: Hashable {
        let size: UInt32
        let artist: String
        let title: String

        init(size: UInt32, artist: String?, title: String?) {
            self.size = size
            self.artist = SyncPlan.normalize(artist)
            self.title = SyncPlan.normalize(title)
        }
    }

    /// Folds case and diacritics, and collapses every run of
    /// non-alphanumeric characters (punctuation, whitespace) into a single
    /// space, so e.g. `"Beyoncé"`/`"beyonce"`, or `"Rock & Roll"`/`"Rock and
    /// Roll... "` don't cause a false "new track" on re-scan just because of
    /// how a tagger happened to punctuate the artist/title.
    ///
    /// (The "and"/"&" case isn't actually normalized away — that would
    /// require language-aware synonym handling well beyond a content key's
    /// job. Only whitespace/punctuation/case/diacritics are folded.)
    static func normalize(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "" }
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var result = ""
        result.reserveCapacity(folded.count)
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                result.append(" ")
                lastWasSpace = true
            }
        }
        while result.hasSuffix(" ") { result.removeLast() }
        return result
    }
}
