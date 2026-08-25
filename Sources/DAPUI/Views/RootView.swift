import SwiftUI

/// The app's only top-level view, shared verbatim by the iOS, iPadOS and
/// macOS targets.
///
/// The sidebar is split between the two libraries the app deals with —
/// what's on the DAP, and what's staged on this device — and the steps that
/// move music from the second to the first. Steps that aren't reachable yet
/// are disabled and say why, which is the whole reason for modelling them as
/// data (`Step.availability`) instead of plain `NavigationLink`s.
public struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()
    @State private var selection: Step? = .device

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(Step.allCases, selection: $selection) { step in
                let availability = step.availability(in: model)
                NavigationLink(value: step) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                            if let detail = availability.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: step.systemImage)
                    }
                }
                .disabled(!availability.isEnabled)
            }
            .navigationTitle("Tarantado")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
            #endif
        } detail: {
            NavigationStack {
                switch selection ?? .device {
                case .device: DeviceView(model: model)
                case .library: LibraryView(model: model, step: $selection)
                case .playlists: PlaylistsView(model: model, step: $selection)
                case .localLibrary: LocalLibraryView(model: model, step: $selection)
                case .review: ReviewView(model: model, step: $selection)
                case .sync: SyncView(model: model, step: $selection)
                }
            }
        }
        .task {
            #if DEBUG
            // Screenshot support: point the app at a prepared synthetic volume
            // and open a named screen, so App Store captures show real content
            // without a device attached. DEBUG-only, so it cannot reach a
            // shipping build; see Scripts/screenshots.sh.
            if let demoPath = ProcessInfo.processInfo.environment["TARANTADO_DEMO_VOLUME"] {
                // Select first: connecting is slow enough that a capture can
                // land before it returns, and the wrong screen would be up.
                if let name = ProcessInfo.processInfo.environment["TARANTADO_DEMO_SCREEN"],
                   let step = Step(rawValue: name) {
                    selection = step
                }
                await model.connect(to: URL(fileURLWithPath: demoPath))
                // A mini 2G is a 4 GB device; the container reports the host disk.
                model.setCapacityForScreenshots(
                    totalBytes: 4 * 1_000_000_000,
                    availableBytes: 2_640_000_000
                )
                return
            }
            #endif
            await model.attemptAutoReconnect()
        }
        // Music copied into the library folder through the Files app arrives
        // with no notification to us, and usually while the app is
        // backgrounded. Coming back to the app is the moment to look again.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshLocalLibrary() }
        }
        // Each step's primary button both acts and navigates — see the
        // `step` binding handed to the detail views. Inferring the move from
        // observed state instead looks equivalent but isn't: recomputing an
        // identical plan produces no state change to observe, so the button
        // would silently do nothing on a second press.
    }

    // MARK: - Steps

    enum Step: String, CaseIterable, Identifiable, Hashable {
        // Order is the order they appear in the sidebar: what's on the DAP
        // now, then the flow for changing it.
        case device, library, playlists, localLibrary, review, sync

        var id: String { rawValue }

        var title: String {
            switch self {
            case .device: return "Device"
            case .library: return "DAP Library"
            case .playlists: return "Playlists"
            case .localLibrary: return "Local Library"
            case .review: return "Review"
            case .sync: return "Sync"
            }
        }

        var systemImage: String {
            switch self {
            case .device: return "ipod"
            case .library: return "music.note"
            case .playlists: return "music.note.list"
            case .localLibrary: return "square.and.arrow.down"
            case .review: return "checklist"
            case .sync: return "arrow.triangle.2.circlepath"
            }
        }

        struct Availability {
            let isEnabled: Bool
            /// Shown under the step's title — the reason it's unavailable,
            /// or a one-line summary of its state when it is.
            let detail: String?
        }

        @MainActor
        func availability(in model: AppModel) -> Availability {
            switch self {
            case .device:
                guard let volume = model.volume else {
                    return Availability(isEnabled: true, detail: "Not connected")
                }
                return Availability(isEnabled: true, detail: volume.model.displayName)

            case .library:
                guard model.isConnected else {
                    return Availability(isEnabled: false, detail: "Connect a DAP first")
                }
                let count = model.deviceTracks.count
                return Availability(isEnabled: true, detail: "\(count) track\(count == 1 ? "" : "s") on DAP")

            case .playlists:
                guard model.isConnected else {
                    return Availability(isEnabled: false, detail: "Connect a DAP first")
                }
                let editable = model.editablePlaylists.count
                return Availability(isEnabled: true, detail: "\(editable) editable")

            case .localLibrary:
                // Deliberately usable with no DAP attached: staging music
                // is exactly the thing you want to do on a phone before you
                // are anywhere near the cable.
                if model.isImporting {
                    return Availability(isEnabled: true, detail: "Importing…")
                }
                if case .scanning = model.scanState {
                    return Availability(isEnabled: true, detail: "Reading…")
                }
                if model.sourceTracks.isEmpty {
                    return Availability(isEnabled: true, detail: "Empty")
                }
                return Availability(isEnabled: true, detail: "\(model.selectedFileURLs.count) of \(model.sourceTracks.count) selected")

            case .review:
                guard model.isConnected else {
                    return Availability(isEnabled: false, detail: "Connect a DAP first")
                }
                guard !model.sourceTracks.isEmpty else {
                    return Availability(isEnabled: false, detail: "Add music first")
                }
                guard let plan = model.plan else {
                    return Availability(isEnabled: true, detail: "Not computed")
                }
                return Availability(isEnabled: true, detail: "\(plan.toAdd.count) to add, \(plan.toRemove.count) to remove")

            case .sync:
                guard let plan = model.plan, !plan.isEmpty else {
                    return Availability(isEnabled: false, detail: "Review a plan first")
                }
                switch model.syncState {
                case .syncing: return Availability(isEnabled: true, detail: "In progress…")
                case .done: return Availability(isEnabled: true, detail: "Finished")
                case .failed: return Availability(isEnabled: true, detail: "Failed")
                case .idle: return Availability(isEnabled: true, detail: "Ready")
                }
            }
        }
    }
}
