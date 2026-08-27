import SwiftUI
import DAPSync

/// The "are you sure?" screen. Shows exactly what a sync would add and
/// remove, and whether it fits, before anything is written — `SyncPlan` is
/// pure, so everything here is computed without touching the device.
struct ReviewView: View {
    @Bindable var model: AppModel
    @Binding var step: RootView.Step?

    var body: some View {
        Group {
            if let plan = model.plan {
                planForm(plan)
            } else {
                ContentUnavailableView {
                    Label("No plan computed", systemImage: "checklist")
                } description: {
                    Text("Choose tracks under Music, then compute a plan to see what would change.")
                } actions: {
                    Button("Compute Plan") { model.computePlan() }
                        .disabled(model.sourceTracks.isEmpty)
                }
            }
        }
        .navigationTitle("Review")
    }

    private func planForm(_ plan: SyncPlan) -> some View {
        Form {
            if let capacity = model.capacity {
                Section("Storage") {
                    let breakdown = StorageBreakdown(
                        capacity: capacity,
                        incomingBytes: plan.bytesRequired,
                        freedBytes: plan.bytesFreed
                    )
                    StorageBarView(breakdown: breakdown).padding(.vertical, 4)
                    if !breakdown.fits {
                        Label(
                            "This sync needs \(Formatting.bytes(plan.bytesRequired)) but only \(Formatting.bytes(capacity.availableBytes + plan.bytesFreed)) will be free.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                Toggle("Remove tracks not in this folder", isOn: $model.mirrorSync)
                    .onChange(of: model.mirrorSync) { _, _ in model.computePlan() }
                Text("Off by default: a sync of a few tracks should never propose deleting everything else already on the DAP.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !plan.toAdd.isEmpty {
                Section("Add (\(plan.toAdd.count)) — \(Formatting.bytes(plan.bytesRequired))") {
                    ForEach(plan.toAdd, id: \.source.fileURL) { item in
                        row(
                            title: item.source.title,
                            subtitle: item.source.artist,
                            trailing: Formatting.bytes(item.source.fileSize),
                            artwork: .some(item.source.artworkData)
                        )
                    }
                }
            }

            if !plan.toRemove.isEmpty {
                Section("Remove (\(plan.toRemove.count)) — frees \(Formatting.bytes(plan.bytesFreed))") {
                    ForEach(plan.toRemove, id: \.deviceTrack.uniqueID) { item in
                        row(
                            title: item.deviceTrack.title ?? "Untitled",
                            subtitle: item.deviceTrack.artist,
                            trailing: Formatting.bytes(Int64(item.deviceTrack.size))
                        )
                    }
                }
            }

            if !plan.skipped.isEmpty {
                Section("Skipped (\(plan.skipped.count))") {
                    ForEach(plan.skipped, id: \.source.fileURL) { item in
                        row(title: item.source.fileURL.lastPathComponent, subtitle: item.reason, trailing: nil)
                    }
                }
            }

            Section {
                LabeledContent("Already on DAP", value: "\(plan.unchanged.count)")
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            Button("Sync") {
                model.startSync()
                step = .sync
            }
                .buttonStyle(.borderedProminent)
                .disabled(!canSync(plan))
                .padding()
        }
    }

    private func canSync(_ plan: SyncPlan) -> Bool {
        guard !plan.isEmpty else { return false }
        guard model.syncSupport?.isSupported == true else { return false }
        guard let capacity = model.capacity else { return true }
        return plan.fits(in: capacity)
    }

    /// `artwork` is a double optional so this can tell "this row type has no
    /// artwork concept at all" (Remove/Skipped rows, the default `nil`) apart
    /// from "this track has the concept but no actual art" (Add rows for a
    /// track with no embedded cover, `.some(nil)`) — the former shows nothing,
    /// the latter shows the placeholder, keeping every row in the Add
    /// section the same height rather than only the ones with real art.
    private func row(title: String, subtitle: String?, trailing: String?, artwork: Data?? = nil) -> some View {
        HStack {
            if let artwork {
                ArtworkThumbnailView(data: artwork, size: 32)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let trailing {
                Text(trailing).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}
