import Foundation
import DAPDB

/// `Track` (DAPDB's plain-value snapshot of an `mhit`) has no public
/// memberwise initializer — only `init(from: MHIT)` — since it already
/// declares that initializer, Swift doesn't synthesize a memberwise one.
/// This builds one through the public `MHIT.make` construction API instead,
/// for tests that need a "device already has this track" fixture without a
/// real device or database file.
func makeDeviceTrack(
    uniqueID: UInt32,
    title: String? = nil,
    artist: String? = nil,
    album: String? = nil,
    size: UInt32 = 0,
    lengthMS: UInt32 = 0,
    location: String? = nil
) -> Track {
    var fields = MHIT.Fields(uniqueID: uniqueID)
    fields.size = size
    fields.length = lengthMS

    var strings: [MHOD.Kind: String] = [:]
    if let title { strings[.title] = title }
    if let artist { strings[.artist] = artist }
    if let album { strings[.album] = album }
    if let location { strings[.location] = location }

    let chunk = MHIT.make(fields, strings: strings)
    guard let mhit = MHIT(chunk) else {
        preconditionFailure("MHIT.make produced a non-mhit chunk")
    }
    return Track(from: mhit)
}
