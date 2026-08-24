import SwiftUI

/// How a track list is broken into sections.
///
/// Grouping exists to make *selection* bulk-sized: picking a whole album or
/// artist is the common case, and ticking a dozen rows by hand on a phone is
/// miserable. Both library screens use this, so the album-keying rule below
/// can't drift between them.
enum TrackGrouping: String, CaseIterable, Identifiable {
    case songs = "Songs"
    case artists = "Artists"
    case albums = "Albums"

    var id: String { rawValue }

    /// The section a track belongs to.
    ///
    /// Albums are keyed by title *and* artist. Keying on title alone merges
    /// every "Greatest Hits" in the library into one section, which is both
    /// wrong and a trap: "Select All" there would tick tracks from records
    /// the user never looked at.
    func sectionName(artist: String?, albumArtist: String? = nil, album: String?) -> String {
        switch self {
        case .songs:
            return ""
        case .artists:
            return artist ?? "Unknown Artist"
        case .albums:
            let album = album ?? "Unknown Album"
            guard let creditedArtist = albumArtist ?? artist else { return album }
            return "\(album) — \(creditedArtist)"
        }
    }
}

/// The Songs / Artists / Albums selector shown above a track list.
struct TrackGroupingPicker: View {
    @Binding var grouping: TrackGrouping

    var body: some View {
        Picker("Group by", selection: $grouping) {
            ForEach(TrackGrouping.allCases) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Section-header button that ticks or unticks everything under it.
struct SelectAllButton: View {
    let isFullySelected: Bool
    let action: () -> Void

    var body: some View {
        Button(isFullySelected ? "Deselect All" : "Select All", action: action)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .font(.caption)
            // Section headers uppercase their contents by default, which
            // would shout the button text.
            .textCase(nil)
    }
}
