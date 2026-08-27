import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A small square cover-art thumbnail decoded from a track's embedded
/// artwork bytes (`SourceTrack.artworkData`), or a plain music-note
/// placeholder when there's none, or it fails to decode — a track without
/// art is the common case, not an error, so this never shows anything
/// alarming for `nil`.
///
/// SwiftUI has no `Image(data:)` initializer, so decoding goes through
/// `NSImage`/`UIImage` depending on platform. Decoding happens on every
/// render rather than being cached: `List`/`Form` rows are already lazy —
/// only visible rows decode — and a personal library's row count never gets
/// large enough for that to matter.
struct ArtworkThumbnailView: View {
    let data: Data?
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let image = Self.decode(data) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(.quaternary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: size * 0.15, style: .continuous))
    }

    private static func decode(_ data: Data?) -> Image? {
        guard let data else { return nil }
        #if os(macOS)
        guard let platformImage = NSImage(data: data) else { return nil }
        return Image(nsImage: platformImage)
        #else
        guard let platformImage = UIImage(data: data) else { return nil }
        return Image(uiImage: platformImage)
        #endif
    }
}
