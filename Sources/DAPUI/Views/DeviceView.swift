import SwiftUI
import DAPDevice

/// Connect / disconnect, plus what the engine could work out about the
/// device: model, capacity, and — most importantly — whether it is safe to
/// write to at all.
struct DeviceView: View {
    @Bindable var model: AppModel
    @State private var isPickingVolume = false

    var body: some View {
        Form {
            connectionSection

            if let volume = model.volume {
                if let support = model.syncSupport, !support.isSupported {
                    Section {
                        Label {
                            Text(support.reason ?? "This DAP can't be synced.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section("Device") {
                    LabeledContent("Model", value: volume.model.displayName)
                    LabeledContent("Generation", value: volume.model.generation)
                    LabeledContent("Model Number", value: volume.sysInfo.modelNumber ?? "Unknown")
                    LabeledContent("Serial", value: volume.sysInfo.serialNumber ?? "Unknown")
                    LabeledContent("Artwork", value: volume.model.supportsArtwork ? "Supported" : "Not supported")

                    // An unrecognized model is only ever fixed by adding it
                    // to the lookup table, and the model number that would
                    // let us do that is on the device in the user's hand.
                    // Make it something they can send us in one tap rather
                    // than something they have to transcribe.
                    if volume.model.isUnknown {
                        Text("Tarantado has no entry for this device. Sending its identity lets support add one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ShareLink("Share Device Identity…", item: volume.identityReport)
                    }
                }

                Section("Library") {
                    LabeledContent("Tracks", value: "\(model.deviceTracks.count)")
                    LabeledContent("Playlists", value: "\(model.devicePlaylistCount)")
                }

                if let capacity = model.capacity {
                    Section("Storage") {
                        StorageBarView(breakdown: StorageBreakdown(capacity: capacity))
                            .padding(.vertical, 4)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Device")
        .fileImporter(
            isPresented: $isPickingVolume,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                Task { await model.connect(to: url) }
            }
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        Section {
            switch model.connectionState {
            case .disconnected:
                Button("Connect DAP…") { isPickingVolume = true }
                Text("Choose the mounted DAP volume. Tarantado reads its `SysInfo` to identify the model before touching anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .connecting:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Connecting…")
                }

            case .connected:
                Button("Disconnect", role: .destructive) { model.disconnect() }

            case .failed(let message):
                Label {
                    Text(message)
                        // Connection failures now carry the chunk path and
                        // byte offset that identify an unreadable database.
                        // That detail is only worth producing if the user can
                        // actually get it back to us, so keep it selectable
                        // and shareable rather than screenshot-only.
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
                Button("Try Again…") { isPickingVolume = true }
                ShareLink("Share Error Details…", item: message)
            }
        }
    }
}
